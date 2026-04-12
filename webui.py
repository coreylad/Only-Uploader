#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Only-Uploader Web UI
====================
A lightweight Flask interface for submitting upload jobs, monitoring their
status and editing the configuration file.

Start with:
    python webui.py [--host 0.0.0.0] [--port 5000] [--debug]

The server is intentionally single-threaded so that the background upload
jobs do not race each other.  Jobs are queued and executed sequentially by a
dedicated background thread that calls the upload pipeline directly
(in-process, via run_upload_programmatic) rather than spawning a subprocess.
"""

import io
import os
import sys
import json
import uuid
import queue
import shlex
import logging
import argparse
import asyncio
import contextlib
import threading
from datetime import datetime, timezone

from flask import (
    Flask,
    render_template,
    request,
    redirect,
    url_for,
    flash,
    jsonify,
)

from src.cross_seed import UNIT3D_API_MAP

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
BASE_DIR = os.path.abspath(os.path.dirname(__file__))
JOBS_FILE = os.path.join(BASE_DIR, "tmp", "webui_jobs.json")
CONFIG_FILE = os.path.join(BASE_DIR, "data", "config.py")

# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------
app = Flask(__name__, template_folder="templates")
app.secret_key = os.environ.get("WEBUI_SECRET", os.urandom(24).hex())

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("webui")

# ---------------------------------------------------------------------------
# Job store (JSON file – good enough for a single-user tool)
# ---------------------------------------------------------------------------
_jobs_lock = threading.Lock()


def _load_jobs():
    if not os.path.exists(JOBS_FILE):
        return {}
    with open(JOBS_FILE) as fh:
        try:
            return json.load(fh)
        except (json.JSONDecodeError, IOError):
            return {}


def _save_jobs(jobs):
    os.makedirs(os.path.dirname(JOBS_FILE), exist_ok=True)
    with open(JOBS_FILE, "w") as fh:
        json.dump(jobs, fh, indent=2)


def _get_job(job_id):
    with _jobs_lock:
        return _load_jobs().get(job_id)


def _update_job(job_id, **kwargs):
    with _jobs_lock:
        jobs = _load_jobs()
        if job_id in jobs:
            jobs[job_id].update(kwargs)
            _save_jobs(jobs)


def _create_job(path, trackers, extra_args, download_from=None, source_id=None, debug=False):
    job_id = uuid.uuid4().hex
    job = {
        "id": job_id,
        "path": path,
        "trackers": trackers,
        "extra_args": extra_args,
        "download_from": download_from,
        "source_id": source_id,
        "debug": debug,
        "status": "queued",
        "started": None,
        "finished": None,
        "log": "",
    }
    with _jobs_lock:
        jobs = _load_jobs()
        jobs[job_id] = job
        _save_jobs(jobs)
    return job_id


# ---------------------------------------------------------------------------
# Background job runner
# ---------------------------------------------------------------------------
_job_queue = queue.Queue()


def _run_job(job_id):
    """Execute the upload pipeline in-process for *job_id*, capturing all output."""
    job = _get_job(job_id)
    if not job:
        log.error("Job %s not found", job_id)
        return

    _update_job(job_id, status="running", started=datetime.now(timezone.utc).isoformat())
    log.info("Starting job %s: %s", job_id, job["path"])

    # Build the meta_overrides dict from the stored job record.
    meta_overrides = {
        "path": job["path"],
        "trackers": job.get("trackers") or "",
        "download_from": job.get("download_from"),
        "source_id": job.get("source_id"),
        "debug": bool(job.get("debug")),
        "unattended": True,
    }

    # Parse any extra free-form flags submitted via the form and merge them.
    extra = job.get("extra_args", "").strip()
    if extra:
        extra_tokens = shlex.split(extra)
        # Walk token pairs to extract --flag value entries into meta_overrides.
        i = 0
        while i < len(extra_tokens):
            tok = extra_tokens[i]
            if tok.startswith("--") and i + 1 < len(extra_tokens) and not extra_tokens[i + 1].startswith("--"):
                key = tok.lstrip("-").replace("-", "_")
                meta_overrides[key] = extra_tokens[i + 1]
                i += 2
            elif tok.startswith("--"):
                key = tok.lstrip("-").replace("-", "_")
                meta_overrides[key] = True
                i += 1
            else:
                i += 1

    # Import run_upload_programmatic lazily so webui.py stays importable even
    # if data/config.py does not yet exist (the config page handles that case).
    try:
        from upload import run_upload_programmatic  # noqa: PLC0415
    except Exception as import_exc:
        log.error("Failed to import upload pipeline: %s", import_exc)
        _update_job(
            job_id,
            status="failed",
            finished=datetime.now(timezone.utc).isoformat(),
            log=f"[webui] Import error: {import_exc}\n",
        )
        return

    # Capture all output (Rich console + print + logging to stdout/stderr) into
    # a StringIO buffer.  Jobs run sequentially on a single worker thread so
    # redirecting the global sys.stdout/stderr here is safe.
    buf = io.StringIO()
    status = "failed"
    try:
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            asyncio.run(run_upload_programmatic(meta_overrides))
        status = "completed"
    except Exception as exc:
        buf.write(f"\n[webui] ERROR: {exc}\n")
        log.exception("Job %s raised an exception", job_id)

    accumulated_log = buf.getvalue()
    _update_job(
        job_id,
        status=status,
        finished=datetime.now(timezone.utc).isoformat(),
        log=accumulated_log,
    )
    log.info("Job %s finished with status: %s", job_id, status)


def _worker():
    """Consume jobs from *_job_queue* sequentially."""
    while True:
        job_id = _job_queue.get()
        try:
            _run_job(job_id)
        except Exception as exc:
            log.exception("Unhandled error in job %s: %s", job_id, exc)
        finally:
            _job_queue.task_done()


# Start one background worker thread (daemon so it exits with the process)
_worker_thread = threading.Thread(target=_worker, daemon=True, name="job-worker")
_worker_thread.start()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _job_list_sorted():
    with _jobs_lock:
        jobs = _load_jobs()
    return sorted(jobs.values(), key=lambda j: j.get("started") or "", reverse=True)


def _compute_stats(jobs):
    counts = {"total": len(jobs), "completed": 0, "running": 0, "failed": 0, "queued": 0}
    for j in jobs:
        counts[j.get("status", "queued")] = counts.get(j.get("status", "queued"), 0) + 1
    return counts


def _default_trackers():
    try:
        sys.path.insert(0, BASE_DIR)
        from data.config import config  # noqa: E402
        return config.get("TRACKERS", {}).get("default_trackers", "")
    except Exception:
        return ""


def _default_screens():
    try:
        sys.path.insert(0, BASE_DIR)
        from data.config import config  # noqa: E402
        return config.get("DEFAULT", {}).get("screens", "6")
    except Exception:
        return "6"


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
def dashboard():
    jobs = _job_list_sorted()
    return render_template(
        "webui/dashboard.html",
        jobs=jobs[:20],
        stats=_compute_stats(jobs),
    )


@app.route("/upload")
def upload_page():
    return render_template(
        "webui/upload.html",
        supported_sources=sorted(UNIT3D_API_MAP.keys()),
        default_trackers=_default_trackers(),
        default_screens=_default_screens(),
    )


@app.route("/upload", methods=["POST"])
def upload_submit():
    path = request.form.get("path", "").strip()
    if not path:
        flash("Content path is required.", "error")
        return redirect(url_for("upload_page"))

    trackers = request.form.get("trackers", "").strip()
    download_from = request.form.get("download_from", "").strip() or None
    source_id = request.form.get("source_id", "").strip() or None
    debug = bool(request.form.get("debug"))

    # Build extra args from optional override fields
    extra_parts = []
    for field, flag in [
        ("category", "--category"),
        ("manual_type", "--type"),
        ("resolution", "--resolution"),
        ("tmdb", "--tmdb"),
        ("imdb", "--imdb"),
        ("manual_edition", "--edition"),
        ("screens", "--screens"),
        ("tag", "--tag"),
        ("desc", "--desc"),
    ]:
        val = request.form.get(field, "").strip()
        if val:
            extra_parts += [flag, val]

    if request.form.get("anon"):
        extra_parts.append("--anon")
    # --unattended is appended automatically by _run_job; the checkbox here
    # is a no-op kept only for UI clarity (store_true is idempotent).

    extra_args = " ".join(shlex.quote(p) for p in extra_parts)

    job_id = _create_job(
        path=path,
        trackers=trackers,
        extra_args=extra_args,
        download_from=download_from,
        source_id=source_id,
        debug=debug,
    )
    _job_queue.put(job_id)

    flash(f"Job {job_id[:8]} queued successfully.", "success")
    return redirect(url_for("job_detail", job_id=job_id))


@app.route("/jobs")
def jobs_page():
    return render_template("webui/jobs.html", jobs=_job_list_sorted())


@app.route("/jobs/<job_id>")
def job_detail(job_id):
    job = _get_job(job_id)
    if not job:
        flash("Job not found.", "error")
        return redirect(url_for("jobs_page"))
    return render_template("webui/job_detail.html", job=job)


@app.route("/api/jobs")
def api_jobs():
    """JSON endpoint for polling job status."""
    return jsonify(_job_list_sorted())


@app.route("/api/jobs/<job_id>")
def api_job(job_id):
    job = _get_job(job_id)
    if not job:
        return jsonify({"error": "not found"}), 404
    return jsonify(job)


@app.route("/config")
def config_page():
    try:
        with open(CONFIG_FILE) as fh:
            content = fh.read()
    except FileNotFoundError:
        content = "# config.py not found – copy data/example-config.py to data/config.py\n"
    return render_template("webui/config.html", config_content=content)


@app.route("/config", methods=["POST"])
def config_save():
    content = request.form.get("config_content", "")
    # Basic safety: ensure it's valid Python before writing
    try:
        compile(content, CONFIG_FILE, "exec")
    except SyntaxError as exc:
        flash(f"Syntax error in config – not saved: {exc}", "error")
        return render_template("webui/config.html", config_content=content)
    try:
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        with open(CONFIG_FILE, "w") as fh:
            fh.write(content)
        flash("Config saved. Restart the Web UI to apply changes.", "success")
    except IOError as exc:
        flash(f"Could not write config: {exc}", "error")
    return redirect(url_for("config_page"))


# ---------------------------------------------------------------------------
# Entry-point
# ---------------------------------------------------------------------------

def _parse_args():
    p = argparse.ArgumentParser(description="Only-Uploader Web UI")
    p.add_argument("--host", default="127.0.0.1", help="Bind address (default: 127.0.0.1)")
    p.add_argument("--port", type=int, default=5000, help="Port (default: 5000)")
    p.add_argument("--debug", action="store_true", help="Enable Flask debug mode")
    return p.parse_args()


if __name__ == "__main__":
    args = _parse_args()
    log.info("Starting Only-Uploader Web UI on http://%s:%s", args.host, args.port)
    app.run(host=args.host, port=args.port, debug=args.debug, use_reloader=False)
