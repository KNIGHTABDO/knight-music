"""AutoMix service: keeps an analysis of every Navidrome track and serves transition plans to Knight Music.

- Watches Navidrome's database; new or changed tracks are analysed within seconds of Navidrome indexing them,
  newest first, and any track the app asks about jumps the queue.
- HTTP API under /automix/v1, authenticated with the same Subsonic credentials the app already sends
  (validated against the local Navidrome).
"""
from __future__ import annotations

import json
import logging
import os
import sqlite3
import threading
import time
import traceback
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import planner
from .analyze import ANALYSIS_VERSION

log = logging.getLogger("automix")

NAVIDROME_DB = os.environ.get("AUTOMIX_NAVIDROME_DB", "/home/knight/Navidrome/data/navidrome.db")
NAVIDROME_URL = os.environ.get("AUTOMIX_NAVIDROME_URL", "http://127.0.0.1:4533")
DATA_DIR = os.environ.get("AUTOMIX_DATA", os.path.expanduser("~/automix/data"))
PORT = int(os.environ.get("AUTOMIX_PORT", "4534"))
SCAN_INTERVAL = float(os.environ.get("AUTOMIX_SCAN_INTERVAL", "10"))


class Store:
    def __init__(self, path: str):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.path = path
        self.local = threading.local()
        with self.db() as c:
            c.execute("""create table if not exists analysis (
                id text primary key, path text, size integer, updated text, version integer,
                status text, error text, data text, analyzed_at real)""")

    def db(self) -> sqlite3.Connection:
        conn = getattr(self.local, "conn", None)
        if conn is None:
            conn = sqlite3.connect(self.path, timeout=30)
            conn.execute("pragma journal_mode=wal")
            self.local.conn = conn
        return conn

    def get(self, track_id: str) -> dict | None:
        row = self.db().execute("select data from analysis where id=? and status='ok'", (track_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def fresh(self, track: dict) -> bool:
        row = self.db().execute("select path, size, updated, version from analysis where id=?", (track["id"],)).fetchone()
        return bool(row) and tuple(row) == (track["path"], track["size"], track["updated"], ANALYSIS_VERSION)

    def known(self) -> dict[str, tuple]:
        return {r[0]: (r[1], r[2], r[3], r[4], r[5]) for r in
                self.db().execute("select id, path, size, updated, version, status from analysis")}

    def put(self, track_id: str, path: str, size: int, updated: str, data: dict | None, error: str | None):
        with self.db() as c:
            c.execute("insert or replace into analysis values (?,?,?,?,?,?,?,?,?)",
                      (track_id, path, size, updated, ANALYSIS_VERSION, "ok" if data else "error", error,
                       json.dumps(data, separators=(",", ":")) if data else None, time.time()))

    def counts(self) -> dict:
        rows = self.db().execute("select status, count(*) from analysis where version=? group by status",
                                 (ANALYSIS_VERSION,)).fetchall()
        return {status: n for status, n in rows}


def navidrome_tracks() -> list[dict]:
    conn = sqlite3.connect(f"file:{NAVIDROME_DB}?mode=ro", uri=True, timeout=30)
    try:
        libs = dict(conn.execute("select id, path from library"))
        rows = conn.execute("""select id, path, size, updated_at, library_id, album_id, track_number, disc_number,
                                      duration, created_at from media_file where missing = 0""").fetchall()
    finally:
        conn.close()
    out = []
    for r in rows:
        root = libs.get(r[4], "")
        out.append({"id": r[0], "path": os.path.join(root, r[1]), "size": r[2], "updated": r[3],
                    "album_id": r[5], "track_number": r[6], "disc_number": r[7], "duration": r[8], "created": r[9]})
    return out


class Worker(threading.Thread):
    def __init__(self, store: Store):
        super().__init__(daemon=True, name="automix-worker")
        self.store = store
        self.meta: dict[str, dict] = {}
        self.pending: list[str] = []
        self.urgent: list[str] = []
        self.lock = threading.Condition()
        self.current: str | None = None
        self.failures: dict[str, int] = {}

    def bump(self, ids: list[str]):
        with self.lock:
            for track_id in ids:
                if track_id in self.pending and track_id not in self.urgent:
                    self.urgent.append(track_id)
            self.lock.notify_all()

    def rescan(self):
        tracks = navidrome_tracks()
        known = self.store.known()
        meta = {t["id"]: t for t in tracks}
        todo = []
        for t in tracks:
            k = known.get(t["id"])
            stale = k is None or k[0] != t["path"] or k[1] != t["size"] or k[2] != t["updated"] or k[3] != ANALYSIS_VERSION
            if stale and t["id"] != self.current and self.failures.get(t["id"], 0) < 3:
                todo.append(t)
        todo.sort(key=lambda t: t["created"] or "", reverse=True)     # newest additions first
        with self.lock:
            self.meta = meta
            ids = [t["id"] for t in todo]
            if ids != self.pending:
                self.pending = ids
                self.urgent = [i for i in self.urgent if i in ids]
                self.lock.notify_all()

    def next_job(self) -> str | None:
        with self.lock:
            while not self.pending:
                self.lock.wait(timeout=SCAN_INTERVAL)
                if not self.pending:
                    return None
            track_id = self.urgent.pop(0) if self.urgent else self.pending[0]
            if track_id in self.pending:
                self.pending.remove(track_id)
            return track_id

    def run(self):
        from .analyze import analyze
        while True:
            track_id = self.next_job()
            if track_id is None:
                continue
            t = self.meta.get(track_id)
            if not t or self.store.fresh(t):   # queued twice by a rescan that raced the previous job
                continue
            self.current = track_id
            started = time.time()
            try:
                data = analyze(t["path"])
                self.store.put(track_id, t["path"], t["size"], t["updated"], data, None)
                log.info("analysed %s (%.1f BPM) in %.1fs: %s", track_id, data.get("bpm") or 0,
                         time.time() - started, os.path.basename(t["path"]))
            except Exception as exc:  # keep going; a broken file must not stop the library
                self.failures[track_id] = self.failures.get(track_id, 0) + 1
                self.store.put(track_id, t["path"], t["size"], t["updated"], None, str(exc))
                log.error("analysis failed for %s: %s\n%s", t["path"], exc, traceback.format_exc(limit=3))
            finally:
                self.current = None


class Scanner(threading.Thread):
    def __init__(self, worker: Worker):
        super().__init__(daemon=True, name="automix-scanner")
        self.worker = worker

    def run(self):
        last_mtime = None
        while True:
            try:
                mtimes = [os.path.getmtime(p) for p in (NAVIDROME_DB, NAVIDROME_DB + "-wal") if os.path.exists(p)]
                stamp = max(mtimes) if mtimes else None
                if stamp != last_mtime:
                    last_mtime = stamp
                    self.worker.rescan()
            except Exception as exc:
                log.error("rescan failed: %s", exc)
            time.sleep(SCAN_INTERVAL)


class Auth:
    """Accepts exactly the credentials Navidrome accepts (token or password), cached for 30 minutes."""

    def __init__(self):
        self.ok: dict[tuple, float] = {}
        self.lock = threading.Lock()

    def check(self, query: dict[str, str]) -> bool:
        user = query.get("u")
        if not user:
            return False
        key = (user, query.get("t"), query.get("s"), query.get("p"))
        with self.lock:
            if self.ok.get(key, 0) > time.time():
                return True
        params = {k: v for k, v in query.items() if k in ("u", "t", "s", "p")}
        params.update({"v": "1.16.1", "c": "automix", "f": "json"})
        try:
            with urllib.request.urlopen(f"{NAVIDROME_URL}/rest/ping.view?{urllib.parse.urlencode(params)}",
                                        timeout=10) as resp:
                body = json.load(resp)
            good = body.get("subsonic-response", {}).get("status") == "ok"
        except Exception:
            good = False
        if good:
            with self.lock:
                self.ok[key] = time.time() + 1800
        return good


def batch_token() -> str | None:
    """Secret for an external analysis worker (e.g. a Colab GPU), from ~/automix/data/batch_token. None = off."""
    path = os.path.join(DATA_DIR, "batch_token")
    try:
        with open(path) as f:
            token = f.read().strip()
        return token if len(token) >= 32 else None
    except OSError:
        return None


def make_handler(store: Store, worker: Worker, auth: Auth):
    class Handler(BaseHTTPRequestHandler):
        server_version = "KnightAutoMix/1"

        def log_message(self, fmt, *args):
            log.debug("%s %s", self.address_string(), fmt % args)

        def _send(self, code: int, payload: dict):
            body = json.dumps(payload, separators=(",", ":")).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _plan(self, a_id: str, b_id: str) -> dict:
            a, b = store.get(a_id), store.get(b_id)
            missing = [i for i, x in ((a_id, a), (b_id, b)) if x is None]
            if missing:
                worker.bump(missing)
            meta_a, meta_b = worker.meta.get(a_id, {}), worker.meta.get(b_id, {})
            result = planner.plan(a, b, meta_a, meta_b)
            result.update({"from": a_id, "to": b_id, "final": not missing})
            return result

        def _batch(self, path: str) -> tuple[str, str] | None:
            """('manifest'|'file'|'result', id) for /automix/v1/batch/<token>/..., when the token matches."""
            parts = path.split("/")
            token = batch_token()
            if len(parts) < 6 or parts[3] != "batch" or not token or parts[4] != token:
                return None
            return parts[5], (parts[6] if len(parts) > 6 else "")

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            query = dict(urllib.parse.parse_qsl(url.query))
            path = url.path.rstrip("/")
            if path.startswith("/automix/v1/batch/"):
                job = self._batch(path)
                if not job:
                    return self._send(404, {"error": "not found"})
                kind, track_id = job
                if kind == "manifest":
                    with worker.lock:
                        pending = [i for i in worker.pending if i != worker.current]
                    items = [{"id": i, "suffix": os.path.splitext(worker.meta[i]["path"])[1],
                              "size": worker.meta[i]["size"]} for i in pending if i in worker.meta]
                    return self._send(200, {"version": ANALYSIS_VERSION, "tracks": items})
                if kind == "file" and track_id in worker.meta:
                    file_path = worker.meta[track_id]["path"]
                    try:
                        size = os.path.getsize(file_path)
                        self.send_response(200)
                        self.send_header("Content-Type", "application/octet-stream")
                        self.send_header("Content-Length", str(size))
                        self.end_headers()
                        with open(file_path, "rb") as f:
                            while chunk := f.read(1 << 20):
                                self.wfile.write(chunk)
                    except OSError as exc:
                        return self._send(500, {"error": str(exc)})
                    return
                return self._send(404, {"error": "not found"})
            if path == "/automix/v1/health":
                return self._send(200, {"ok": True})
            if not path.startswith("/automix/v1/"):
                return self._send(404, {"error": "not found"})
            if not auth.check(query):
                return self._send(401, {"error": "invalid credentials"})
            if path == "/automix/v1/status":
                counts = store.counts()
                return self._send(200, {"analysisVersion": ANALYSIS_VERSION, "planVersion": planner.PLAN_VERSION,
                                        "tracks": len(worker.meta), "analysed": counts.get("ok", 0),
                                        "failed": counts.get("error", 0), "queued": len(worker.pending),
                                        "working": worker.current})
            if path == "/automix/v1/plan":
                a_id, b_id = query.get("from"), query.get("to")
                if not a_id or not b_id:
                    return self._send(400, {"error": "from and to are required"})
                return self._send(200, self._plan(a_id, b_id))
            if path == "/automix/v1/matches":
                a_id = query.get("from")
                a = store.get(a_id) if a_id else None
                if not a:
                    return self._send(200, {"matches": []})
                limit = min(int(query.get("limit", "12") or 12), 30)
                found = []
                for b_id, meta_b in list(worker.meta.items()):
                    if b_id == a_id:
                        continue
                    b = store.get(b_id)
                    if not b:
                        continue
                    result = planner.plan(a, b, worker.meta.get(a_id, {}), meta_b)
                    if result["mode"] == "beatmatch":
                        stretch = abs(result["a"].get("rate", 1) - 1) + abs(result["b"].get("rate", 1) - 1)
                        found.append((stretch, b_id, result["reason"]))
                found.sort()
                return self._send(200, {"matches": [{"id": i, "reason": r} for _, i, r in found[:limit]]})
            if path.startswith("/automix/v1/analysis/"):
                data = store.get(path.rsplit("/", 1)[-1])
                return self._send(200, data) if data else self._send(404, {"error": "not analysed"})
            return self._send(404, {"error": "not found"})

        def do_POST(self):
            url = urllib.parse.urlparse(self.path)
            query = dict(urllib.parse.parse_qsl(url.query))
            if url.path.startswith("/automix/v1/batch/"):
                job = self._batch(url.path.rstrip("/"))
                if not job or job[0] != "result" or job[1] not in worker.meta:
                    return self._send(404, {"error": "not found"})
                try:
                    length = min(int(self.headers.get("Content-Length", "0")), 16 << 20)
                    data = json.loads(self.rfile.read(length))
                except (ValueError, TypeError):
                    return self._send(400, {"error": "bad body"})
                if data.get("version") != ANALYSIS_VERSION or not isinstance(data.get("beats"), list):
                    return self._send(409, {"error": f"analysis version must be {ANALYSIS_VERSION}"})
                t = worker.meta[job[1]]
                store.put(job[1], t["path"], t["size"], t["updated"], data, None)
                with worker.lock:
                    if job[1] in worker.pending:
                        worker.pending.remove(job[1])
                log.info("imported external analysis %s (%.1f BPM): %s", job[1], data.get("bpm") or 0,
                         os.path.basename(t["path"]))
                return self._send(200, {"ok": True})
            if url.path.rstrip("/") != "/automix/v1/plans":
                return self._send(404, {"error": "not found"})
            if not auth.check(query):
                return self._send(401, {"error": "invalid credentials"})
            try:
                length = min(int(self.headers.get("Content-Length", "0")), 1 << 20)
                pairs = json.loads(self.rfile.read(length) or b"{}").get("pairs", [])[:50]
            except (ValueError, AttributeError):
                return self._send(400, {"error": "bad body"})
            return self._send(200, {"plans": [self._plan(str(a), str(b)) for a, b in pairs]})

    return Handler


def main():
    logging.basicConfig(level=os.environ.get("AUTOMIX_LOG", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    try:
        import torch
        torch.set_num_threads(int(os.environ.get("AUTOMIX_THREADS", "3")))
    except ImportError:
        pass
    store = Store(os.path.join(DATA_DIR, "analysis.db"))
    worker = Worker(store)
    worker.rescan()
    worker.start()
    Scanner(worker).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(store, worker, Auth()))
    log.info("AutoMix listening on :%d, %d tracks, %d queued", PORT, len(worker.meta), len(worker.pending))
    server.serve_forever()


if __name__ == "__main__":
    main()
