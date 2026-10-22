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

## Shared rules for this CarPlay wave (read carefully, they are mandatory)
- Project: Knight Music, a native SwiftUI iOS 26 Navidrome client. Read `CLAUDE.md` first. Swift 5 language mode,
  Xcode 26 SDK, GRDB 7, Nuke 12. There is NO Mac: you cannot compile. Write code that compiles first time: open and
  read every file you call into and use the exact existing names/signatures. NEVER invent an API.
- Three agents are editing this repo AT THE SAME TIME, each in different files. Only edit the files listed under
  "Files you own". If you believe another file must change, do the minimal change only if it is listed as allowed;
  otherwise mention it in your final response instead of editing it.
- Keep every public name/signature listed in CLAUDE.md "Cross-module contracts" unchanged. Keep existing behavior
  unless the brief explicitly changes it. Do not delete features, do not "simplify" unrelated code, no drive-by
  refactors or reformatting of lines you are not changing.
- No placeholder/sample data, no TODOs, no "coming soon". Errors go to `Log` (Core/Support/Log.swift) and, when
  user-facing, to the existing error/toast path used by nearby code. Do not add new `try?` that hides real failures.
- Swift concurrency: UI-facing classes are `@MainActor @Observable`. Pure helpers that run inside GRDB
  `pool.read/write` closures or background tasks must be `nonisolated` / free functions / static on a non-MainActor
  type, never `@MainActor`. Closures passed to GRDB must be `@Sendable`-safe (capture only Sendable values).
- GRDB 7 notes: `pool.write { db in ... }` / `pool.read` are async when awaited from async code. Records here are
  `Codable, Hashable, FetchableRecord, PersistableRecord` (Core/API/Models.swift). `Record.fetchAll(db, keys: ids)`
  fetches by primary key. `record.insert(db)`, `record.update(db)`, `record.upsert(db)` exist.
  SQLite stores dates with MILLISECOND precision, so a `Date` decoded from JSON and the same date read back from the
  DB are often NOT `==`. Any "did this row change?" comparison must compare dates with a tolerance (see
  `sameInstant` in SyncEngine.swift) — plain `==` on whole structs will report false changes.
- Style: match surrounding code (naming, comment density: only non-obvious "why" comments), small focused helpers,
  async/await, no Combine, no force unwraps on data.
- Commit your work locally when done (one commit, message = the first line of this brief). Do not push.
- Final response: max 15 lines — what you changed per numbered item, anything you could not do and why, and any
  file outside your list you think needs a change.
- Background for this wave: the user drives with CarPlay. Research notes in `notes/carplay/` of the MAIN checkout are summarized
  in your brief; you do not need them. Base commit already added `AppModel.startIfNeeded()` (idempotent launch, also called from
  `AppDelegate.didFinishLaunching`), `AppDelegate.application(_:configurationForConnecting:options:)` routing the
  `.carTemplateApplication` role to `CarPlaySceneDelegate`, and `UIApplicationSupportsMultipleScenes: true`. Do not undo these.
- Everything you build must work while the iPhone is LOCKED in a pocket and the app was launched in the background with no phone UI.
