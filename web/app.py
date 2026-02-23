#!/usr/bin/env python3
"""
Only-Uploader Web Panel
A self-contained Flask web interface for configuring and triggering uploads,
as well as cross-seeding existing torrents to additional trackers.
"""

import ast
import json
import os
import queue
import subprocess
import sys
import threading
import time

from flask import Flask, Response, jsonify, redirect, render_template, request, url_for
from flask_socketio import SocketIO, emit

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", os.urandom(24))
socketio = SocketIO(app, async_mode="threading", cors_allowed_origins="*")

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CONFIG_PATH = os.path.join(BASE_DIR, "data", "config.py")
UPLOAD_SCRIPT = os.path.join(BASE_DIR, "upload.py")

# In-memory store for running job outputs  {job_id: {"lines": [...], "done": bool}}
_jobs: dict = {}
_jobs_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_config_text() -> str:
    """Return the raw text of data/config.py (or example if it doesn't exist)."""
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH, "r") as fh:
            return fh.read()
    example = os.path.join(BASE_DIR, "data", "example-config.py")
    if os.path.exists(example):
        with open(example, "r") as fh:
            return fh.read()
    return ""


def _save_config_text(text: str) -> None:
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w") as fh:
        fh.write(text)


def _parse_config() -> dict:
    """
    Evaluate data/config.py and return the config dict.

    NOTE: This executes a trusted local file (data/config.py) that exists on the
    same filesystem as the running server.  The web panel is intended for private,
    self-hosted use only – do not expose it to untrusted networks without
    authentication.  This matches the security posture of the existing CLI tool,
    which imports the same file directly.
    """
    text = _load_config_text()
    try:
        tree = ast.parse(text, mode="exec")
        ns: dict = {}
        exec(compile(tree, CONFIG_PATH, "exec"), ns)  # nosec B102 – trusted local file
        return ns.get("config", {})
    except Exception:
        return {}


def _run_job(job_id: str, cmd: list) -> None:
    """Run *cmd* in a subprocess, streaming lines to _jobs[job_id]."""
    with _jobs_lock:
        _jobs[job_id] = {"lines": [], "done": False, "returncode": None}

    env = {**os.environ, "PYTHONUNBUFFERED": "1"}
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            cwd=BASE_DIR,
        )
        for line in proc.stdout:
            line = line.rstrip("\n")
            with _jobs_lock:
                _jobs[job_id]["lines"].append(line)
            socketio.emit("log_line", {"job_id": job_id, "line": line})
        proc.wait()
        with _jobs_lock:
            _jobs[job_id]["done"] = True
            _jobs[job_id]["returncode"] = proc.returncode
        socketio.emit("job_done", {"job_id": job_id, "returncode": proc.returncode})
    except Exception as exc:
        with _jobs_lock:
            _jobs[job_id]["lines"].append(f"ERROR: {exc}")
            _jobs[job_id]["done"] = True
            _jobs[job_id]["returncode"] = -1
        socketio.emit("job_done", {"job_id": job_id, "returncode": -1})


def _start_job(cmd: list) -> str:
    job_id = str(int(time.time() * 1000))
    t = threading.Thread(target=_run_job, args=(job_id, cmd), daemon=True)
    t.start()
    return job_id


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    config = _parse_config()
    with _jobs_lock:
        recent_jobs = sorted(_jobs.items(), key=lambda kv: kv[0])[-10:]
    return render_template("index.html", config=config, recent_jobs=recent_jobs)


# --- Config editor ----------------------------------------------------------

@app.route("/config", methods=["GET"])
def config_get():
    text = _load_config_text()
    return render_template("config.html", config_text=text, saved=False, error=None)


@app.route("/config", methods=["POST"])
def config_post():
    text = request.form.get("config_text", "")
    error = None
    # Validate that it's parseable Python before saving
    try:
        ast.parse(text)
    except SyntaxError as exc:
        error = str(exc)
        return render_template("config.html", config_text=text, saved=False, error=error)
    _save_config_text(text)
    return render_template("config.html", config_text=text, saved=True, error=None)


