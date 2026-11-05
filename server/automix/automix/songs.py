"""Song file edits from the app: retag a song, or move a file to the library's trash (duplicate cleanup).

Navidrome is read-only over Subsonic, so the files are changed here and Navidrome picks the change up through its
file watcher. Admin only: these touch the music files themselves.
"""
from __future__ import annotations

import os
import shutil
import sqlite3
import threading
import time

LOCK = threading.Lock()
TRASH = ".trash/songs"
# App field -> mutagen "easy" key (same names for EasyID3 and EasyMP4).
FIELDS = {"title": "title", "artist": "artist", "album": "album", "albumArtist": "albumartist", "year": "date",
          "genre": "genre", "track": "tracknumber", "disc": "discnumber"}


class SongError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


def _locate(db_path: str, song_id: str, user: str) -> tuple[str, str, str]:
    """(absolute file path, library root, updated_at) for an admin."""
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=30)
    try:
        admin = conn.execute("select is_admin from user where user_name = ?", (user,)).fetchone()
        if not admin or not admin[0]:
            raise SongError(403, "only an admin can change music files")
        row = conn.execute("""select m.path, l.path, m.updated_at from media_file m join library l on l.id = m.library_id
                              where m.id = ? and m.missing = 0""", (song_id,)).fetchone()
    finally:
        conn.close()
    if not row:
        raise SongError(404, "no such song")
    root = os.path.realpath(row[1])
    full = os.path.realpath(os.path.join(root, row[0]))
    if not full.startswith(root + os.sep) or not os.path.isfile(full):
        raise SongError(404, "the song's file is gone")
    return full, root, row[2]


def retag(db_path: str, song_id: str, user: str, changes: dict) -> dict:
    """changes: any of FIELDS -> new value (empty string removes the tag)."""
    import mutagen

    unknown = set(changes) - set(FIELDS)
    if unknown:
        raise SongError(400, f"unknown fields: {', '.join(sorted(unknown))}")
    if not changes:
        raise SongError(400, "nothing to change")
    for key in ("year", "track", "disc"):
        value = str(changes.get(key, "")).strip()
        if value and not value.isdigit():
            raise SongError(400, f"{key} must be a number")
    with LOCK:
        path, _, updated = _locate(db_path, song_id, user)
        audio = mutagen.File(path, easy=True)
        if audio is None:
            raise SongError(415, "this file type can't be tagged")
        if audio.tags is None:
            audio.add_tags()
        for field, value in changes.items():
            key, value = FIELDS[field], str(value).strip()
            if value:
                audio.tags[key] = [value]
            elif key in audio.tags:
                del audio.tags[key]
        audio.save()
    return {"ok": True, "updated": updated}


def wait_for_rescan(db_path: str, song_id: str, since: str, timeout: float = 30) -> bool:
    """True once Navidrome has re-read the song (its updated_at moved past `since`)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=30)
        try:
            row = conn.execute("select updated_at from media_file where id = ?", (song_id,)).fetchone()
        finally:
            conn.close()
        if row and row[0] != since:
            return True
        time.sleep(1)
    return False


def trash(db_path: str, song_id: str, user: str) -> dict:
    """Moves the file to <library>/.trash/songs/<same relative path>. Reversible: move it back."""
    with LOCK:
        path, root, _ = _locate(db_path, song_id, user)
        target = os.path.join(root, TRASH, os.path.relpath(path, root))
        if os.path.exists(target):
            stem, ext = os.path.splitext(target)
            target = f"{stem} ({time.strftime('%Y%m%d-%H%M%S')}){ext}"
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.move(path, target)
    return {"ok": True, "trashedTo": target}
