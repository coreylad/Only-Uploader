# -*- coding: utf-8 -*-
"""
Cross-seed module: download torrent information from a source tracker
and prepare it for re-upload to one or more target trackers.

Supported source trackers (UNIT3D-based with public API):
    AITHER, BLU, LST, OE, TIK, ULCX, ACM, CBR, FNP, HUNO, JPTV,
    LCD, LT, OTW, PSS, RF, R4E, SHRI, UTP, YOINK, YUS, SP, LUME,
    STC, HHD, DP, PTT

For other trackers the caller must supply the local content path
manually; this class simply maps tracker API responses to *meta*.
"""

import os
import re
import asyncio
import requests

from src.console import console


# Map of tracker abbreviation -> base API URL for the torrent endpoint.
# All of these are UNIT3D instances that expose /api/torrents/<id>.
UNIT3D_API_MAP = {
    'AITHER': 'https://aither.cc/api/torrents',
    'BLU': 'https://blutopia.cc/api/torrents',
    'LST': 'https://lst.gg/api/torrents',
    'OE': 'https://onlyencodes.cc/api/torrents',
    'TIK': 'https://cinematik.net/api/torrents',
    'ULCX': 'https://upload.cx/api/torrents',
    'ACM': 'https://asiancinema.me/api/torrents',
    'CBR': 'https://capybarabr.com/api/torrents',
    'FNP': 'https://fearnopeer.com/api/torrents',
    'HUNO': 'https://hawke.uno/api/torrents',
    'JPTV': 'https://jptv.club/api/torrents',
    'LCD': 'https://locadora.cc/api/torrents',
    'LT': 'https://lat-team.com/api/torrents',
    'OTW': 'https://oldtoons.world/api/torrents',
    'PSS': 'https://privatesilverscreen.cc/api/torrents',
    'RF': 'https://reelflix.xyz/api/torrents',
    'R4E': 'https://racing4everyone.eu/api/torrents',
    'SHRI': 'https://shareisland.org/api/torrents',
    'UTP': 'https://utp.to/api/torrents',
    'YOINK': 'https://yoinked.org/api/torrents',
    'YUS': 'https://yu-scene.net/api/torrents',
    'SP': 'https://seedpool.org/api/torrents',
    'LUME': 'https://luminarr.me/api/torrents',
    'STC': 'https://skipthecommercials.xyz/api/torrents',
    'HHD': 'https://homiehelpdesk.net/api/torrents',
    'DP': 'https://darkpeers.org/api/torrents',
    'PTT': 'https://polishtorrent.top/api/torrents',
    'AL': 'https://animelovers.club/api/torrents',
    'HP': 'https://hidden-palace.net/api/torrents',
}

# Category ID -> string used by UNIT3D instances
UNIT3D_CAT_MAP = {
    1: 'MOVIE',
    2: 'TV',
}

# Type ID -> string used by this tool
UNIT3D_TYPE_MAP = {
    1: 'DISC',
    2: 'REMUX',
    3: 'ENCODE',
    4: 'WEBDL',
    5: 'WEBRIP',
    6: 'HDTV',
}

# Resolution ID -> string
UNIT3D_RES_MAP = {
    1: '4320p',
    2: '2160p',
    3: '1080p',
    4: '1080i',
    5: '720p',
    6: '576p',
    7: '576i',
    8: '480p',
    9: '480i',
    10: 'OTHER',
}


