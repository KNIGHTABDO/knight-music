"""Turns two track analyses into a transition plan the app executes sample-accurately.

Plan (all times are seconds of that deck's own media timeline, gains are linear amplitude, filters in Hz):
  mode      beatmatch | crossfade | gapless
  a.rate    A's playback rate from a.start on (reached through a.rateRamp in the bars before)
  a.start   A's media time at which B must start playing (B at b.start, rate b.rate)
  a.handoff A's media time at which the app shows B as the current song
  a.stop    A's media time after which A is silent and is stopped
  a.gain / a.hpf / a.lpf, b.gain / b.hpf / b.lpf   keyframes [[t, value], ...]
  b.rateRamp  [[t, rate], ...] applied once A is gone (B eases back to its own tempo)

Beat matching aligns a phrase-starting downbeat of A's outro with B's first downbeat, stretches B (pitch kept)
so the two grids stay locked for the whole overlap, swaps the basslines on the middle downbeat and fades A out
over the second half — the way a DJ (and Apple Music's AutoMix) blends two songs.
"""
from __future__ import annotations

import math

from .analyze import fit_grid

PLAN_VERSION = 3
MAX_STRETCH = 0.08          # per deck (a DJ pitch fader range); both decks meet halfway, so ±16 % between songs
SAME_TEMPO = 0.0004         # closer than this the grids stay locked without any stretching
MIN_STEADINESS = 0.25       # songs without a usable grid anywhere (live, rubato, ambient) are not beat-matched
CROSSFADE_SECONDS = 6.0
HPF_OFF, LPF_OFF = 20.0, 20000.0


def _camelot_distance(a: str | None, b: str | None) -> int:
    if not a or not b:
        return 0
    na, la, nb, lb = int(a[:-1]), a[-1], int(b[:-1]), b[-1]
    step = min((na - nb) % 12, (nb - na) % 12)
    return step + (0 if la == lb else 1)


def _equal_power(t0: float, t1: float, g0: float, g1: float, steps: int = 12) -> list[list[float]]:
    """Gain keyframes following a quarter-sine from g0 to g1 (constant perceived loudness)."""
    out = []
    for k in range(steps + 1):
        u = k / steps
        shape = math.sin(u * math.pi / 2) if g1 > g0 else math.cos(u * math.pi / 2)
        lo, hi = min(g0, g1), max(g0, g1)
        g = lo + (hi - lo) * shape
        out.append([round(t0 + (t1 - t0) * u, 4), round(g, 4)])
    return out


def _end_of_music(a: dict) -> float:
    """Where a transition out of A must be complete: before the deep part of a fade, or the last audible sound."""
    end = a["fadeEnd"] if a.get("fadeOut") else a["lastAudible"]
    return min(end, a["duration"] - 0.05)


def gapless(reason: str) -> dict:
    return {"version": PLAN_VERSION, "mode": "gapless", "reason": reason}


def crossfade(a: dict | None, b: dict | None, dur_a: float, reason: str) -> dict:
    """Phrase-aligned blend without tempo change (tempos too far apart, unsteady beats, or no analysis yet)."""
    end_a = _end_of_music(a) if a else max(dur_a - 0.3, 1.0)
    fade = min(CROSSFADE_SECONDS, max(2.0, end_a * 0.08))
    x = max(end_a - fade, 0.0)
    if a and a.get("downbeats"):
        earlier = [d for d in a["downbeats"] if end_a - fade - 4.0 <= d <= end_a - fade]
        if earlier:
            x = earlier[-1]
            fade = end_a - x
    s_b = max((b or {}).get("firstAudible", 0.0) - 0.02, 0.0)
    return {
        "version": PLAN_VERSION, "mode": "crossfade", "reason": reason,
        "a": {
            "start": round(x, 4), "handoff": round(x + fade / 2, 4), "stop": round(x + fade + 0.05, 4),
            "rate": 1.0, "rateRamp": [],
            "gain": [[round(x, 4), 1.0]] + _equal_power(x, x + fade, 1.0, 0.0),
            "hpf": [],
            "lpf": [[round(x, 4), LPF_OFF], [round(x + fade * 0.4, 4), 6000.0], [round(x + fade, 4), 900.0]],
        },
        "b": {
            "start": round(s_b, 4), "rate": 1.0,
            "gain": _equal_power(s_b, s_b + fade * 0.6, 0.0, 1.0),
            "hpf": [[round(s_b, 4), 260.0], [round(s_b + fade * 0.35, 4), 260.0], [round(s_b + fade * 0.6, 4), HPF_OFF]],
            "lpf": [],
            "rateRamp": [],
        },
    }


def _index_at_or_after(values: list[float], t: float) -> int | None:
    for i, v in enumerate(values):
        if v >= t - 1e-6:
            return i
    return None


