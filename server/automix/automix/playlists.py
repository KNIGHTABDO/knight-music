"""Edits for Navidrome playlists that are synced from .m3u8 files (the ones Knight writes).

Navidrome refuses track edits on synced playlists, and turning sync off would stop Knight from updating them. So the
app sends edits here: the .m3u8 is rewritten in place and Navidrome re-imports it through its file watcher.
Lines that don't match a library file (not scanned yet, or missing) are kept where they are.
"""
from __future__ import annotations

import os
import shutil
import sqlite3
import tempfile
import threading
import time
import urllib.parse
import urllib.request

LOCK = threading.Lock()
TRASH = ".trash/playlists"


class EditError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def _connect(db_path: str) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=30)


def _playlist(conn: sqlite3.Connection, playlist_id: str, user: str) -> tuple[str, str]:
    row = conn.execute("""select p.path, p.sync, u.user_name, p.name from playlist p
                          left join user u on u.id = p.owner_id where p.id = ?""", (playlist_id,)).fetchone()
    if not row:
        raise EditError(404, "no such playlist")
    path, sync, owner, name = row
    if owner != user:
        raise EditError(403, "only the playlist's owner can edit it")
    if not sync or not path:
        raise EditError(409, "playlist isn't synced from a file; edit it through Navidrome")
    roots = [r[0] for r in conn.execute("select path from library")]
    real = os.path.realpath(path)
    if not real.endswith((".m3u", ".m3u8")) or not any(real.startswith(os.path.realpath(r) + os.sep) for r in roots):
        raise EditError(409, "playlist file is outside the music library")
    return real, name


def _library_paths(conn: sqlite3.Connection) -> tuple[dict[str, str], dict[str, str]]:
    """(absolute path -> media id, media id -> absolute path) for every present file."""
    roots = dict(conn.execute("select id, path from library"))
    by_path, by_id = {}, {}
    for mid, rel, lib in conn.execute("select id, path, library_id from media_file where missing = 0"):
        full = os.path.normpath(os.path.join(roots.get(lib, ""), rel))
        by_path[full] = mid
        by_id[mid] = full
    return by_path, by_id


def _read(path: str) -> tuple[list[str], list[str]]:
    """(header lines, entry lines). Header = #EXTM3U / #PLAYLIST etc. before the first entry."""
    try:
        with open(path, encoding="utf-8-sig") as f:
            lines = [l.rstrip("\r\n") for l in f]
    except FileNotFoundError:
        raise EditError(404, "playlist file is gone")
    header, entries = [], []
    for line in lines:
        if not line.strip():
            continue
        if not entries and line.startswith("#") and not line.startswith("#EXTINF"):
            header.append(line)
        else:
            entries.append(line)
    return header, entries


def _entry_target(line: str, base: str) -> str | None:
    if line.startswith("#"):
        return None
    if line.startswith("file://"):
        line = urllib.parse.unquote(urllib.parse.urlparse(line).path)
    return os.path.normpath(line if os.path.isabs(line) else os.path.join(base, line))


