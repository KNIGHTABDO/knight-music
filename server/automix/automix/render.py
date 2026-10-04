"""Offline renderer for transition plans: the same gain / filter / stretch the app applies, written to an MP3.

Used to listen to and to measure transitions (see `verify`): if the two beat grids are locked, a beat tracker run
over the rendered overlap finds one steady grid; misaligned decks produce flams and a messy grid.
"""
from __future__ import annotations

import os
import subprocess
import tempfile

import numpy as np
from scipy.signal import lfilter

SR = 44100
BLOCK = 256


def decode_stereo(path: str) -> np.ndarray:
    out = subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-i", path, "-ac", "2", "-ar", str(SR),
                          "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(out, dtype=np.float32).reshape(-1, 2).copy()


def _interp(frames: list, t: np.ndarray, default: float, log: bool = False) -> np.ndarray:
    if not frames:
        return np.full_like(t, default)
    xs = np.array([f[0] for f in frames])
    ys = np.array([f[1] for f in frames], dtype=float)
    if log:
        return np.exp(np.interp(t, xs, np.log(ys)))
    return np.interp(t, xs, ys)


def _biquad(kind: str, fc: float) -> tuple[np.ndarray, np.ndarray]:
    w = 2 * np.pi * fc / SR
    alpha = np.sin(w) / (2 * 0.7071)
    cos = np.cos(w)
    if kind == "hp":
        b = np.array([(1 + cos) / 2, -(1 + cos), (1 + cos) / 2])
    else:
        b = np.array([(1 - cos) / 2, 1 - cos, (1 - cos) / 2])
    a = np.array([1 + alpha, -2 * cos, 1 - alpha])
    return b / a[0], a / a[0]


def _filter(x: np.ndarray, cutoffs: np.ndarray, kind: str) -> np.ndarray:
    """Time-varying biquad, coefficients updated every BLOCK samples, state carried across blocks."""
    y = np.empty_like(x)
    zi = np.zeros((2, x.shape[1]))
    for s in range(0, len(x), BLOCK):
        b, a = _biquad(kind, float(cutoffs[min(s, len(cutoffs) - 1)]))
        y[s:s + BLOCK], zi = lfilter(b, a, x[s:s + BLOCK], axis=0, zi=zi)
    return y


def _deck(audio: np.ndarray, media_t: np.ndarray, deck: dict) -> np.ndarray:
    gain = _interp(deck.get("gain", []), media_t, 1.0)
    hpf = np.clip(_interp(deck.get("hpf", []), media_t, 20.0, log=True), 10, SR / 2.2)
    lpf = np.clip(_interp(deck.get("lpf", []), media_t, 20000.0, log=True), 40, SR / 2.2)
    out = _filter(audio, hpf, "hp")
    out = _filter(out, lpf, "lp")
    return out * gain[:, None]


def _stretch(audio: np.ndarray, rate: float) -> np.ndarray:
    if abs(rate - 1) < 1e-4:
        return audio
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "in.wav"), os.path.join(tmp, "out.wav")
        import soundfile as sf
        sf.write(src, audio, SR, subtype="FLOAT")
        subprocess.run(["rubberband", "-q", "-3", "-T", f"{rate:.6f}", src, dst], check=True)
        out, _ = sf.read(dst, dtype="float32", always_2d=True)
    return out


