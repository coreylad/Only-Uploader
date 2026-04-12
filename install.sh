#!/usr/bin/env bash
# =============================================================================
# Only-Uploader – Easy Installer
# =============================================================================
# Sets up a fully self-contained, ISOLATED environment including:
#   • Python virtual environment with all dependencies
#   • Optional rtorrent daemon – ALL files live under <install-dir>/rtorrent/
#     so it NEVER touches ~/.rtorrent.rc or any other rtorrent instance
#   • Optional ruTorrent web UI – cloned into <install-dir>/rutorrent/
#     and served on a unique nginx vhost (only-uploader-rutorrent)
#   • Convenience run scripts (run_upload.sh, run_webui.sh, run_rtorrent.sh)
#   • Starter config copied from example-config.py
#
# Isolation guarantees
# --------------------
#   • rtorrent config: <install-dir>/rtorrent/rtorrent.rc  (not ~/.rtorrent.rc)
#   • rtorrent started with -n so it NEVER reads ~/.rtorrent.rc
#   • SCGI RPC uses a loopback TCP port (not a UNIX socket) to avoid
#     file-permission fights between rtorrent and nginx's www-data user
#   • systemd service name: only-uploader-rtorrent.service
#   • nginx vhost name:     only-uploader-rutorrent
#   • ruTorrent files:      <install-dir>/rutorrent/  (not /var/www/rutorrent)
#   • An existing rtorrent.service, ~/.rtorrent.rc, or /var/www/rutorrent
#     installation is left completely untouched
#
# Usage:
#   bash install.sh [OPTIONS]
#
# Options:
#   --install-rtorrent    Install rtorrent daemon (isolated)
#   --install-rutorrent   Install ruTorrent web UI (implies --install-rtorrent)
#   --rutorrent-port N    nginx listen port for ruTorrent (default: 8181)
#   --rpc-port N          loopback TCP SCGI port for rtorrent RPC (default: 51444)
#   --bt-port N           BitTorrent listening port (default: 51914)
#   --download-dir PATH   Directory where rtorrent saves downloads
#                         (default: <install-dir>/downloads)
#   --no-venv             Skip venv creation (not recommended)
#   --help                Show this help
#
# Supported OS: Debian / Ubuntu (apt-based).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${INSTALL_DIR}/venv"
PYTHON_BIN="$(command -v python3 || true)"
INSTALL_RTORRENT=false
INSTALL_RUTORRENT=false
RUTORRENT_PORT=8181          # deliberately NOT 8080 to avoid common conflicts
RPC_PORT=51444               # loopback TCP SCGI port – unique to this instance
BT_PORT=51914                # BitTorrent port – differs from common 51413 default
DOWNLOAD_DIR="${INSTALL_DIR}/downloads"
USE_VENV=true

# All rtorrent/ruTorrent data lives here – isolated from the rest of the system
RTORRENT_BASE="${INSTALL_DIR}/rtorrent"
RUTORRENT_BASE="${INSTALL_DIR}/rutorrent"

# Unique systemd / nginx names so this instance never clashes with others
SYSTEMD_SERVICE="only-uploader-rtorrent.service"
NGINX_VHOST_NAME="only-uploader-rutorrent"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-rtorrent)  INSTALL_RTORRENT=true ;;
        --install-rutorrent) INSTALL_RUTORRENT=true; INSTALL_RTORRENT=true ;;
        --rutorrent-port)    RUTORRENT_PORT="$2"; shift ;;
        --rpc-port)          RPC_PORT="$2"; shift ;;
        --bt-port)           BT_PORT="$2"; shift ;;
        --download-dir)      DOWNLOAD_DIR="$2"; shift ;;
        --no-venv)           USE_VENV=false ;;
        --help|-h)
            sed -n '/^# Usage/,/^# =====/p' "$0" | grep -v '^# ====' | sed 's/^# \?//'
            exit 0
            ;;
        *) warn "Unknown option: $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║       Only-Uploader Installer         ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"
