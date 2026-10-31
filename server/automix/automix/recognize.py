"""Identifies a short audio clip through Shazam's public web endpoint (shazamio).

Apple's ShazamKit only answers App IDs with its App Service enabled, which a free-account SideStore install can't have,
so the app uploads a clip here instead. This API is unofficial: failures must surface as errors, never as "no match".
"""
import asyncio

MAX_CLIP_BYTES = 2 << 20  # 12 s of 16 kHz mono PCM is about 400 KB.
TIMEOUT_SECONDS = 20


class RecognitionFailed(Exception):
    pass


def _apple_music_url(track: dict) -> str | None:
    for provider in [track.get("hub") or {}, *((track.get("hub") or {}).get("options") or [])]:
        for action in provider.get("actions") or []:
            uri = action.get("uri") or ""
            if uri.startswith("https://music.apple.com") or uri.startswith("https://itunes.apple.com"):
                return uri
    return None


def _album(track: dict) -> str | None:
    for section in track.get("sections") or []:
        if section.get("type") == "SONG":
            for item in section.get("metadata") or []:
                if item.get("title") == "Album":
                    return item.get("text")
    return None


def summarize(reply: dict) -> dict:
    track = reply.get("track")
    if not track or not track.get("title"):
        return {"match": False}
    images = track.get("images") or {}
    return {
        "match": True,
        "id": str(track.get("key") or ""),
        "title": track["title"],
        "artist": track.get("subtitle") or "",
        "album": _album(track),
        "artworkURL": images.get("coverarthq") or images.get("coverart"),
        "appleMusicURL": _apple_music_url(track),
        "isrc": track.get("isrc"),
    }


def recognize(clip: bytes) -> dict:
    """Blocking; each request handler runs on its own thread."""
    try:
        from shazamio import Shazam
    except ImportError as error:
        raise RecognitionFailed("shazamio is not installed on the server") from error

    async def run() -> dict:
        return await asyncio.wait_for(Shazam().recognize(clip), TIMEOUT_SECONDS)

    try:
        return summarize(asyncio.run(run()))
    except Exception as error:
        raise RecognitionFailed(f"{type(error).__name__}: {error}") from error