def _anchor_candidates(b: dict, bars: int) -> list[tuple[int, float]]:
    """Downbeats in B's first 32 bars it could come in on (earliest first, phrase starts preferred), each with the
    media time B starts playing from: its very beginning when the intro before the anchor is short, otherwise
    8 bars before the anchor (a long beatless intro is partly skipped, like a DJ would)."""
    db = b["downbeats"]
    j0 = _index_at_or_after(db, b["firstAudible"])
    if j0 is None:
        return []
    off = b.get("phraseOffset", 0)
    out = []
    for j in range(j0, min(j0 + 32, len(db) - bars)):
        bar_b = (db[j + bars] - db[j]) / bars
        lead = db[j] - b["firstAudible"]
        start = b["firstAudible"] - 0.02 if lead <= 8 * bar_b else db[j] - 8 * bar_b
        out.append((0 if (j - off) % 4 == 0 else 1, j, max(start, 0.0)))
    out.sort(key=lambda c: (c[0], c[1]))
    return [(j, start) for _, j, start in out]


def _mix_out_candidates(a: dict, bars: int) -> list[int]:
    """Phrase-starting downbeats in A's outro whose `bars` still fit before the music ends, best first."""
    db = a["downbeats"]
    end = _end_of_music(a)
    nov = {round(bar["t"], 3): bar.get("novelty", 0.0) for bar in a.get("bars", [])}
    energy = {round(bar["t"], 3): bar["db"] for bar in a.get("bars", [])}
    ref = a.get("refDb", 0.0)
    off = a.get("phraseOffset", 0)
    scored = []
    for i in range(len(db) - bars):
        p, e = db[i], db[i + bars]
        tail = end - e                       # music of A skipped after the blend
        if e > end or tail > 45 or p < a["duration"] * 0.5:
            continue
        phrase = (i - off) % 8
        if phrase % 4:
            continue
        quiet = ref - energy.get(round(p, 3), ref)   # dB below the song's loud level: outro-ness
        score = (1.0 * nov.get(round(p, 3), 0.0) + (0.5 if phrase == 0 else 0.0) + 0.06 * min(quiet, 12)
                 - 0.09 * tail)
        scored.append((score, i))
    return [i for _, i in sorted(scored, reverse=True)]


def _snap(beats: list[float], times: list[float], margin: float) -> list[float] | None:
    """Moves downbeat times onto a straight grid fitted through the beats around them (ms-accurate alignment
    instead of the tracker's 20 ms frames). None when the local grid isn't steady enough to beat-match on."""
    window = [x for x in beats if times[0] - margin <= x <= times[-1] + margin]
    fit = fit_grid(window)
    if not fit or fit[2] > 0.025:
        return None
    t0, ibi, _ = fit
    return [t0 + round((t - t0) / ibi) * ibi for t in times]