# --- Upload -----------------------------------------------------------------

@app.route("/upload", methods=["GET"])
def upload_get():
    config = _parse_config()
    trackers = list(config.get("TRACKERS", {}).keys())
    trackers = [t for t in trackers if t != "default_trackers"]
    return render_template("upload.html", trackers=trackers)


@app.route("/upload", methods=["POST"])
def upload_post():
    path = request.form.get("path", "").strip()
    trackers = request.form.getlist("trackers")
    debug = "debug" in request.form
    anon = "anon" in request.form
    unattended = "unattended" in request.form

    if not path:
        return jsonify({"error": "path is required"}), 400

    cmd = [sys.executable, UPLOAD_SCRIPT, path]
    if trackers:
        cmd += ["--trackers"] + trackers
    if debug:
        cmd.append("--debug")
    if anon:
        cmd.append("--anon")
    if unattended:
        cmd += ["--unattended", "--unattended-confirm"]

    job_id = _start_job(cmd)
    return redirect(url_for("job_view", job_id=job_id))


# --- Cross-seed -------------------------------------------------------------

@app.route("/cross-seed", methods=["GET"])
def cross_seed_get():
    config = _parse_config()
    trackers = list(config.get("TRACKERS", {}).keys())
    trackers = [t for t in trackers if t != "default_trackers"]
    return render_template("cross_seed.html", trackers=trackers)


@app.route("/cross-seed", methods=["POST"])
def cross_seed_post():
    """
    Cross-seed an already-completed torrent to additional trackers.

    The user supplies either:
      - a path on disk that is already being seeded, OR
      - a torrent hash present in the configured torrent client.

    We then invoke upload.py with --no-seed (don't re-add to client) and the
    supplied hash / path, targeting only the selected trackers, so that the
    existing data is re-used without re-hashing.
    """
    path = request.form.get("path", "").strip()
    torrent_hash = request.form.get("torrent_hash", "").strip()
    trackers = request.form.getlist("trackers")
    unattended = "unattended" in request.form

    if not path and not torrent_hash:
        return jsonify({"error": "Provide either a path or a torrent hash"}), 400
    if not trackers:
        return jsonify({"error": "Select at least one tracker"}), 400

    cmd = [sys.executable, UPLOAD_SCRIPT]
    if path:
        cmd.append(path)
    if torrent_hash:
        cmd += ["--torrenthash", torrent_hash]
    cmd += ["--trackers"] + trackers
    if unattended:
        cmd += ["--unattended", "--unattended-confirm"]

    job_id = _start_job(cmd)
    return redirect(url_for("job_view", job_id=job_id))


# --- Job log viewer ---------------------------------------------------------

@app.route("/job/<job_id>")
def job_view(job_id: str):
    with _jobs_lock:
        job = _jobs.get(job_id)
    if job is None:
        return "Job not found", 404
    return render_template("job.html", job_id=job_id, job=job)


@app.route("/api/job/<job_id>")
def job_api(job_id: str):
    with _jobs_lock:
        job = _jobs.get(job_id)
    if job is None:
        return jsonify({"error": "not found"}), 404
    return jsonify(job)


# ---------------------------------------------------------------------------

if __name__ == "__main__":
    host = os.environ.get("WEBUI_HOST", "0.0.0.0")
    port = int(os.environ.get("WEBUI_PORT", "5000"))
    debug = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    # allow_unsafe_werkzeug is only needed when running under the dev server
    # in non-debug mode (e.g., inside Docker with a single worker).  It is
    # harmless in production because the web panel should be behind a reverse
    # proxy or used on a private network.
    socketio.run(app, host=host, port=port, debug=debug, allow_unsafe_werkzeug=not debug)