echo "  Install dir       : ${INSTALL_DIR}"
echo "  Python venv       : ${VENV_DIR}"
echo "  rtorrent          : ${INSTALL_RTORRENT}"
echo "  ruTorrent         : ${INSTALL_RUTORRENT}"
if [[ "${INSTALL_RTORRENT}" == true ]]; then
echo "  rtorrent base dir : ${RTORRENT_BASE}"
echo "  Download dir      : ${DOWNLOAD_DIR}"
echo "  BT port           : ${BT_PORT}"
echo "  RPC (SCGI) port   : ${RPC_PORT}"
fi
if [[ "${INSTALL_RUTORRENT}" == true ]]; then
echo "  ruTorrent base dir: ${RUTORRENT_BASE}"
echo "  ruTorrent port    : ${RUTORRENT_PORT}"
fi
echo ""

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
info "Checking prerequisites…"

if [[ -z "${PYTHON_BIN}" ]]; then
    error "python3 not found. Please install Python 3.12 or higher and re-run."
fi

# Version check comes immediately after confirming python3 exists
"${PYTHON_BIN}" -c "
import sys
if sys.version_info < (3, 12):
    print('Python 3.12+ is required (found %s.%s)' % sys.version_info[:2])
    sys.exit(1)
" || error "Please upgrade Python to 3.12 or higher and re-run."

PY_VER=$("${PYTHON_BIN}" -c 'import sys; print("%s.%s.%s" % sys.version_info[:3])')
info "Found ${PYTHON_BIN} (${PY_VER})"

# ---------------------------------------------------------------------------
# Port conflict pre-flight (warn only – do not abort, user may intend a re-run)
# ---------------------------------------------------------------------------
_port_in_use() {
    ss -tlnp 2>/dev/null | grep -q ":${1} " || \
    netstat -tlnp 2>/dev/null | grep -q ":${1} " || \
    false
}

if [[ "${INSTALL_RUTORRENT}" == true ]] && _port_in_use "${RUTORRENT_PORT}"; then
    warn "Port ${RUTORRENT_PORT} is already in use."
    warn "Pass --rutorrent-port <N> to choose a different port, or stop the"
    warn "process using that port before starting Only-Uploader's ruTorrent."
fi

if [[ "${INSTALL_RTORRENT}" == true ]] && _port_in_use "${RPC_PORT}"; then
    warn "SCGI RPC port ${RPC_PORT} is already in use."
    warn "Pass --rpc-port <N> to choose a different port."
fi

# ---------------------------------------------------------------------------
# System packages (Debian/Ubuntu only)
# ---------------------------------------------------------------------------
if command -v apt-get &>/dev/null; then
    info "Installing system dependencies via apt…"
    sudo apt-get update -qq
    PKGS="ffmpeg mediainfo git g++ cargo mktorrent rustc mono-complete python3-venv python3-pip"
    if [[ "${INSTALL_RTORRENT}" == true ]]; then
        PKGS="${PKGS} rtorrent"
    fi
    if [[ "${INSTALL_RUTORRENT}" == true ]]; then
        PKGS="${PKGS} nginx php-fpm php-cli php-curl php-xml php-mbstring php-zip unzip"
    fi
    # shellcheck disable=SC2086
    sudo apt-get install -y --no-install-recommends ${PKGS}
    success "System packages installed."
else
    warn "apt-get not found – skipping system package installation."
    warn "Ensure ffmpeg, mediainfo, mktorrent, and mono are installed manually."
    if [[ "${INSTALL_RTORRENT}" == true ]]; then
        warn "Install rtorrent via your system package manager."
    fi
fi

# ---------------------------------------------------------------------------
# Python virtual environment
# ---------------------------------------------------------------------------
if [[ "${USE_VENV}" == true ]]; then
    info "Creating Python virtual environment at ${VENV_DIR}…"
    "${PYTHON_BIN}" -m venv "${VENV_DIR}"
    PIP="${VENV_DIR}/bin/pip"
    PYTHON="${VENV_DIR}/bin/python"
    success "Venv created."

    info "Upgrading pip and installing wheel…"
    "${PIP}" install --quiet --upgrade pip wheel

    info "Installing Python dependencies from requirements.txt…"
    "${PIP}" install --quiet -r "${INSTALL_DIR}/requirements.txt"
    success "Python dependencies installed."
