In-car playback reliability: interruptions, Wi-Fi to Tailscale handoff, steering-wheel seek, Now Playing accuracy

Knight Music plays in CarPlay through the system Now Playing screen (MPNowPlayingInfoCenter + MPRemoteCommandCenter). Make that
path flawless. Read first: KnightMusic/Core/Playback/* (all files), KnightMusic/App/AppModel.swift (networkChanged, reresolveAddress,
how `client` is replaced when the address changes, how the player gets the new client), KnightMusic/Core/API/AddressResolver.swift,
KnightMusic/Core/Support/NetworkMonitor.swift, KnightMusic/App/ServiceWiring.swift.

## Files you own
KnightMusic/Core/Playback/* (any file), KnightMusic/App/AppModel.swift (only networking/address-change hooks into the player),
KnightMusic/App/ServiceWiring.swift. Another agent owns KnightMusic/CarPlay/* and KnightMusic/Intents/* — do not touch them.

## Items
1. Interruptions (phone call, Siri, navigation prompt with interruption). `AudioSessionController.onInterruptionBegan` is never
   wired (PlayerEngine+Playback.swift `wireAudioSession`). Wire it: keep `userWantsPlaying` as is (so `.shouldResume` can resume),
   mark the engine interrupted, make sure an in-progress AutoMix transition is settled cleanly (use the existing settle/cancel
   helpers in PlayerEngine+AutoMix.swift; read them, pick the one that leaves one consistent deck playing) and both decks are paused,
   update Now Playing to paused with the correct elapsed time. On `.ended` + shouldResume: reactivate the session if needed and resume.
   On `.ended` without shouldResume: stay paused, Now Playing paused. Also handle `AVAudioSession.InterruptionReasonKey`
   `.routeDisconnected` / `.appWasSuspended` correctly (do not auto-resume for those).
2. Route changes: car Bluetooth/CarPlay disconnect already pauses (`onRouteLost`). Keep. Make sure a route change to a new device
   while playing (CarPlay connect) never stops playback and never restarts the song.
3. LAN to Tailscale handoff mid-song. Scenario: song streaming from the LAN address, user drives away, Wi-Fi drops, the app switches
   to the Tailscale address. Today the current AVPlayerItem fails and `handleFailure` marks the song failed and skips. Required:
   when the current item is a network stream (not a downloaded or cached file) and it fails or stalls (buffering > 6 s while
   `userWantsPlaying`), and the network path changed or the address resolver picked a new address, re-resolve the address (use the
   existing AppModel/AddressResolver API — do not write a second resolver), then reload the SAME queue entry at the current elapsed
   position with a fresh stream URL from the new client, keeping play state. Allow at most 2 such retries per entry per 60 s, then
   fall back to the existing failure behaviour. Do the same when `NetworkMonitor` reports the path changed while a stream is
   buffering. Also re-prepare the prepared next item (`nextPrepared`) if its URL points to the old address. Log each step with
   PlaybackLog.logger. A cached/downloaded current song must never be interrupted by address changes.
4. Steering-wheel hold-to-seek. Enable `seekForwardCommand` and `seekBackwardCommand` (RemoteCommands.swift) for non-radio
   playback: on `.beginSeeking` start a MainActor Task that jumps ±10 s every 0.35 s (clamped to 0...duration-1) via the engine's
   existing seek; on `.endSeeking` stop it. Cancel it on track change/pause. Do NOT enable skipForward/skipBackward (they replace
   the next/previous buttons in CarPlay).
5. previous(): if elapsed > 3 s, restart the current song; else go to the previous song (verify current behaviour; fix only if it differs).
6. Now Playing accuracy (NowPlayingCenter.swift and callers):
   a. Publish elapsed time + rate only on events (play, pause, seek, item change, rate change, interruption, buffering start/end),
      never from a periodic timer; while buffering publish rate 0 so the car's progress bar does not run ahead.
   b. AutoMix: when a transition changes a deck's playback rate (tempo ramp), publish `MPNowPlayingInfoPropertyPlaybackRate` and
      elapsed for the deck that is "current" for Now Playing; at handoff switch metadata exactly once (no flicker, no blank frame).
   c. Artwork: when the song changes, if the new cover is already in the image cache use it synchronously in the same publish
      (read ArtworkLoader.swift; add a small synchronous cache-lookup method there if needed — ArtworkLoader is in Core/Artwork, you
      may add ONE method to it). Otherwise publish without artwork (never the previous song's art) and fill it in when loaded,
      ignoring late loads for a song that is no longer current. Artwork request handler must return an image for any requested size.
   d. Radio (`currentRadio != nil`): set `MPNowPlayingInfoPropertyIsLiveStream = true`, title = station name, omit
      queue index/count, duration and elapsed; next/previous/seek/changePlaybackPosition disabled (already partly done).
   e. Keep `MPNowPlayingInfoPropertyPlaybackQueueIndex/Count`, `MPNowPlayingInfoCenter.playbackState` (.playing/.paused/
      .interrupted/.stopped) correct at all times, including after queue end (stopped) and on cold launch with restored queue (paused,
      with metadata + artwork shown so pressing play on the steering wheel works).
   f. `RemoteCommands.refresh()` must run after every song change, star change, repeat/shuffle change, queue edit and radio start.
7. Cold background launch: with the queue restored paused (existing restore), a remote `playCommand` arriving before
   `AppModel.start()` finished resolving the address must still play: if the current song is not local, wait (max 5 s) for the
   address resolution in progress, then play. Read how AppModel exposes it; add a minimal async hook if none exists.