def _write(path: str, header: list[str], entries: list[str]):
    mode = os.stat(path).st_mode & 0o777
    folder = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".km-", suffix=".m3u8", dir=folder)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(header + entries) + "\n")
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def edit(db_path: str, playlist_id: str, user: str, body: dict) -> dict:
    """body: {"add": [ids], "removeIndexes": [ints]} or {"songIds": [ids]} (full new order).
    Indexes count the songs Navidrome shows (matched entries only). Renames go through Subsonic: Navidrome allows
    them on synced playlists and keeps the name across re-imports."""
    with LOCK:
        conn = _connect(db_path)
        try:
            path, _ = _playlist(conn, playlist_id, user)
            by_path, by_id = _library_paths(conn)
        finally:
            conn.close()
        base = os.path.dirname(path)
        header, entries = _read(path)

        def rel(mid: str) -> str:
            full = by_id.get(mid)
            if not full:
                raise EditError(400, f"unknown song {mid}")
            return os.path.relpath(full, base)

        # (line, media id or None) keeps any #EXTINF line glued to the entry after it.
        items: list[tuple[list[str], str | None]] = []
        pending: list[str] = []
        for line in entries:
            if line.startswith("#"):
                pending.append(line)
                continue
            target = _entry_target(line, base)
            items.append((pending + [line], by_path.get(target) if target else None))
            pending = []
        trailing = pending

        if "songIds" in body:
            wanted = [str(i) for i in body["songIds"]]
            for mid in wanted:
                rel(mid)
            matched = [it for it in items if it[1]]
            pool: dict[str, list[list[str]]] = {}
            for lines, mid in matched:
                pool.setdefault(mid, []).append(lines)
            rebuilt = []
            for mid in wanted:
                old = pool.get(mid)
                rebuilt.append((old.pop(0) if old else [rel(mid)], mid))
            unmatched = [it for it in items if not it[1]]
            items = rebuilt + unmatched
        else:
            remove = {int(i) for i in body.get("removeIndexes", [])}
            if remove:
                count = sum(1 for it in items if it[1])
                if any(i < 0 or i >= count for i in remove):
                    raise EditError(400, "song index out of range")
                kept, index = [], 0
                for it in items:
                    if it[1]:
                        if index in remove:
                            index += 1
                            continue
                        index += 1
                    kept.append(it)
                items = kept
            for mid in body.get("add", []):
                items.append(([rel(str(mid))], str(mid)))

        if not header or header[0] != "#EXTM3U":
            header = ["#EXTM3U"] + [h for h in header if h != "#EXTM3U"]

        expected = [mid for _, mid in items if mid]
        if not expected:
            # Navidrome only replaces a synced playlist's tracks when the file lists some, so it would keep the old ones.
            raise EditError(422, "Navidrome can't empty a playlist that comes from a file. Delete the playlist instead.")
        _write(path, header, [l for lines, _ in items for l in lines] + trailing)
        return {"ok": True, "songCount": len(expected), "expected": expected}


def wait_for_import(db_path: str, playlist_id: str, expected: list[str], timeout: float = 30) -> bool:
    """True once Navidrome's copy of the playlist matches what was written."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        conn = _connect(db_path)
        try:
            ids = [r[0] for r in conn.execute(
                "select media_file_id from playlist_tracks where playlist_id = ? order by id", (playlist_id,))]
        finally:
            conn.close()
        if ids == expected:
            return True
        time.sleep(1)
    return False


def trigger_scan(navidrome_url: str, query: dict[str, str]):
    """Nudges Navidrome when its watcher hasn't picked the file up (quick scan; admin only, best effort)."""
    params = {k: v for k, v in query.items() if k in ("u", "t", "s", "p")}
    params.update({"v": "1.16.1", "c": "automix", "f": "json"})
    try:
        urllib.request.urlopen(f"{navidrome_url}/rest/startScan.view?{urllib.parse.urlencode(params)}", timeout=10).close()
    except Exception:
        pass


def delete(db_path: str, playlist_id: str, user: str) -> dict:
    """Moves the .m3u8 to <library>/.trash/playlists so Navidrome won't re-import it; the app then deletes the
    playlist through Subsonic. Reversible: move the file back."""
    with LOCK:
        conn = _connect(db_path)
        try:
            path, _ = _playlist(conn, playlist_id, user)
            roots = [os.path.realpath(r[0]) for r in conn.execute("select path from library")]
        finally:
            conn.close()
        root = next(r for r in roots if path.startswith(r + os.sep))
        trash = os.path.join(root, TRASH)
        os.makedirs(trash, exist_ok=True)
        target = os.path.join(trash, f"{time.strftime('%Y%m%d-%H%M%S')} {os.path.basename(path)}")
        shutil.move(path, target)
        return {"ok": True, "trashedTo": target}