def beatmatch(a: dict, b: dict) -> dict | None:
    bpm_a, bpm_b = a.get("bpm"), b.get("bpm")
    if not bpm_a or not bpm_b:
        return None
    if a.get("steadiness", 0) < MIN_STEADINESS or b.get("steadiness", 0) < MIN_STEADINESS:
        return None
    # Half/double-time reading: map A's beats onto B's beats, or onto every other one.
    ratio = bpm_b / bpm_a
    per = min((0.5, 1.0, 2.0), key=lambda k: abs(math.log(ratio / k)))
    if abs(ratio / per - 1) > 2 * MAX_STRETCH + 0.005:
        return None

    bar_seconds = 4 * 60.0 / bpm_a
    bars = 8 if 9.0 <= 8 * bar_seconds <= 24.0 else (16 if 8 * bar_seconds < 9.0 else 4)
    if _camelot_distance(a["key"].get("camelot"), b["key"].get("camelot")) > 2:
        bars = max(4, bars // 2)           # clashing keys: keep the overlap short

    combos = ((t, i, anchor) for t in dict.fromkeys((bars, max(4, bars // 2)))
              for i in _mix_out_candidates(a, t)[:8]
              for anchor in _anchor_candidates(b, max(1, int(round(t * per))))[:10])
    for t, i, (j, s_b) in combos:
        db_a, db_b = a["downbeats"], b["downbeats"]
        bar_a = (db_a[i + t] - db_a[i]) / t
        snapped_a = _snap(a["beats"], [db_a[i], db_a[i + t // 2], db_a[i + t]], bar_a)
        bars_b = max(1, int(round(t * per)))
        bar_b = (db_b[j + bars_b] - db_b[j]) / bars_b
        snapped_b = _snap(b["beats"], [db_b[j], db_b[j + bars_b]], bar_b)
        if not snapped_a or not snapped_b:
            continue                       # the grid wobbles right where we would mix
        p, h, e = snapped_a
        d, d_end = snapped_b
        ratio_ab = (d_end - d) / (e - p)   # B media seconds per A media second: locks both grids end to end
        if abs(ratio_ab - 1) <= SAME_TEMPO:
            rate_a, rate = 1.0, 1.0        # same tempo: both decks untouched (grids differ by < 1 ms per bar)
        else:
            # Meet halfway: each deck moves by the same factor, so both pass through the same time-stretch
            # processing on the phone (equal latency) and neither is stretched more than half the gap.
            rate_a, rate = ratio_ab ** -0.5, ratio_ab ** 0.5
        if abs(rate - 1) > MAX_STRETCH + 0.005 or abs(rate_a - 1) > MAX_STRETCH + 0.005:
            continue
        a_start = p - (d - s_b) * rate_a / rate

        def b_at(x: float) -> float:       # B's media time when A is at media time x (both decks locked)
            return d + (x - p) * ratio_ab

        beat_a = (e - p) / (4 * t)
        beat_b = beat_a * ratio_ab
        loud = 1.0
        if a.get("lufs") is not None and b.get("lufs") is not None and b["lufs"] > a["lufs"]:
            loud = max(0.5, 10 ** ((a["lufs"] - b["lufs"]) / 20))

        a_gain = [[round(a_start, 4), 1.0], [round(h, 4), 1.0]] + _equal_power(h + beat_a, e, 1.0, 0.0)[0:]
        a_hpf = [[round(h - beat_a * 0.25, 4), HPF_OFF], [round(h, 4), 160.0], [round(h + beat_a * 4, 4), 260.0],
                 [round(e, 4), 500.0]]
        if a_start < p - 0.05:
            b_gain = _equal_power(s_b, d, 0.0, 0.55 * loud)
        else:
            b_gain = _equal_power(s_b, b_at(p + beat_a * 8), 0.0, 0.6 * loud)
        b_gain += [[round(b_at(h) - beat_b * 0.25, 4), 0.85 * loud], [round(b_at(h), 4), loud],
                   [round(b_at(e), 4), loud]]
        if loud < 0.999:
            b_gain.append([round(b_at(e) + 32 * beat_b, 4), 1.0])
        b_hpf = [[round(s_b, 4), 300.0], [round(b_at(h) - beat_b * 0.25, 4), 300.0], [round(b_at(h), 4), HPF_OFF]]
        a_ramp = []
        if abs(rate_a - 1) > 0.0005:
            # A eases to its blend tempo over the 8 bars before B comes in, finishing two bars early.
            ramp_end = a_start - 2 * (bar_a / 1.0)
            ramp_start = ramp_end - 8 * bar_a
            a_ramp = [[round(ramp_start + (ramp_end - ramp_start) * k / 16, 4), round(1 + (rate_a - 1) * k / 16, 5)]
                      for k in range(1, 17)]
        ramp = []
        if abs(rate - 1) > 0.002:
            start_ramp = b_at(e) + beat_b
            ramp = [[round(start_ramp + k * beat_b, 4), round(rate + (1.0 - rate) * k / 16, 5)] for k in range(1, 17)]
        b_gain.sort(key=lambda kf: kf[0])
        return {
            "version": PLAN_VERSION, "mode": "beatmatch",
            "reason": f"{bpm_a:.1f}→{bpm_b:.1f} BPM, {t} bars, A {100 * (rate_a - 1):+.1f}% B {100 * (rate - 1):+.1f}%",
            "bars": t,
            "a": {"start": round(a_start, 4), "handoff": round(h, 4), "stop": round(e + 0.05, 4),
                  "rate": round(rate_a, 6), "rateRamp": a_ramp, "gain": a_gain, "hpf": a_hpf, "lpf": []},
            "b": {"start": round(s_b, 4), "rate": round(rate, 6), "gain": b_gain, "hpf": b_hpf, "lpf": [],
                  "rateRamp": ramp},
        }
    return None


def plan(a: dict | None, b: dict | None, meta_a: dict, meta_b: dict) -> dict:
    """meta_*: album_id, track_number, disc_number, duration from Navidrome."""
    same_album = meta_a.get("album_id") and meta_a.get("album_id") == meta_b.get("album_id")
    consecutive = same_album and meta_a.get("disc_number") == meta_b.get("disc_number") and \
        (meta_b.get("track_number") or 0) == (meta_a.get("track_number") or 0) + 1
    if consecutive and a and b and a["lastAudible"] > a["duration"] - 0.6 and b["firstAudible"] < 0.4:
        return gapless("continuous album: tracks run into each other")
    if not a or not b:
        return crossfade(a, b, float(meta_a.get("duration") or 0), "not analysed yet")
    if a["duration"] < 45 or b["duration"] < 45:
        return crossfade(a, b, a["duration"], "short track")
    return beatmatch(a, b) or crossfade(a, b, a["duration"], "tempos or grids too different to beat-match")