def render(path_a: str, path_b: str, plan: dict, lead: float = 10.0, tail: float = 14.0) -> tuple[np.ndarray, dict]:
    """Mixes the transition region; returns stereo audio, and in `marks` where the overlap sits (seconds into
    the excerpt) plus the two processed decks separately (`stems`) for measurement."""
    a_audio, b_audio = decode_stereo(path_a), decode_stereo(path_b)
    if plan["mode"] == "gapless":
        a_seg = a_audio[max(0, len(a_audio) - int(lead * SR)):]
        mix = np.concatenate([a_seg, b_audio[:int(tail * SR)]])
        return mix, {"overlapStart": lead, "overlapEnd": lead}
    pa, pb = plan["a"], plan["b"]
    t0 = max(pa["start"] - lead, 0.0)                      # A media time where the excerpt starts (A runs at 1x)
    total = (pa["stop"] - t0) + tail
    n = int(total * SR)
    deck_a = np.zeros((n, 2), dtype=np.float32)
    deck_b = np.zeros((n, 2), dtype=np.float32)

    a_seg = a_audio[int(t0 * SR):int(pa["stop"] * SR)]
    deck_a[:len(a_seg)] = _deck(a_seg, t0 + np.arange(len(a_seg)) / SR, pa)

    rate = pb.get("rate", 1.0)
    b_offset = int((pa["start"] - t0) * SR)                # where B starts in the excerpt
    b_media_len = (n - b_offset) / SR * rate
    b_seg = b_audio[int(pb["start"] * SR):int((pb["start"] + b_media_len) * SR) + SR]
    b_proc = _stretch(_deck(b_seg, pb["start"] + np.arange(len(b_seg)) / SR, pb), rate)[:n - b_offset]
    deck_b[b_offset:b_offset + len(b_proc)] = b_proc
    mix = deck_a + deck_b
    peak = float(np.abs(mix).max())
    if peak > 0.99:
        mix *= 0.99 / peak
    return mix, {"overlapStart": pa["start"] - t0, "overlapEnd": pa["stop"] - t0, "handoff": pa["handoff"] - t0,
                 "stems": (deck_a, deck_b)}


def write_mp3(audio: np.ndarray, path: str):
    proc = subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", "-",
                           "-b:a", "256k", path], input=audio.astype(np.float32).tobytes())
    proc.check_returncode()


def _onset_lag_ms(a: np.ndarray, b: np.ndarray, max_ms: float = 80.0) -> float | None:
    """Lag of B's onsets behind A's (positive = B late), from cross-correlating onset envelopes at ~2.9 ms steps."""
    import librosa
    hop = 128
    ea = librosa.onset.onset_strength(y=a, sr=SR, hop_length=hop)
    eb = librosa.onset.onset_strength(y=b, sr=SR, hop_length=hop)
    n = min(len(ea), len(eb))
    if n < 64:
        return None
    ea, eb = ea[:n] - ea[:n].mean(), eb[:n] - eb[:n].mean()
    max_lag = int(max_ms / 1000 * SR / hop)
    scores = [float(np.dot(ea[max(0, -k):n - max(0, k)], eb[max(0, k):n - max(0, -k)])) for k in range(-max_lag, max_lag + 1)]
    best = int(np.argmax(scores)) - max_lag
    return round(best * hop / SR * 1000, 1)


def verify(marks: dict) -> dict:
    """Beat-tracks each processed deck over the overlap and measures how far B's beats sit from A's.
    Locked decks: B's beats land within a few ms of A's (tracker resolution is 20 ms)."""
    from beat_this.inference import Audio2Beats
    tracker = Audio2Beats(checkpoint_path="final0", device="cpu", dbn=False)
    deck_a, deck_b = marks["stems"]
    s0, s1 = int(marks["overlapStart"] * SR), int(marks["overlapEnd"] * SR)
    beats_a, _ = tracker(deck_a[s0:s1].mean(axis=1), SR)
    beats_b, _ = tracker(deck_b[s0:s1].mean(axis=1), SR)
    if len(beats_a) < 4 or len(beats_b) < 4:
        return {"locked": None, "note": "too few beats to measure"}
    ibi = float(np.median(np.diff(beats_a)))
    offsets = []
    for t in beats_b:
        nearest = beats_a[np.argmin(np.abs(beats_a - t))]
        offsets.append(t - nearest)
    offsets = np.array(offsets)
    good = np.abs(offsets) < ibi * 0.25
    phase = float(np.median(np.abs(offsets[good]))) * 1000 if good.any() else None
    lag = _onset_lag_ms(deck_a[s0:s1].mean(axis=1), deck_b[s0:s1].mean(axis=1))
    return {"beatsA": len(beats_a), "beatsB": len(beats_b), "matched": round(float(good.mean()), 2),
            "onsetLagMs": lag,
            "phaseErrorMs": round(phase, 1) if phase is not None else None,
            "locked": bool(good.mean() > 0.8 and phase is not None and phase < 25)}
