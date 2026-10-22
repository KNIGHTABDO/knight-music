
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
