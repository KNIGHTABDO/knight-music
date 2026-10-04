# Knight Music AutoMix service

Runs next to Navidrome and gives Knight Music Apple-Music-style AutoMix: beat-matched transitions between songs.

- **Analysis** (`automix/analyze.py`): beats and downbeats (Beat This!, ISMIR 2024), tempo and steadiness, 8-bar phrase
  grid from structural novelty, per-bar energy / bass / percussiveness, where the music really starts and ends (silence,
  fade-out), loudness (EBU R128) and key (Camelot). About 30–70 s per song on CPU, once.
- **Sync** (`automix/service.py`): watches Navidrome's database. New or changed songs are analysed seconds after
  Navidrome indexes them, newest first; a song the app asks about jumps the queue. Results live in
  `~/automix/data/analysis.db`.
- **Plans** (`automix/planner.py`): for a pair of songs, either
  - `beatmatch`: a phrase-starting downbeat in A's outro is locked to B's first downbeat; both decks are time-stretched
    (pitch kept) to meet halfway in tempo, grids snapped to the millisecond; B comes in with its bass cut, the basslines
    swap on the middle downbeat and A fades over the second half; B then eases back to its own tempo,
  - `crossfade`: phrase-aligned blend with filter sweeps when tempos or grids don't allow beat-matching,
  - `gapless`: continuous albums whose tracks run into each other.
  The app executes plans sample-accurately (`KnightMusic/Core/AutoMix`, `PlayerEngine+AutoMix.swift`).

## API (under `/automix/v1`, Subsonic auth params `u`/`t`/`s` like any Navidrome call)

| | |
|---|---|
| `GET health` | liveness, no auth |
| `GET status` | tracks, analysed, queued, current job |
| `GET plan?from=<songId>&to=<songId>` | one transition plan (`final: false` while a song is still being analysed) |
| `POST plans` `{"pairs": [[a, b], ...]}` | up to 50 plans at once (the app prefetches the queue) |
| `GET analysis/<songId>` | raw analysis |

Reachable at `https://<tailnet host>/automix/...` (Tailscale Funnel path, see `deploy/install.sh`) and on the LAN at
`http://<host>:4534/automix/...`.

## Install / update

```
server/automix/deploy/install.sh
```

Creates `~/automix/.venv`, copies the code to `~/automix/app`, installs the `knight-automix` systemd unit (low CPU and
IO priority) and the Funnel path.

## Checking quality

```
cd server/automix
~/automix/.venv/bin/python -m automix.cli plan A.mp3 B.mp3 --preview /tmp/mix.mp3 --verify
~/automix/.venv/bin/python -m automix.evaluate --pairs 60 --render 10
```

`verify` beat-tracks each processed deck over the overlap and reports how far B's beats sit from A's
(`phaseErrorMs`, `onsetLagMs`); previews are written to `~/automix/previews`.
