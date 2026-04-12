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
jobs (which invoke the existing CLI pipeline via subprocess) do not race
each other.  Jobs are queued and executed sequentially by a dedicated
background thread.
"""

import os
import sys
import json
import uuid
import queue
import logging
import argparse
import threading
import subprocess
from datetime import datetime

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
UPLOAD_SCRIPT = os.path.join(BASE_DIR, "upload.py")

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
    """Execute the upload.py script for *job_id* and stream output to the log."""
    job = _get_job(job_id)
    if not job:
        log.error("Job %s not found", job_id)
        return

    _update_job(job_id, status="running", started=datetime.utcnow().isoformat())
    log.info("Starting job %s: %s", job_id, job["path"])

    # Build the command
    cmd = [sys.executable, UPLOAD_SCRIPT, job["path"]]

    if job.get("trackers"):
        cmd += ["--trackers", job["trackers"]]

    if job.get("download_from"):
        cmd += ["--download-from", job["download_from"]]

    if job.get("source_id"):
        cmd += ["--source-id", str(job["source_id"])]

    if job.get("debug"):
        cmd.append("--debug")

    # Append any extra free-form args that were submitted via the form
    extra = job.get("extra_args", "").strip()
    if extra:
        cmd += extra.split()

    # Always run unattended from the Web UI
    cmd.append("--unattended")

    log.info("Command: %s", " ".join(cmd))
    accumulated_log = ""

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            cwd=BASE_DIR,
        )
        for line in iter(proc.stdout.readline, ""):
            accumulated_log += line
            # Flush log to disk every 20 lines so the UI can tail it
            if accumulated_log.count("\n") % 20 == 0:
                _update_job(job_id, log=accumulated_log)
        proc.wait()
        status = "completed" if proc.returncode == 0 else "failed"
    except Exception as exc:
        accumulated_log += f"\n[webui] ERROR: {exc}\n"
        status = "failed"

    _update_job(
        job_id,
        status=status,
        finished=datetime.utcnow().isoformat(),
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
    if request.form.get("unattended"):
        extra_parts.append("--unattended")

    extra_args = " ".join(extra_parts)

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
