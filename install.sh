#!/usr/bin/env bash
# =============================================================================
# Only-Uploader – Easy Installer
# =============================================================================
# Sets up a fully self-contained environment including:
#   • Python virtual environment with all dependencies
#   • Optional rtorrent daemon (for seeding / downloading content)
#   • Optional ruTorrent web UI for rtorrent  (Nginx + PHP-FPM)
#   • Convenience run scripts (run_upload.sh, run_webui.sh)
#   • Starter config copied from example-config.py
#
# Usage:
#   bash install.sh [OPTIONS]
#
# Options:
#   --install-rtorrent    Install rtorrent daemon
#   --install-rutorrent   Install ruTorrent web UI (requires --install-rtorrent)
#   --rutorrent-port N    Port for ruTorrent nginx vhost (default: 8080)
#   --download-dir PATH   Default directory rtorrent saves downloads to
#                         (default: <install-dir>/downloads)
#   --no-venv             Skip venv creation (use system Python – not recommended)
#   --help                Show this help
#
# Supported OS: Debian / Ubuntu (apt-based).
# On other systems the Python venv steps still work; skip the rtorrent/ruTorrent
# steps and install those packages via your system package manager.
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
RUTORRENT_PORT=8080
DOWNLOAD_DIR="${INSTALL_DIR}/downloads"
USE_VENV=true

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
echo "  Install dir   : ${INSTALL_DIR}"
echo "  Python venv   : ${VENV_DIR}"
echo "  rtorrent      : ${INSTALL_RTORRENT}"
echo "  ruTorrent     : ${INSTALL_RUTORRENT}"
echo "  Download dir  : ${DOWNLOAD_DIR}"
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
# System packages (Debian/Ubuntu only)
# ---------------------------------------------------------------------------
if command -v apt-get &>/dev/null; then
    info "Installing system dependencies via apt…"
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends \
        ffmpeg \
        mediainfo \
        git \
        g++ \
        cargo \
        mktorrent \
        rustc \
        mono-complete \
        python3-venv \
        python3-pip
    success "System packages installed."
else
    warn "apt-get not found – skipping system package installation."
    warn "Ensure ffmpeg, mediainfo, mktorrent, and mono are installed manually."
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
# rtorrent installation
# ---------------------------------------------------------------------------
if [[ "${INSTALL_RTORRENT}" == true ]]; then
    echo ""
    echo -e "${BOLD}── rtorrent Setup ──────────────────────────────${NC}"

    if command -v apt-get &>/dev/null; then
        info "Installing rtorrent…"
        sudo apt-get install -y --no-install-recommends rtorrent screen
        success "rtorrent installed."
    else
        warn "Non-Debian system detected. Install rtorrent via your package manager."
    fi

    RTORRENT_HOME="${HOME}"
    RTORRENT_SESSION_DIR="${RTORRENT_HOME}/.rtorrent/session"
    RTORRENT_WATCH_DIR="${RTORRENT_HOME}/.rtorrent/watch"
    RTORRENT_CONF="${RTORRENT_HOME}/.rtorrent.rc"

    mkdir -p "${RTORRENT_SESSION_DIR}" "${RTORRENT_WATCH_DIR}"

    # Write a default rtorrent config only if one does not already exist
    if [[ ! -f "${RTORRENT_CONF}" ]]; then
        info "Writing default rtorrent config to ${RTORRENT_CONF}…"
        cat > "${RTORRENT_CONF}" << RTCONF
# rtorrent config – generated by Only-Uploader installer

# Listening port range
port_range = 51413-51413

# Save downloaded content here by default
directory.default.set = ${DOWNLOAD_DIR}

# Session directory (stores .torrent files)
session.path.set = ${RTORRENT_SESSION_DIR}

