# Only-Uploader

# Updated to work with new Unit3d Updates with hash downloads. Blu,RF,YS are updated

Forked from L4G Upload Assistant, thanks for all the work L4G on this tool and all the forks and updates. Shoutout Audionut and Uploarr

This fork is being maintained by OE.

A simple tool to take the work out of uploading.

## What It Can Do:
  - Generates and Parses MediaInfo/BDInfo.
  - Generates and Uploads screenshots.
  - Uses srrdb to fix scene filenames
  - Can grab descriptions from PTP (automatically on filename match or arg) / BLU (arg)
  - Obtains TMDb/IMDb/MAL identifiers.
  - Converts absolute to season episode numbering for Anime
  - Generates custom .torrents without useless top level folders/nfos.
  - Can re-use existing torrents instead of hashing new
  - Generates proper name for your upload using Mediainfo/BDInfo and TMDb/IMDb conforming to site rules
  - Checks for existing releases already on site
  - Uploads to OE/PTP/BLU/BHD/Aither/THR/R4E(limited)/HP/ACM/LCD/LST/NBL/ANT/FL/HUNO/RF/SN/RTF/OTW/FNP/CBR/UTP/AL/ULCX/HDB/YOINK/TVC/TIK/SPD/SHRI/PTT/PSS/YS/SP/LUME/STC
  - Adds to your client with fast resume, seeding instantly (rtorrent/qbittorrent/deluge/watch folder)
  - ALL WITH MINIMAL INPUT!
  - Currently works with .mkv/.mp4/Blu-ray/DVD/HD-DVDs

  Built with updated BDInfoCLI from https://github.com/rokibhasansagar/BDInfoCLI-ng

  ## Image Hosts:
  - OnlyImage - onlyimage
  - ImgBB - imgbb
  - PTPimg - ptpimg
  - ImageBox - imgbox
  - PixHost - pixhost
  - LensDump - lensdump
  - PTScreens - ptscreens

## Coming Soon:
  - Features
  - Rebase

## **Setup:**

### Prerequisites

**Python 3.12 or newer is required.** Verify your version with:
```bash
python3 --version
```

You will also need **Git**, **MediaInfo**, **ffmpeg**, and (on Linux) **mono** installed before running the tool.

#### Linux (Debian/Ubuntu)
```bash
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv git ffmpeg mediainfo mono-complete
```

#### Linux (Fedora/RHEL/CentOS)
```bash
sudo dnf install -y python3 python3-pip git ffmpeg mediainfo mono-complete
```

#### macOS (Homebrew)
```bash
brew install python git ffmpeg mediainfo
# mono is not required on macOS
```

#### Windows
1. Install **Python 3.12+** from https://www.python.org/downloads/ — check "Add Python to PATH" during setup.
2. Install **Git** from https://git-scm.com/download/win.
3. Install **MediaInfo CLI** from https://mediaarea.net/en/MediaInfo/Download/Windows.
4. Install **ffmpeg** and add it to your PATH: https://windowsloop.com/install-ffmpeg-windows-10/

---

### Installation Steps

1. **Clone the repository:**
   ```bash
   git clone https://github.com/coreylad/Only-Uploader.git
   cd Only-Uploader
   ```

2. **Create and activate a virtual environment** *(recommended)*:
   ```bash
   # Linux / macOS
   python3 -m venv venv
   source venv/bin/activate

   # Windows (Command Prompt)
   python -m venv venv
   venv\Scripts\activate.bat

   # Windows (PowerShell)
   python -m venv venv
   venv\Scripts\Activate.ps1
   ```

3. **Install Python dependencies:**
   ```bash
   pip install -U -r requirements.txt
   ```

4. **Create your config file:**

   Linux / macOS:
   ```bash
   cp data/example-config.py data/config.py
   ```
   Windows (Command Prompt):
   ```bat
   copy data\example-config.py data\config.py
   ```

5. **Edit `data/config.py`** and fill in your API keys and settings:
   - `tmdb_api` — create a free account and request a v3 API key at https://developers.themoviedb.org/3/getting-started/introduction
   - Tracker `api_key` / `announce_url` values — obtain from each tracker's settings page
   - Image host API keys — obtain from each host's settings page
   - Torrent client connection details (qBittorrent, rtorrent, Deluge, or watch folder)

   > More detailed config documentation is in the [wiki](https://github.com/coreylad/Only-Uploader/wiki).

---

### Web Panel Setup

Only-Uploader includes a browser-based web panel for configuring settings and triggering uploads without using the command line.

**Start the web panel:**
```bash
python3 web/app.py
```
Then open **http://localhost:5000** in your browser.

To bind to a different host or port, set the environment variables `WEBUI_HOST` and `WEBUI_PORT` before starting:
```bash
WEBUI_HOST=0.0.0.0 WEBUI_PORT=8080 python3 web/app.py
```

---

**Additional Resources are found in the [wiki](https://github.com/coreylad/Only-Uploader/wiki)**

Feel free to contact me if you need help, I'm not that hard to find.

## **Updating:**
  1. Navigate into the Only-Uploader directory: `cd Only-Uploader`
  2. Pull the latest changes: `git pull`
  3. Re-activate your virtual environment if you created one (see step 2 above).
  4. Update Python dependencies:
     ```bash
     pip install -U -r requirements.txt
     ```

## **CLI Usage:**

```bash
python3 upload.py /downloads/path/to/content [--args]
```

Args are OPTIONAL. For a full list of available arguments, run:
```bash
python3 upload.py --help
```

## **Docker Usage:**

Only-Uploader ships with a `Dockerfile` and `docker-compose.yml` for a fully containerised setup.

### Quick start (web panel)
```bash
# 1. Copy and edit the config
cp data/example-config.py data/config.py
# (edit data/config.py with your API keys)

# 2. Start the container
docker compose up -d

# 3. Open the web panel
#    http://localhost:5000
```

The `docker-compose.yml` mounts `data/config.py` automatically. Uncomment the media volume line in the file to expose your download folder inside the container.

### CLI via Docker
```bash
docker compose run --rm only-uploader /media/path/to/content --args
```

> For full Docker documentation, visit the [docker usage wiki page](https://github.com/coreylad/Only-Uploader/wiki/Docker).
