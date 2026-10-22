Siri in the car: complete hands-free App Shortcuts for Knight Music

Siri works in CarPlay through App Shortcuts (App Intents). Read first: KnightMusic/Intents/* (all), KnightMusic/App/AppModel.swift
(startIfNeeded, session), KnightMusic/Core/Playback/PlayerEngine.swift + PlayerEngine+Queue.swift (play/resume/pause/next/previous/
enqueue/setShuffle), KnightMusic/Core/Library/LibraryRepository.swift.

## Files you own
KnightMusic/Intents/* only. Other agents edit Core/Playback and KnightMusic/CarPlay at the same time.

## Items
1. Every intent that plays audio must work with the phone locked and the app not running: conform to `AudioPlaybackIntent` where it
   starts/controls playback, `static var openAppWhenRun: Bool = false`, `static var authenticationPolicy: IntentAuthenticationPolicy
   = .alwaysAllowed`, and at the start of perform call `AppModel.shared?.startIfNeeded()` (check how intents currently get the
   model — keep that path) and wait (max 5 s, polling `session` every 100 ms) until the session is `.ready` before playing. If not
   signed in, throw an error whose message tells the user to open Knight Music and sign in.
2. Add intents that are missing (check Entities.swift / PlayIntents.swift for what exists, reuse entities and queries):
   - PlayArtistIntent (artist entity → play that artist's songs, shuffled) if not already present.
   - PlaySongIntent (song entity, entity query searches the local library by title via the existing search APIs).
   - ResumeIntent ("Resume", plays if paused, no toggle), PauseIntent (pause only), PreviousTrackIntent, ToggleShuffleIntent? NO —
     keep it to Resume, Pause, Previous.
   - PlayDownloadsIntent: plays downloaded songs shuffled (works fully offline).
3. ShortcutsProvider: App Shortcuts allow at most 10 `AppShortcut`s. Pick the 10 most useful for driving, in this order:
   Play album, Play artist, Play playlist, Play song, Shuffle library, Play favorites, Play downloads, Resume, Pause, Next.
   (Previous stays an intent without a shortcut phrase if it does not fit.) Each phrase must contain `\(.applicationName)`;
   give 2–4 natural phrases each, e.g. "Play \(\.$artist) on \(.applicationName)", "Play \(\.$artist) in \(.applicationName)",
   "Resume \(.applicationName)", "Continue \(.applicationName)", "Play music on \(.applicationName)" (→ Resume when a queue exists,
   else shuffle library — implement that in ResumeIntent). Provide `shortTitle` and `systemImageName` for each.
   Parameterized phrases need `AppShortcutsProvider.updateAppShortcutParameters()` to be called after library sync — find whether it
   is called; if not, add a static helper in Intents and mention in your final response where it should be called (do not edit
   files outside Intents).
4. Entity queries must read only the local GRDB mirror (fast, offline), return at most 50 suggestions, and `EntityStringQuery`
   matching must be case/diacritic-insensitive.
5. Dialog: return `.result(dialog:)` with a short spoken confirmation ("Playing Discovery by Daft Punk").