# Watch folder: drop .torrent files here for automatic loading
schedule2 = watch_directory, 5, 5, load.start=${RTORRENT_WATCH_DIR}/*.torrent

# XML-RPC socket (used by Only-Uploader and ruTorrent)
network.scgi.open_local = ${RTORRENT_HOME}/.rtorrent/rpc.socket
scgi_local = ${RTORRENT_HOME}/.rtorrent/rpc.socket

# Logging
log.open_file = "log", ${RTORRENT_HOME}/.rtorrent/rtorrent.log
log.add_output = "info", "log"

# Misc
pieces.hash.on_completion.set = no
use_udp_trackers = yes
RTCONF
        success "rtorrent config written."
    else
        info "${RTORRENT_CONF} already exists – skipping."
    fi

    # systemd service for rtorrent
    if command -v systemctl &>/dev/null; then
        RTORRENT_SERVICE="/etc/systemd/system/rtorrent.service"
        CURRENT_USER="$(whoami)"
        info "Installing rtorrent systemd service…"
        sudo tee "${RTORRENT_SERVICE}" > /dev/null << RTSERVICE
[Unit]
Description=rtorrent daemon
After=network.target

[Service]
User=${CURRENT_USER}
Type=forking
ExecStart=/usr/bin/screen -dmS rtorrent /usr/bin/rtorrent
ExecStop=/usr/bin/screen -S rtorrent -X quit
Restart=on-failure

[Install]
WantedBy=multi-user.target
RTSERVICE
        sudo systemctl daemon-reload
        sudo systemctl enable rtorrent.service
        sudo systemctl start  rtorrent.service || warn "Could not start rtorrent service – start it manually with: sudo systemctl start rtorrent"
        success "rtorrent systemd service installed and enabled."
    else
        warn "systemctl not available. Start rtorrent manually: screen -dmS rtorrent rtorrent"
    fi

    # Inject rtorrent client entry into config.py if the placeholder is present
    if grep -q '"rtorrent_sample"' "${CONFIG_DST}" 2>/dev/null; then
        warn "Found rtorrent_sample in config.py – please rename/fill it in manually."
    fi

    success "rtorrent setup complete."
    echo ""
    echo "  rtorrent XML-RPC socket : ${RTORRENT_HOME}/.rtorrent/rpc.socket"
    echo "  Download directory       : ${DOWNLOAD_DIR}"
    echo "  Session directory        : ${RTORRENT_SESSION_DIR}"
    echo ""
    echo "  Add this block to the TORRENT_CLIENTS section in data/config.py:"
    echo ""
    echo '  "rtorrent_main": {'
    echo '      "torrent_client": "rtorrent",'
    echo "      # Without ruTorrent: connect directly via the UNIX socket (scgi:// scheme)"
    echo "      # xmlrpc.client does not support scgi:// natively; install scgi2xmlrpc or"
    echo "      # use an HTTP proxy.  With ruTorrent installed, use the nginx /RPC2 endpoint:"
    echo "      \"rtorrent_url\": \"http://127.0.0.1:${RUTORRENT_PORT}/RPC2\","
    echo "      \"download_dir\": \"${DOWNLOAD_DIR}\","
    echo "      # \"torrent_storage_dir\": \"${RTORRENT_SESSION_DIR}\","
    echo "      # \"rtorrent_label\": \"only-uploader\","
    echo '  },'
    echo ""
    if [[ "${INSTALL_RUTORRENT}" == false ]]; then
        warn "Note: the rtorrent_url above requires ruTorrent or a local HTTP/SCGI proxy."
        warn "Run with --install-rutorrent to set that up automatically, or configure"
        warn "your own SCGI-to-HTTP bridge and update rtorrent_url accordingly."
    fi
fi

# ---------------------------------------------------------------------------
# ruTorrent installation (Nginx + PHP-FPM)
# ---------------------------------------------------------------------------
if [[ "${INSTALL_RUTORRENT}" == true ]]; then
    echo ""
    echo -e "${BOLD}── ruTorrent Setup ─────────────────────────────${NC}"

    if ! command -v apt-get &>/dev/null; then
        warn "Non-Debian system – ruTorrent installation skipped. Install it manually."
    else
        info "Installing ruTorrent dependencies (nginx, php-fpm, lighttpd tools)…"
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

        RUTORRENT_DIR="/var/www/rutorrent"
        RUTORRENT_CONF_DIR="${RUTORRENT_DIR}/conf"

        if [[ ! -d "${RUTORRENT_DIR}" ]]; then
            info "Cloning ruTorrent into ${RUTORRENT_DIR}…"
            sudo git clone --depth 1 https://github.com/Novik/ruTorrent.git "${RUTORRENT_DIR}"
            success "ruTorrent cloned."
        else
            info "ruTorrent already present at ${RUTORRENT_DIR} – skipping clone."
        fi

        # Detect active PHP-FPM socket
        PHP_SOCK=$(find /run/php/ -name "php*.fpm.sock" 2>/dev/null | sort | tail -1 || true)
        if [[ -z "${PHP_SOCK}" ]]; then
            PHP_SOCK="/run/php/php-fpm.sock"
            warn "Could not detect PHP-FPM socket; defaulting to ${PHP_SOCK}."
        fi
        info "Using PHP-FPM socket: ${PHP_SOCK}"

        NGINX_VHOST="/etc/nginx/sites-available/rutorrent"
        info "Writing nginx vhost for ruTorrent on port ${RUTORRENT_PORT}…"
        sudo tee "${NGINX_VHOST}" > /dev/null << NGINXCONF
server {
    listen ${RUTORRENT_PORT};
    server_name _;

    root ${RUTORRENT_DIR};
    index index.html index.php;

    # ruTorrent SCGI / RPC pass-through to rtorrent socket
    location /RPC2 {
        include scgi_params;
        scgi_pass unix:${RTORRENT_HOME:-$HOME}/.rtorrent/rpc.socket;
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

        sudo ln -sf "${NGINX_VHOST}" /etc/nginx/sites-enabled/rutorrent 2>/dev/null || true
        sudo nginx -t && sudo systemctl reload nginx
        success "Nginx vhost for ruTorrent configured."

        # Ownership
        WEB_USER="www-data"
        sudo chown -R "${WEB_USER}:${WEB_USER}" "${RUTORRENT_DIR}"
        sudo chmod -R 755 "${RUTORRENT_DIR}"

        # ruTorrent config: point it at the rtorrent UNIX socket directly.
        # ruTorrent PHP connects to rtorrent via SCGI; we give it the socket path.
        RT_SCGI_SOCKET="${HOME}/.rtorrent/rpc.socket"
        RUTORRENT_CONFIG_PHP="${RUTORRENT_CONF_DIR}/config.php"
        if [[ -d "${RUTORRENT_CONF_DIR}" ]]; then
            # Write the config using a variable – can't use single-quote heredoc here
            sudo tee "${RUTORRENT_CONFIG_PHP}" > /dev/null << RUCONF
<?php
// ruTorrent config – generated by Only-Uploader installer
// Connect directly to the rtorrent UNIX SCGI socket.
\$scgi_port = 0;
\$scgi_host = "unix://${RT_SCGI_SOCKET}";
\$XMLRPCMountPoint = "/RPC2";
RUCONF
            sudo chown "${WEB_USER}:${WEB_USER}" "${RUTORRENT_CONFIG_PHP}"
            success "ruTorrent config written (SCGI socket: ${RT_SCGI_SOCKET})."
        else
            warn "ruTorrent conf dir not found at ${RUTORRENT_CONF_DIR} – configure manually."
        fi

        success "ruTorrent installation complete."
        echo ""
        echo "  Access ruTorrent at: http://localhost:${RUTORRENT_PORT}/"
        echo "  (Replace localhost with your server IP if accessing remotely)"
        echo ""
        warn "ruTorrent has no authentication by default."
        warn "Add HTTP Basic Auth in the nginx vhost (${NGINX_VHOST}) before"
        warn "exposing it to a network."
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
echo "  2. Add an 'rtorrent_main' entry to TORRENT_CLIENTS in data/config.py"
echo "     (see the block printed above)."
echo "  3. Set 'default_torrent_client': 'rtorrent_main' in DEFAULT (optional)."
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
if [[ "${INSTALL_RUTORRENT}" == true ]]; then
echo ""
echo "  ruTorrent:  http://localhost:${RUTORRENT_PORT}/"
fi
echo ""