else
    PYTHON="${PYTHON_BIN}"
    warn "--no-venv: using system Python – dependency conflicts may occur."
fi

# ---------------------------------------------------------------------------
# Config setup
# ---------------------------------------------------------------------------
CONFIG_SRC="${INSTALL_DIR}/data/example-config.py"
CONFIG_DST="${INSTALL_DIR}/data/config.py"

if [[ ! -f "${CONFIG_DST}" ]]; then
    info "Copying example-config.py to data/config.py…"
    cp "${CONFIG_SRC}" "${CONFIG_DST}"
    success "Config created at ${CONFIG_DST}"
    warn "Edit ${CONFIG_DST} and fill in your API keys before running uploads."
else
    info "data/config.py already exists – skipping copy."
fi

# ---------------------------------------------------------------------------
# Create download directory
# ---------------------------------------------------------------------------
mkdir -p "${DOWNLOAD_DIR}"
info "Download directory: ${DOWNLOAD_DIR}"

# ---------------------------------------------------------------------------
# rtorrent – fully isolated installation
# ---------------------------------------------------------------------------
if [[ "${INSTALL_RTORRENT}" == true ]]; then
    echo ""
    echo -e "${BOLD}── Isolated rtorrent Setup ─────────────────────${NC}"
    echo "   All files live under: ${RTORRENT_BASE}"
    echo "   System ~/.rtorrent.rc is NEVER read or modified."
    echo ""

    # ---- Create the isolated directory tree --------------------------------
    RTORRENT_CONF_FILE="${RTORRENT_BASE}/rtorrent.rc"
    RTORRENT_SESSION_DIR="${RTORRENT_BASE}/session"
    RTORRENT_WATCH_DIR="${RTORRENT_BASE}/watch"
    RTORRENT_LOG_FILE="${RTORRENT_BASE}/rtorrent.log"

    mkdir -p "${RTORRENT_SESSION_DIR}" "${RTORRENT_WATCH_DIR}"
    info "Created rtorrent directories under ${RTORRENT_BASE}"

    # ---- Write the isolated rtorrent config --------------------------------
    if [[ ! -f "${RTORRENT_CONF_FILE}" ]]; then
        info "Writing isolated rtorrent config to ${RTORRENT_CONF_FILE}…"
        cat > "${RTORRENT_CONF_FILE}" << RTCONF
# rtorrent config – generated by Only-Uploader installer
# This file is used EXCLUSIVELY by this Only-Uploader instance.
# The system ~/.rtorrent.rc is never loaded (rtorrent is started with -n).

# BitTorrent listen port (isolated – different from common defaults)
port_range = ${BT_PORT}-${BT_PORT}
port_random = no

# Default download directory for this instance
directory.default.set = ${DOWNLOAD_DIR}

# Session directory – stores active .torrent files for THIS instance only
session.path.set = ${RTORRENT_SESSION_DIR}

