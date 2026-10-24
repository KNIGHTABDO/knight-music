"""YouTube Music support for the app: a self-updating yt-dlp, the live InnerTube client table, an audio
fallback and "Add to Navidrome".

yt-dlp is kept as the standalone zipapp in DATA_DIR/bin and updated daily (and right away when an
extraction fails), so the server keeps working the day YouTube changes something. The app reads the client
table from here, which is yt-dlp's own INNERTUBE_CLIENTS, so phones pick up new client versions too.
"""
from __future__ import annotations

import json
import logging
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

log = logging.getLogger("automix.youtube")

DATA_DIR = os.environ.get("AUTOMIX_DATA", os.path.expanduser("~/automix/data"))
NAVIDROME_URL = os.environ.get("AUTOMIX_NAVIDROME_URL", "http://127.0.0.1:4533")
MUSIC_DIR = os.environ.get("AUTOMIX_MUSIC_DIR", os.path.expanduser("~/Music"))
BIN = os.path.join(DATA_DIR, "bin", "yt-dlp")
CACHE = os.path.join(DATA_DIR, "yt-cache")
RELEASE = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp"
UPDATE_EVERY = 24 * 3600
CACHE_LIMIT = 2 << 30
VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
CLIENT_KEYS = ("visionos", "ios", "web_music", "web", "mweb", "android_vr", "tv", "android", "android_music")

_dump = r"""
import json, sys
sys.path.insert(0, sys.argv[1])
from yt_dlp.extractor.youtube._base import INNERTUBE_CLIENTS
import yt_dlp.version
keys = sys.argv[2].split(",")
out = {}
for key in keys:
    c = INNERTUBE_CLIENTS.get(key)
    if not c:
        continue
    client = dict(c["INNERTUBE_CONTEXT"]["client"])
    out[key] = {"context": client, "id": c.get("INNERTUBE_CONTEXT_CLIENT_NAME"),
                "host": c.get("INNERTUBE_HOST"), "requireJs": bool(c.get("REQUIRE_JS_PLAYER")),
                "requirePoToken": bool(c.get("PO_TOKEN_REQUIRED_CONTEXTS"))}
print(json.dumps({"ytdlp": yt_dlp.version.__version__, "clients": out}))
"""