class CrossSeedDownloader:
    """
    Download torrent/release metadata from a supported source tracker
    and populate the *meta* dictionary used by the rest of the upload
    pipeline.

    Usage
    -----
    downloader = CrossSeedDownloader(config)
    meta = await downloader.fetch_meta(
        source_tracker='AITHER',
        torrent_id='12345',
        meta=meta,
    )
    # meta is now enriched with title, tmdb, imdb, description, etc.
    """

    def __init__(self, config):
        self.config = config

    # ------------------------------------------------------------------
    # Public helpers
    # ------------------------------------------------------------------

    def is_supported(self, tracker):
        """Return True if *tracker* is a supported download source."""
        return tracker.upper() in UNIT3D_API_MAP

    async def fetch_meta(self, source_tracker, torrent_id, meta):
        """
        Fetch release metadata from *source_tracker* for *torrent_id*
        and merge it into *meta*.

        Parameters
        ----------
        source_tracker : str
            Uppercase tracker abbreviation (e.g. 'AITHER').
        torrent_id : str | int
            Numeric torrent ID on the source tracker.
        meta : dict
            Existing meta dict (will be updated in-place and returned).

        Returns
        -------
        dict
            Updated *meta*.
        """
        source_tracker = source_tracker.upper().strip()

        if source_tracker not in UNIT3D_API_MAP:
            console.print(
                f"[bold red]Cross-seed: tracker '{source_tracker}' is not "
                "supported as a download source. "
                "Supported: " + ", ".join(sorted(UNIT3D_API_MAP)) + "[/bold red]"
            )
            return meta

        api_key = self.config.get('TRACKERS', {}).get(source_tracker, {}).get('api_key', '').strip()
        if not api_key:
            console.print(
                f"[bold red]Cross-seed: no api_key configured for "
                f"'{source_tracker}' in config.py[/bold red]"
            )
            return meta

        base_url = UNIT3D_API_MAP[source_tracker]
        url = f"{base_url}/{torrent_id}"
        params = {'api_token': api_key}
        headers = {'Accept': 'application/json'}

        console.print(
            f"[cyan]Cross-seed: fetching metadata from {source_tracker} "
            f"(torrent id: {torrent_id}) …[/cyan]"
        )

        try:
            loop = asyncio.get_event_loop()
            resp = await loop.run_in_executor(
                None,
                lambda: requests.get(url, params=params, headers=headers, timeout=15)
            )
            resp.raise_for_status()
            data = resp.json()
        except requests.RequestException as exc:
            console.print(f"[bold red]Cross-seed: HTTP error – {exc}[/bold red]")
            return meta
        except ValueError:
            console.print("[bold red]Cross-seed: invalid JSON in tracker response[/bold red]")
            return meta

        torrent_data = data.get('data', data)
        if isinstance(torrent_data, dict) and 'attributes' in torrent_data:
            attrs = torrent_data['attributes']
        else:
            attrs = torrent_data

        meta = self._map_unit3d_attrs(attrs, meta, source_tracker)
        console.print(
            f"[green]Cross-seed: metadata fetched from {source_tracker}[/green]"
        )
        return meta

    async def download_torrent_file(self, source_tracker, torrent_id, dest_path):
        """
        Download the raw .torrent file from *source_tracker* and write
        it to *dest_path*.

        Returns True on success, False on failure.
        """
        source_tracker = source_tracker.upper().strip()

        if source_tracker not in UNIT3D_API_MAP:
            console.print(
                f"[bold red]Cross-seed: tracker '{source_tracker}' is not "
                "supported as a download source.[/bold red]"
            )
            return False

        api_key = self.config.get('TRACKERS', {}).get(source_tracker, {}).get('api_key', '').strip()
        if not api_key:
            console.print(
                f"[bold red]Cross-seed: no api_key configured for '{source_tracker}'[/bold red]"
            )
            return False

        base_url = UNIT3D_API_MAP[source_tracker]
        url = f"{base_url}/{torrent_id}/download"
        params = {'api_token': api_key}

        console.print(
            f"[cyan]Cross-seed: downloading .torrent from {source_tracker} "
            f"(id: {torrent_id}) …[/cyan]"
        )

        try:
            loop = asyncio.get_event_loop()
            resp = await loop.run_in_executor(
                None,
                lambda: requests.get(url, params=params, timeout=30, stream=True)
            )
            resp.raise_for_status()
            os.makedirs(os.path.dirname(dest_path), exist_ok=True)
            with open(dest_path, 'wb') as fh:
                for chunk in resp.iter_content(chunk_size=8192):
                    fh.write(chunk)
        except requests.RequestException as exc:
            console.print(f"[bold red]Cross-seed: failed to download .torrent – {exc}[/bold red]")
            return False

        console.print(f"[green]Cross-seed: .torrent saved to {dest_path}[/green]")
        return True

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _map_unit3d_attrs(self, attrs, meta, source_tracker):
        """
        Map a UNIT3D /api/torrents/<id> attributes payload onto *meta*.
        Only fields that are *not already set* in *meta* are populated
        so that explicit CLI overrides are not clobbered.
        """

        def _set(key, value):
            if value is not None and meta.get(key) in (None, '', 0, '0', []):
                meta[key] = value

        # Title / name
        name = attrs.get('name') or attrs.get('title')
        if name:
            _set('title', name)
            _set('name', name)

        # IDs
        _set('tmdb', str(attrs.get('tmdb_id', '') or ''))
        _set('imdb_id', str(attrs.get('imdb_id', '') or '').zfill(7) if attrs.get('imdb_id') else None)
        _set('tvdb_id', str(attrs.get('tvdb_id', '') or ''))
        _set('mal_id', str(attrs.get('mal_id', '') or ''))

        # Category / type / resolution
        cat_raw = attrs.get('category_id') or attrs.get('category')
        if isinstance(cat_raw, int):
            cat_str = UNIT3D_CAT_MAP.get(cat_raw)
            if cat_str:
                _set('category', cat_str)
        elif isinstance(cat_raw, str) and cat_raw.upper() in ('MOVIE', 'TV'):
            _set('category', cat_raw.upper())

        type_raw = attrs.get('type_id') or attrs.get('type')
        if isinstance(type_raw, int):
            type_str = UNIT3D_TYPE_MAP.get(type_raw)
            if type_str:
                _set('type', type_str)
        elif isinstance(type_raw, str):
            _set('type', type_raw.upper())

        res_raw = attrs.get('resolution_id') or attrs.get('resolution')
        if isinstance(res_raw, int):
            res_str = UNIT3D_RES_MAP.get(res_raw)
            if res_str:
                _set('resolution', res_str)
        elif isinstance(res_raw, str):
            _set('resolution', res_raw)

        # Description / overview
        desc = attrs.get('description') or attrs.get('overview')
        if desc:
            _set('overview', desc)

        # Year – extract from name if not provided directly
        year = attrs.get('year')
        if not year and name:
            m = re.search(r'\b(19\d{2}|20\d{2})\b', name)
            if m:
                year = int(m.group(1))
        if year:
            _set('year', int(year))

        # Season / episode
        _set('season_int', attrs.get('season_number'))
        _set('episode_int', attrs.get('episode_number'))

        # Tags / keywords
        tags = attrs.get('tags') or attrs.get('keywords')
        if isinstance(tags, list):
            _set('keywords', ', '.join(str(t) for t in tags))
        elif isinstance(tags, str):
            _set('keywords', tags)

        # Source tracker reference (for provenance)
        meta['cross_seed_source'] = source_tracker

        return meta