# Watch directory – drop .torrent files here to auto-load into this instance
schedule2 = only_uploader_watch, 5, 5, load.start=${RTORRENT_WATCH_DIR}/*.torrent

# SCGI/XML-RPC over loopback TCP (no UNIX socket – avoids www-data permission issues)
# Only accessible on localhost; this port is dedicated to this instance.
network.scgi.open_port = 127.0.0.1:${RPC_PORT}

# Logging
log.open_file = "only_uploader_log", ${RTORRENT_LOG_FILE}
log.add_output = "info", "only_uploader_log"

# Performance / misc
pieces.hash.on_completion.set = no
use_udp_trackers = yes
RTCONF
        success "Isolated rtorrent config written."
    else
        info "${RTORRENT_CONF_FILE} already exists – skipping."
    fi

    # ---- systemd service (unique name, explicit config, -n flag) -----------
    if command -v systemctl &>/dev/null; then
        SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SYSTEMD_SERVICE}"
        CURRENT_USER="$(whoami)"

        # Check if service already exists (idempotent re-run support)
        SERVICE_EXISTS=false
        if [[ -f "${SYSTEMD_SERVICE_FILE}" ]]; then
            info "${SYSTEMD_SERVICE} already exists – updating service file."
            SERVICE_EXISTS=true
        else
            info "Installing systemd service ${SYSTEMD_SERVICE}…"
        fi

        # Verify that an unrelated rtorrent.service is not already defined
        # (we deliberately use a different name, so this is just an info note).
        if systemctl list-unit-files rtorrent.service 2>/dev/null | grep -q "rtorrent.service"; then
            warn "Existing 'rtorrent.service' detected on this machine."
            warn "Only-Uploader uses '${SYSTEMD_SERVICE}' – no conflict."
        fi

        # The key isolation flags:
        #   -n  →  do NOT load ~/.rtorrent.rc  (ignore any user config)
        #   -o import=<path>  →  load THIS instance's config file only
        sudo tee "${SYSTEMD_SERVICE_FILE}" > /dev/null << RTSERVICE
[Unit]
Description=Only-Uploader rtorrent daemon (isolated instance)
Documentation=https://github.com/coreylad/Only-Uploader
After=network.target
# Deliberately NOT 'rtorrent.service' to avoid masking any existing instance

[Service]
User=${CURRENT_USER}
WorkingDirectory=${RTORRENT_BASE}
Type=simple
# -n  skips ~/.rtorrent.rc entirely
# -o import= loads only this instance's config
ExecStart=/usr/bin/rtorrent -n -o "import=${RTORRENT_CONF_FILE}"
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5
# Restrict the service to the install directory for extra containment
ReadWritePaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
RTSERVICE

        sudo systemctl daemon-reload
        sudo systemctl enable "${SYSTEMD_SERVICE}"

        if [[ "${SERVICE_EXISTS}" == true ]]; then
            sudo systemctl restart "${SYSTEMD_SERVICE}" || \
                warn "Could not restart ${SYSTEMD_SERVICE}. Run: sudo systemctl restart ${SYSTEMD_SERVICE}"
        else
            sudo systemctl start "${SYSTEMD_SERVICE}" || \
                warn "Could not start ${SYSTEMD_SERVICE}. Run: sudo systemctl start ${SYSTEMD_SERVICE}"
        fi
        success "${SYSTEMD_SERVICE} installed and enabled."
    else
        warn "systemctl not available. Use run_rtorrent.sh to start rtorrent manually."
    fi

    # ---- Write a standalone start/stop helper --------------------------------
    RUN_RTORRENT="${INSTALL_DIR}/run_rtorrent.sh"
    cat > "${RUN_RTORRENT}" << 'RTSCRIPT'
#!/usr/bin/env bash
# Only-Uploader – rtorrent helper script
# Usage: ./run_rtorrent.sh {start|stop|status|logs}
RTSCRIPT

    # Append vars that need interpolation (outside single-quoted heredoc)
    cat >> "${RUN_RTORRENT}" << RTSCRIPT2
RTORRENT_BASE="${RTORRENT_BASE}"
RTORRENT_CONF_FILE="${RTORRENT_CONF_FILE}"
RTORRENT_LOG_FILE="${RTORRENT_LOG_FILE}"
SYSTEMD_SERVICE="${SYSTEMD_SERVICE}"
RTSCRIPT2

    cat >> "${RUN_RTORRENT}" << 'RTSCRIPT3'
set -euo pipefail
case "${1:-start}" in
    start)
        if command -v systemctl &>/dev/null; then
            sudo systemctl start "${SYSTEMD_SERVICE}"
        else
            # Stand-alone start (no systemd): run in background, store PID
            nohup /usr/bin/rtorrent -n -o "import=${RTORRENT_CONF_FILE}" \
                > "${RTORRENT_LOG_FILE}" 2>&1 &
            echo $! > "${RTORRENT_BASE}/rtorrent.pid"
            echo "rtorrent started (PID $(cat "${RTORRENT_BASE}/rtorrent.pid"))"
        fi
        ;;
    stop)
        if command -v systemctl &>/dev/null; then
            sudo systemctl stop "${SYSTEMD_SERVICE}"
        else
            if [[ -f "${RTORRENT_BASE}/rtorrent.pid" ]]; then
                kill "$(cat "${RTORRENT_BASE}/rtorrent.pid")" && \
                    rm -f "${RTORRENT_BASE}/rtorrent.pid"
            else
                echo "PID file not found. Is rtorrent running?"
            fi
        fi
        ;;
    status)
        if command -v systemctl &>/dev/null; then
            systemctl status "${SYSTEMD_SERVICE}" --no-pager
        else
            [[ -f "${RTORRENT_BASE}/rtorrent.pid" ]] && \
                echo "rtorrent PID: $(cat "${RTORRENT_BASE}/rtorrent.pid")" || \
                echo "rtorrent does not appear to be running."
        fi
        ;;
    logs)
        tail -f "${RTORRENT_LOG_FILE}"
        ;;
    *)
        echo "Usage: $0 {start|stop|status|logs}"
        exit 1
        ;;
esac
RTSCRIPT3
    chmod +x "${RUN_RTORRENT}"
    success "run_rtorrent.sh written."

    success "Isolated rtorrent setup complete."
    echo ""
    echo "  Base directory   : ${RTORRENT_BASE}"
    echo "  Config file      : ${RTORRENT_CONF_FILE}"
    echo "  Session dir      : ${RTORRENT_SESSION_DIR}"
    echo "  Watch dir        : ${RTORRENT_WATCH_DIR}"
    echo "  Download dir     : ${DOWNLOAD_DIR}"
    echo "  SCGI/RPC port    : 127.0.0.1:${RPC_PORT}  (loopback only)"
    echo "  BitTorrent port  : ${BT_PORT}"
    echo "  systemd service  : ${SYSTEMD_SERVICE}"
    echo ""
    echo "  Add this block to TORRENT_CLIENTS in data/config.py:"
    echo ""
    echo '  "rtorrent_main": {'
    echo '      "torrent_client": "rtorrent",'
    echo "      \"rtorrent_url\": \"http://127.0.0.1:${RPC_PORT}/RPC2\","
    echo "      \"download_dir\": \"${DOWNLOAD_DIR}\","
    echo "      # \"torrent_storage_dir\": \"${RTORRENT_SESSION_DIR}\","
    echo "      # \"rtorrent_label\": \"only-uploader\","
    echo '  },'
    echo ""
fi

# ---------------------------------------------------------------------------
# ruTorrent – fully isolated installation
# ---------------------------------------------------------------------------
if [[ "${INSTALL_RUTORRENT}" == true ]]; then
    echo ""
    echo -e "${BOLD}── Isolated ruTorrent Setup ────────────────────${NC}"
    echo "   Web files live under: ${RUTORRENT_BASE}"
    echo "   nginx vhost name    : ${NGINX_VHOST_NAME}"
    echo "   No conflict with any existing ruTorrent/nginx setup."
    echo ""

    if ! command -v apt-get &>/dev/null; then
        warn "Non-Debian system – ruTorrent installation skipped. Install it manually."
    else
        info "Installing ruTorrent dependencies (nginx, php-fpm)…"
        sudo apt-get install -y --no-install-recommends \
            nginx \
            php-fpm \
            php-cli \
            php-curl \
            php-xml \
            php-mbstring \
            php-zip \
            unzip \
            git

        # ---- Clone ruTorrent into the isolated directory -------------------
        if [[ ! -d "${RUTORRENT_BASE}/.git" ]]; then
            info "Cloning ruTorrent into ${RUTORRENT_BASE}…"
            git clone --depth 1 https://github.com/Novik/ruTorrent.git "${RUTORRENT_BASE}"
            success "ruTorrent cloned."
        else
            info "ruTorrent already present at ${RUTORRENT_BASE} – skipping clone."
        fi

        # ---- Permissions so nginx can read the files -----------------------
        # ruTorrent is owned by the current user; give nginx (www-data) read +
        # execute access via world-readable bits – the directory is inside the
        # install dir, so no system-wide exposure.
        chmod -R o+rX "${RUTORRENT_BASE}"
        # The conf/ dir must be writable by nginx for plugin settings
        WEB_USER="www-data"
        sudo chown -R "${WEB_USER}:${WEB_USER}" "${RUTORRENT_BASE}/conf" 2>/dev/null || true
        sudo chmod -R 775 "${RUTORRENT_BASE}/conf" 2>/dev/null || true
        sudo chown -R "${WEB_USER}:${WEB_USER}" "${RUTORRENT_BASE}/share" 2>/dev/null || true
        sudo chmod -R 775 "${RUTORRENT_BASE}/share" 2>/dev/null || true

        # ---- Detect active PHP-FPM socket ----------------------------------
        PHP_SOCK=$(find /run/php/ -name "php*.fpm.sock" 2>/dev/null | sort | tail -1 || true)
        if [[ -z "${PHP_SOCK}" ]]; then
            PHP_SOCK="/run/php/php-fpm.sock"
            warn "Could not detect PHP-FPM socket; defaulting to ${PHP_SOCK}."
        fi
        info "Using PHP-FPM socket: ${PHP_SOCK}"

        # ---- nginx vhost (unique name, unique port) ------------------------
        NGINX_VHOST_FILE="/etc/nginx/sites-available/${NGINX_VHOST_NAME}"

        # Warn if the listen port is already occupied by a different vhost
        if [[ -f "${NGINX_VHOST_FILE}" ]]; then
            info "nginx vhost ${NGINX_VHOST_NAME} already exists – updating."
        fi

        info "Writing nginx vhost ${NGINX_VHOST_NAME} on port ${RUTORRENT_PORT}…"
        sudo tee "${NGINX_VHOST_FILE}" > /dev/null << NGINXCONF
# nginx vhost for Only-Uploader ruTorrent (isolated instance)
# File: /etc/nginx/sites-available/${NGINX_VHOST_NAME}
# Do NOT edit the rutorrent vhost at /etc/nginx/sites-available/rutorrent
# (if it exists) – that belongs to a different installation.
server {
    listen ${RUTORRENT_PORT};
    server_name _;

    root ${RUTORRENT_BASE};
    index index.html index.php;

    # Forward SCGI/XML-RPC to the Only-Uploader rtorrent instance via TCP.
    # This uses the loopback SCGI port – isolated to this instance only.
    location /RPC2 {
        include scgi_params;
        scgi_pass 127.0.0.1:${RPC_PORT};
    }

    location ~ \\.php\$ {
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location ~* \\.(css|js|png|jpg|jpeg|gif|ico|svg|woff2?|ttf)\$ {
        expires max;
        log_not_found off;
    }
}
NGINXCONF

        # Enable the vhost with a unique symlink name
        sudo ln -sf "${NGINX_VHOST_FILE}" \
            "/etc/nginx/sites-enabled/${NGINX_VHOST_NAME}" 2>/dev/null || true
        sudo nginx -t && sudo systemctl reload nginx
        success "nginx vhost ${NGINX_VHOST_NAME} configured."

        # ---- ruTorrent config.php – point at the isolated SCGI TCP port ----
        RUTORRENT_CONF_DIR="${RUTORRENT_BASE}/conf"
        RUTORRENT_CONFIG_PHP="${RUTORRENT_CONF_DIR}/config.php"
        if [[ -d "${RUTORRENT_CONF_DIR}" ]]; then
            sudo tee "${RUTORRENT_CONFIG_PHP}" > /dev/null << RUCONF
<?php
// ruTorrent config – generated by Only-Uploader installer (isolated instance)
// Connects to the Only-Uploader rtorrent via the dedicated loopback TCP port.
// This does NOT interfere with any other rtorrent/ruTorrent installation.
\$scgi_port = ${RPC_PORT};
\$scgi_host = "127.0.0.1";
\$XMLRPCMountPoint = "/RPC2";
RUCONF
            sudo chown "${WEB_USER}:${WEB_USER}" "${RUTORRENT_CONFIG_PHP}"
            success "ruTorrent config.php written (SCGI → 127.0.0.1:${RPC_PORT})."
        else
            warn "ruTorrent conf dir not found – configure manually."
        fi

        success "Isolated ruTorrent installation complete."
        echo ""
        echo "  ruTorrent web dir  : ${RUTORRENT_BASE}"
        echo "  nginx vhost file   : ${NGINX_VHOST_FILE}"
        echo "  Connects to rtorrent SCGI port: 127.0.0.1:${RPC_PORT}"
        echo ""
        echo "  Access ruTorrent at: http://localhost:${RUTORRENT_PORT}/"
        echo "  (Replace localhost with your server IP for remote access)"
        echo ""
        warn "ruTorrent has no authentication by default."
        warn "Add HTTP Basic Auth to ${NGINX_VHOST_FILE} before exposing to a network."
        echo ""
    fi
fi

# ---------------------------------------------------------------------------
# Convenience run scripts
# ---------------------------------------------------------------------------
info "Writing convenience scripts…"

RUN_UPLOAD="${INSTALL_DIR}/run_upload.sh"
cat > "${RUN_UPLOAD}" << RUNSCRIPT
#!/usr/bin/env bash
# Run Only-Uploader CLI
# Usage: ./run_upload.sh /path/to/content --trackers BLU AITHER
set -euo pipefail
source "${VENV_DIR}/bin/activate"
python "${INSTALL_DIR}/upload.py" "\$@"
RUNSCRIPT
chmod +x "${RUN_UPLOAD}"

RUN_WEBUI="${INSTALL_DIR}/run_webui.sh"
cat > "${RUN_WEBUI}" << WEBUISCRIPT
#!/usr/bin/env bash
# Start the Only-Uploader Web UI
# Pass --host 0.0.0.0 to listen on all interfaces
set -euo pipefail
source "${VENV_DIR}/bin/activate"
python "${INSTALL_DIR}/webui.py" "\$@"
WEBUISCRIPT
chmod +x "${RUN_WEBUI}"

success "Run scripts written: run_upload.sh  run_webui.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}Installation complete!${NC}"
echo ""
echo "  Next steps:"
echo "  1. Edit data/config.py and fill in your API keys & tracker settings."
if [[ "${INSTALL_RTORRENT}" == true ]]; then
echo "  2. Add the 'rtorrent_main' TORRENT_CLIENTS entry shown above."
echo "  3. Optionally set 'default_torrent_client': 'rtorrent_main' in DEFAULT."
fi
echo ""
echo "  CLI upload:"
echo "    ./run_upload.sh /path/to/content --trackers BLU AITHER"
echo ""
echo "  Cross-seed (download from AITHER, upload to BLU):"
echo "    ./run_upload.sh /path/to/content \\"
echo "        --download-from AITHER --source-id 12345 \\"
echo "        --trackers BLU"
echo ""
echo "  Web UI:"
echo "    ./run_webui.sh                    # binds to 127.0.0.1:5000"
echo "    ./run_webui.sh --host 0.0.0.0     # accessible on all interfaces"
if [[ "${INSTALL_RTORRENT}" == true ]]; then
echo ""
echo "  rtorrent control:"
echo "    ./run_rtorrent.sh start|stop|status|logs"
echo "    sudo systemctl status ${SYSTEMD_SERVICE}"
fi
if [[ "${INSTALL_RUTORRENT}" == true ]]; then
echo ""
echo "  ruTorrent UI: http://localhost:${RUTORRENT_PORT}/"
fi
echo ""

