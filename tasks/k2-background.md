# Knight: survive app switching (durable Hermes runs)

Other Gemini agents are editing OTHER parts of the Knight feature at the same time. Stay strictly inside your allowed files/functions so the merge is clean. Read the files you touch completely first.
Allowed: KnightMusic/Core/Hermes/HermesClient.swift, KnightMusic/Core/Hermes/HermesService.swift EXCEPT the functions
runArrivalWatcher/appendMatchedSong (another agent owns those), KnightMusic/Core/Hermes/KnightConversationStore.swift (ONLY add fields
to the message model, e.g. runId/status; another agent adds delete/rename functions there).

Problem: the chat uses one long streaming request (/v1/responses). When the user switches tabs it's fine, but when they leave the app
iOS suspends it and the stream dies; the job's result is lost. Switch to Hermes' DURABLE RUNS API (verified on the real server):
- Start: `POST /v1/runs` body `{"model":"hermes-knight","input":"[Knight Music] <text>","session_id":"<conversation id>"}` →
  `{"run_id":"run_…","status":"started"}`. `session_id` gives conversation memory across runs (verified).
- Events (SSE, replayable even after completion): `GET /v1/runs/{run_id}/events` → lines `data: {json}` (NO event: lines;
  the type is the json field "event"). Seen events: `message.delta` (field "delta" = text chunk), `reasoning.available` (ignore),
  tool events (log every unknown "event" name once; map anything containing "tool" with fields like tool_name/name/preview/args to
  toolStarted/toolFinished), `run.completed` (field "output" = full final text), and failures (`run.failed`/error fields).
  IMPORTANT: `URLSession.bytes(...).lines` drops empty lines — parse each `data:` line on its own (see current HermesClient for the fixed approach).
- Status: `GET /v1/runs/{run_id}` → `{"status": "running"|"completed"|…, "completed": bool, "output": "<final text>", ...}`.
- Stop: `POST /v1/runs/{run_id}/stop`.
All with `Authorization: Bearer <key>`.
Implement: HermesClient.startRun / events(runId) stream / runStatus / stopRun. HermesService.sendMessage: start the run, persist runId +
"running" on the assistant message immediately, then consume events. Wrap with `UIApplication.shared.beginBackgroundTask` (end it when
done/expired). On `didEnterBackground` let the stream die quietly; on `willEnterForeground` and at app launch, for every message
still "running": GET status → if completed, take "output" as the final text (then run the existing completion path: parse
knight-added block and call runArrivalWatcher exactly as today); if still running, reconnect to /events (events replay from the start —
rebuild the text from scratch, don't duplicate). Keep the public API used by the UI (state per conversation: text, steps, isRunning,
stop) unchanged so KnightChatView keeps compiling. Remove the old /v1/responses streaming path.

## Shared context for every screen task (read carefully)
- Read CLAUDE.md first (Liquid Glass rules + visual spec). Look at the reference screenshots `ref/IMG_1160.PNG` … `ref/IMG_1172.PNG`
  (Arpeggi on iPad — our exact visual target: black background, red accent, big bold titles, rounded search field,
  album tiles with title + secondary subtitle, inset grouped settings cards).
- Data comes ONLY from the real app services, injected in the environment:
  `@Environment(AppModel.self) var app`, `@Environment(LibraryRepository.self) var library`,
  `@Environment(PlayerEngine.self) var player`, `@Environment(DownloadManager.self) var downloads`,
  `@Environment(AppSettings.self) var settings`, `@Environment(UIState.self) var ui` (KnightMusic/UI/Shell/UIState.swift).
- Library reads use LiveQuery (read KnightMusic/Core/Library/LiveQuery.swift, LibraryRepository.swift, LibraryQueries.swift,
  LibraryTypes.swift for the exact factory names/params/return types):
      let albums = library.albums(sort: .name, search: nil)   // call in body; it's cached
      ... ForEach(albums.value) ...
      .observing(albums)                                        // REQUIRED on the view that shows it
  Use `query.isLoaded` to show a skeleton (`SkeletonTileGrid` / `SkeletonRowList`) instead of a flash of the empty state;
  show `EmptyStateView` only when loaded and empty.
- Playback: `player.play(songs, startAt: index, shuffle: false)`, `player.enqueue(songs, next: true/false)`,
  `player.currentSong?.id` to highlight the playing row. Read KnightMusic/Core/Playback/PlayerEngine*.swift for names.
- Navigation: push with `NavigationLink(value: Route.album(album.id)) { ... }` (KnightMusic/UI/Shell/Routes.swift).
  Do NOT add your own navigationDestination for Route; the shell applies `.withAppRoutes()`.
  Your views must NOT wrap themselves in a NavigationStack (the shell owns it).
- Reuse the design system in KnightMusic/UI/DesignSystem (open the files for exact initializers): Theme, Font.km*,
  KMFormat, ArtworkView, HeroArtworkView, AnimatedArtworkView, AlbumTile, AdaptiveAlbumGrid, ShelfSection, SectionHeader,
  SongRow, NowPlayingIndicator, ArtistRow, PlaylistRow, PlaylistMosaic, AlphabetIndexScrubber, StarRatingView,
  EmptyStateView, LoadingShimmer/SkeletonRowList/SkeletonTileGrid, GlassIconButton, GlassCapsuleBar.
- Song menus: use `SongActionsMenu(song:)` (KnightMusic/UI/Detail/SongActionsMenu.swift) inside `.contextMenu { }` on song rows
  and inside the row's ••• `Menu`.
- Liquid Glass: real APIs only (`.glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`).
  Never `.ultraThinMaterial`/fake blur panels. Content (rows, tiles) is never glass.
- Lists: `.searchable(text:)` where the brief says so (system search field = glass automatically), `.refreshable { await app.pullToRefresh() }`
  on library screens. `.navigationTitle(...)` with large display mode. Black background: `.scrollContentBackground(.hidden)` + `.background(Color.black)` for Lists.
- Everything must work on iPhone (compact) and iPad (regular) — use adaptive layouts, not fixed widths.
- Smoothness: LazyVStack/LazyVGrid/List, stable ids, no heavy work in body, `.animation(.smooth, value:)` on state changes,
  `Haptics` (KnightMusic/Core/Support/Haptics.swift) on play/star.
- No fake/sample data, no TODO placeholders, no "coming soon". Every button does its real job.