class YouTube:
    def __init__(self):
        self.lock = threading.Lock()
        self.update_lock = threading.Lock()
        self.last_update = 0.0
        self.clients: dict | None = None
        self.fetching: dict[str, threading.Event] = {}
        self.imports: dict[str, dict] = {}
        os.makedirs(CACHE, exist_ok=True)
        os.makedirs(os.path.dirname(BIN), exist_ok=True)

    # MARK: yt-dlp

    def start(self):
        threading.Thread(target=self._updater, name="yt-dlp-updater", daemon=True).start()

    def _updater(self):
        while True:
            try:
                self.update()
            except Exception:
                log.exception("yt-dlp update failed")
            time.sleep(UPDATE_EVERY)

    def update(self, force: bool = False) -> None:
        """Downloads the latest yt-dlp release. At most once an hour unless the binary is missing."""
        with self.update_lock:
            if os.path.exists(BIN) and not force and time.time() - self.last_update < 3600:
                return
            tmp = BIN + ".new"
            req = urllib.request.Request(RELEASE, headers={"User-Agent": "knight-automix"})
            with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "wb") as f:
                shutil.copyfileobj(resp, f)
            os.chmod(tmp, 0o755)
            os.replace(tmp, BIN)
            self.last_update = time.time()
            with self.lock:
                self.clients = None
            log.info("yt-dlp updated: %s", self.version())

    def version(self) -> str | None:
        try:
            return subprocess.run([sys.executable, BIN, "--version"], capture_output=True, text=True,
                                  timeout=30).stdout.strip() or None
        except (OSError, subprocess.SubprocessError):
            return None

    def _run(self, args: list[str], timeout: int) -> subprocess.CompletedProcess:
        if not os.path.exists(BIN):
            self.update(force=True)
        cmd = [sys.executable, BIN, "--no-warnings", "--no-progress", "--ffmpeg-location", shutil.which("ffmpeg") or "ffmpeg"] + args
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if result.returncode != 0:
            # The usual reason is a YouTube change a newer yt-dlp already handles.
            log.warning("yt-dlp failed (%s), updating and retrying", result.stderr.strip()[-300:])
            try:
                self.update()
            except Exception:
                log.exception("yt-dlp update failed")
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result

    def client_table(self) -> dict:
        with self.lock:
            if self.clients and time.time() - self.clients["at"] < 3600:
                return self.clients["data"]
        if not os.path.exists(BIN):
            self.update(force=True)
        out = subprocess.run([sys.executable, "-c", _dump, BIN, ",".join(CLIENT_KEYS)],
                             capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip()[-300:])
        data = json.loads(out.stdout)
        with self.lock:
            self.clients = {"at": time.time(), "data": data}
        return data

    # MARK: Audio fallback

    def audio_path(self, video_id: str) -> str:
        """Downloads (once) and returns the m4a for `video_id`; concurrent requests share one download."""
        path = os.path.join(CACHE, f"{video_id}.m4a")
        if os.path.exists(path):
            os.utime(path)
            return path
        with self.lock:
            event = self.fetching.get(video_id)
            owner = event is None
            if owner:
                event = self.fetching[video_id] = threading.Event()
        if not owner:
            event.wait(300)
            if os.path.exists(path):
                return path
            raise RuntimeError("download failed")
        try:
            tmp = os.path.join(CACHE, f"{video_id}.part.m4a")
            result = self._run(["-f", "140/139/bestaudio[ext=m4a]", "--no-playlist", "-o", tmp,
                                f"https://music.youtube.com/watch?v={video_id}"], timeout=300)
            if result.returncode != 0 or not os.path.exists(tmp):
                raise RuntimeError(result.stderr.strip()[-300:] or "yt-dlp failed")
            os.replace(tmp, path)
            self._trim_cache()
            return path
        finally:
            with self.lock:
                self.fetching.pop(video_id, None)
            event.set()

    def _trim_cache(self):
        files = [os.path.join(CACHE, f) for f in os.listdir(CACHE) if f.endswith(".m4a") and ".part" not in f]
        files.sort(key=lambda p: os.path.getmtime(p))
        total = sum(os.path.getsize(p) for p in files)
        while files and total > CACHE_LIMIT:
            victim = files.pop(0)
            total -= os.path.getsize(victim)
            os.remove(victim)

    # MARK: Add to Navidrome

    def start_import(self, video_id: str, meta: dict, auth: dict) -> dict:
        with self.lock:
            job = self.imports.get(video_id)
            if job and job["state"] in ("queued", "downloading", "done"):
                return job
            job = self.imports[video_id] = {"id": video_id, "state": "queued", "error": None, "path": None}
        threading.Thread(target=self._import, args=(video_id, meta, auth), daemon=True).start()
        return job

    def import_status(self, video_id: str) -> dict | None:
        with self.lock:
            return self.imports.get(video_id)

    def _import(self, video_id: str, meta: dict, auth: dict):
        job = self.imports[video_id]
        job["state"] = "downloading"
        try:
            artist = _safe(meta.get("artist") or "Unknown Artist")
            album = _safe(meta.get("album") or meta.get("title") or "Singles")
            title = _safe(meta.get("title") or video_id)
            folder = os.path.join(MUSIC_DIR, "YouTube", artist, album)
            os.makedirs(folder, exist_ok=True)
            target = os.path.join(folder, f"{title} [{video_id}].m4a")
            if not os.path.exists(target):
                tmp = os.path.join(folder, f".{video_id}.part.m4a")
                args = ["-f", "140/139/bestaudio[ext=m4a]", "--no-playlist", "--embed-metadata",
                        "--embed-thumbnail", "--convert-thumbnails", "jpg",
                        "--ppa", "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\"",
                        "-o", tmp, f"https://music.youtube.com/watch?v={video_id}"]
                result = self._run(args, timeout=600)
                if result.returncode != 0 or not os.path.exists(tmp):
                    raise RuntimeError(result.stderr.strip()[-300:] or "yt-dlp failed")
                # The app's names (from YouTube Music's song metadata) beat the video's title/channel.
                tags = []
                for key in ("title", "artist", "album"):
                    if meta.get(key):
                        tags += ["-metadata", f"{key}={meta[key]}"]
                if meta.get("artist"):
                    tags += ["-metadata", f"album_artist={meta['artist']}"]
                if meta.get("year"):
                    tags += ["-metadata", f"date={meta['year']}"]
                tagged = subprocess.run([shutil.which("ffmpeg") or "ffmpeg", "-v", "error", "-y", "-i", tmp, "-map", "0",
                                         "-c", "copy", *tags, target], capture_output=True, text=True, timeout=120)
                if tagged.returncode != 0:
                    log.warning("retag failed (%s), keeping yt-dlp tags", tagged.stderr.strip()[-200:])
                    os.replace(tmp, target)
                else:
                    os.remove(tmp)
            job["path"] = os.path.relpath(target, MUSIC_DIR)
            _start_scan(auth)
            job["state"] = "done"
            log.info("imported %s into %s", video_id, job["path"])
        except Exception as exc:
            log.exception("import %s failed", video_id)
            job["state"] = "failed"
            job["error"] = str(exc)[-300:]


def _safe(name: str) -> str:
    cleaned = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "_", str(name)).strip(" .")
    return cleaned[:120] or "_"


def _start_scan(auth: dict):
    params = {k: v for k, v in auth.items() if k in ("u", "t", "s", "p")}
    params.update({"v": "1.16.1", "c": "automix", "f": "json"})
    try:
        urllib.request.urlopen(f"{NAVIDROME_URL}/rest/startScan.view?{urllib.parse.urlencode(params)}", timeout=15).read()
    except Exception:
        log.exception("startScan failed")
