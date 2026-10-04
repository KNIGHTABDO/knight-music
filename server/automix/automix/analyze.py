"""Per-track musical analysis for AutoMix.

Everything a DJ needs to mix a track in or out: beat and downbeat grid (Beat This!, ISMIR 2024), tempo and
how steady it is, phrase boundaries, where the music really starts/ends (silence, fade-out), per-bar energy,
how percussive each bar is, loudness (EBU R128) and key.
"""
from __future__ import annotations

import json
import re
import subprocess

import numpy as np

ANALYSIS_VERSION = 3
SR = 22050
HOP = 512

_beat_model = None


def _beats_model():
    global _beat_model
    if _beat_model is None:
        from beat_this.inference import Audio2Beats  # heavy import, only in the worker
        _beat_model = Audio2Beats(checkpoint_path="final0", device="cpu", dbn=False)
    return _beat_model


def decode(path: str, sr: int = SR) -> np.ndarray:
    """Mono float32 PCM via ffmpeg (handles every format Navidrome serves)."""
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", path, "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
        capture_output=True, check=True,
    ).stdout
    return np.frombuffer(out, dtype=np.float32).copy()


def integrated_loudness(path: str) -> float | None:
    proc = subprocess.run(
        ["ffmpeg", "-nostats", "-nostdin", "-i", path, "-af", "ebur128=framelog=quiet", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    found = re.findall(r"I:\s+(-?[\d.]+) LUFS", proc.stderr)
    return float(found[-1]) if found else None


KEY_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
# Krumhansl–Kessler key profiles
_MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
_MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
# Camelot wheel numbers for major / minor keys indexed by tonic pitch class
_CAMELOT_MAJOR = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
_CAMELOT_MINOR = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]


def detect_key(chroma_mean: np.ndarray) -> dict:
    best = (-2.0, 0, "major")
    for tonic in range(12):
        for mode, profile in (("major", _MAJOR), ("minor", _MINOR)):
            r = float(np.corrcoef(chroma_mean, np.roll(profile, tonic))[0, 1])
            if r > best[0]:
                best = (r, tonic, mode)
    r, tonic, mode = best
    camelot = f"{(_CAMELOT_MAJOR if mode == 'major' else _CAMELOT_MINOR)[tonic]}{'B' if mode == 'major' else 'A'}"
    return {"name": f"{KEY_NAMES[tonic]} {mode}", "camelot": camelot, "confidence": round(r, 3)}


def fit_grid(beats) -> tuple[float, float, float] | None:
    """(t0, ibi, residual_std) of a straight beat grid through `beats`.

    Beats come on a 20 ms frame grid and the tracker sometimes drops or doubles one, so each beat is numbered by
    how many coarse intervals have passed since the previous one before the line is fitted.
    """
    beats = np.asarray(beats, dtype=float)
    if len(beats) < 4:
        return None
    med = float(np.median(np.diff(beats)))
    if med <= 0:
        return None
    kept = [beats[0]]
    for t in beats[1:]:
        if t - kept[-1] >= 0.6 * med:
            kept.append(t)
    kept = np.array(kept)
    idx = np.concatenate([[0], np.cumsum(np.maximum(1, np.round(np.diff(kept) / med)))])
    slope, intercept = np.polyfit(idx, kept, 1)
    residual = kept - (slope * idx + intercept)
    return float(intercept), float(slope), float(np.std(residual))


def _tempo(beats: np.ndarray) -> tuple[float | None, float]:
    """BPM from the steady middle of the track, and steadiness = median tightness of 32-beat windows
    (1 = machine-tight). A bridge at another tempo or one tracker slip must not condemn the whole song."""
    if len(beats) < 16:
        return None, 0.0
    lo, hi = int(len(beats) * 0.1), int(len(beats) * 0.9)
    fit = fit_grid(beats[lo:hi] if hi - lo >= 12 else beats)
    if not fit or fit[1] <= 0:
        return None, 0.0
    scores = []
    for s in range(0, max(1, len(beats) - 32), 16):
        local = fit_grid(beats[s:s + 32])
        if local and local[1] > 0:
            scores.append(float(np.clip(1.0 - local[2] / (0.12 * local[1]), 0.0, 1.0)))
    return 60.0 / fit[1], float(np.median(scores)) if scores else 0.0


def _novelty(features: np.ndarray, width: int = 8) -> np.ndarray:
    """Foote checkerboard novelty over a bar-level self-similarity matrix."""
    n = len(features)
    if n < 2 * width:
        return np.zeros(n)
    f = features - features.mean(axis=0)
    f /= np.linalg.norm(f, axis=1, keepdims=True) + 1e-9
    ssm = f @ f.T
    half = width
    sign = np.ones((2 * half, 2 * half))
    sign[:half, half:] = -1
    sign[half:, :half] = -1
    taper = np.outer(np.hanning(2 * half), np.hanning(2 * half))
    kernel = sign * taper
    out = np.zeros(n)
    for i in range(half, n - half):
        out[i] = float((ssm[i - half:i + half, i - half:i + half] * kernel).sum())
    out = np.clip(out, 0, None)
    return out / (out.max() + 1e-9)


def analyze(path: str) -> dict:
    import librosa

    y = decode(path)
    if len(y) < SR * 5:
        raise ValueError("track too short to analyse")
    duration = len(y) / SR

    beats, downbeats = _beats_model()(y, SR)
    beats = np.asarray(beats, dtype=float)
    downbeats = np.asarray(downbeats, dtype=float)
    bpm, steadiness = _tempo(beats)

    # Loudness envelope (dB, ~23 ms frames) and where the music really is.
    rms = librosa.feature.rms(y=y, frame_length=2048, hop_length=HOP)[0]
    db = librosa.amplitude_to_db(rms + 1e-9)
    times = librosa.frames_to_time(np.arange(len(db)), sr=SR, hop_length=HOP)
    ref = float(np.percentile(db, 95))
    audible = np.where(db > ref - 30)[0]
    first_audible = float(times[audible[0]]) if len(audible) else 0.0
    last_audible = float(times[audible[-1]]) if len(audible) else duration
    win = max(1, int(1.0 * SR / HOP))
    smooth = np.convolve(db, np.ones(win) / win, mode="same")
    loud = np.where(smooth >= ref - 6)[0]
    loud_end = float(times[loud[-1]]) if len(loud) else last_audible
    after = np.where((times > loud_end) & (smooth < ref - 15))[0]
    fade_end = float(times[after[0]]) if len(after) else last_audible
    fade_out = (last_audible - loud_end) > 4.0

    # Spectral features for bar-level structure.
    S = np.abs(librosa.stft(y, n_fft=2048, hop_length=HOP))
    freqs = librosa.fft_frequencies(sr=SR, n_fft=2048)
    low = S[freqs < 150].sum(axis=0)
    H, P = librosa.decompose.hpss(S)
    perc = P.sum(axis=0) / (H.sum(axis=0) + P.sum(axis=0) + 1e-9)
    chroma = librosa.feature.chroma_stft(S=S ** 2, sr=SR, hop_length=HOP)
    mfcc = librosa.feature.mfcc(S=librosa.power_to_db(librosa.feature.melspectrogram(S=S ** 2, sr=SR)), n_mfcc=13)
    onset = librosa.onset.onset_strength(S=librosa.amplitude_to_db(S), sr=SR)

    bars = []
    feats = []
    bar_times = list(downbeats)
    for i, start in enumerate(bar_times):
        end = bar_times[i + 1] if i + 1 < len(bar_times) else min(start + 4 * 60 / (bpm or 120), duration)
        a, b = librosa.time_to_frames([start, end], sr=SR, hop_length=HOP)
        b = max(b, a + 1)
        seg = slice(a, min(b, S.shape[1]))
        if seg.stop <= seg.start:
            continue
        bars.append({
            "t": round(float(start), 4),
            "db": round(float(db[seg].mean()), 2),
            "low": round(float(librosa.amplitude_to_db(np.array([low[seg].mean() + 1e-9]))[0]), 2),
            "perc": round(float(perc[seg].mean()), 3),
            "onset": round(float(onset[seg].mean()), 3),
        })
        feats.append(np.concatenate([chroma[:, seg].mean(axis=1), mfcc[1:, seg].mean(axis=1) / 50.0]))
    novelty = _novelty(np.array(feats)) if feats else np.zeros(0)
    for bar, nov in zip(bars, novelty):
        bar["novelty"] = round(float(nov), 3)

    # Phrase grid: the 8-bar offset whose bars carry the most structural change.
    phrase_offset = 0
    if len(novelty) >= 16:
        scores = [novelty[o::8].sum() for o in range(8)]
        phrase_offset = int(np.argmax(scores))

    key = detect_key(chroma.mean(axis=1))
    return {
        "version": ANALYSIS_VERSION,
        "duration": round(duration, 3),
        "bpm": round(bpm, 3) if bpm else None,
        "steadiness": round(steadiness, 3),
        "beats": [round(float(b), 4) for b in beats],
        "downbeats": [round(float(d), 4) for d in downbeats],
        "bars": bars,
        "phraseOffset": phrase_offset,
        "firstAudible": round(first_audible, 3),
        "lastAudible": round(last_audible, 3),
        "loudEnd": round(loud_end, 3),
        "fadeEnd": round(fade_end, 3),
        "fadeOut": bool(fade_out),
        "refDb": round(ref, 2),
        "lufs": integrated_loudness(path),
        "key": key,
    }


if __name__ == "__main__":
    import sys
    print(json.dumps(analyze(sys.argv[1]), indent=1)[:3000])
