# Knight (Hermes AI) chat: client, chat UI, settings, tab [shots]

Knight Music talks to the user's own Hermes agent (Nous Research hermes-agent) which can download songs into the Navidrome library.
Allowed: new folders `KnightMusic/Core/Hermes/` and `KnightMusic/UI/Knight/`, plus small edits to: KnightMusic/UI/Shell/MainTabsView.swift,
KnightMusic/UI/Shell/UIState.swift, KnightMusic/UI/Shell/Routes.swift (only if needed), KnightMusic/UI/Settings/SettingsView.swift (one row),
project.yml (Info.plist usage strings), KnightMusic/App/AppModel.swift (only to own a `HermesService` instance + environment injection in
KnightMusicApp.swift). Read the existing code you touch first.

## Hermes API contract (verified against the real server)
- Base URL (user setting), default `https://desktop-1rsqaqq.tail7d75d9.ts.net:8643`. Auth header `Authorization: Bearer <key>`.
- `GET /health` → `{"status":"ok","platform":"hermes-agent","version":"0.21.3"}` (no auth). `GET /v1/models` (auth) → list incl. id `hermes-knight`.
- Chat: `POST /v1/responses` JSON `{"model":"hermes-knight","stream":true,"store":true,"conversation":"<conversation id>","input":"[Knight Music] <user text>"}`.
  The server keeps the conversation history per `conversation` id (memory verified), so the app sends only the new message.
  ALWAYS prefix the input with `[Knight Music] ` (the server skill relies on it) — but never show that prefix in the UI.
- Streaming = Server-Sent Events: lines `event: <type>` then `data: <json>` then blank line. Types seen:
  `response.created`; `response.output_item.added` / `response.output_item.done` where `data.item.type` is `function_call`
  (fields: name, call_id, arguments JSON string, status) or `function_call_output` (call_id, output) or `message`;
  `response.output_text.delta` (`data.delta` = text chunk to append); `response.output_text.done`; `response.completed`
  (`data.response.output` final items); errors may arrive as `event: error` or `response.failed` — show them.
  Tool runs take seconds to minutes (a download ~30–90s). Use `URLSession.bytes(for:)` and parse lines incrementally; timeout ≥ 10 min.
- Stop: cancel the streaming task (and show "Stopped").

## Core/Hermes
- `HermesSettings` (@Observable): baseURL (UserDefaults), apiKey (Keychain via the existing Keychain helper in Core/API/Keychain.swift — check its API),
  `isConfigured`. Never log the key.
- `HermesClient` (actor): `health()`, `checkAuth()`, `stream(conversation:input:) -> AsyncThrowingStream<HermesEvent, Error>` with
  `enum HermesEvent { case textDelta(String), toolStarted(id, name, argumentsJSON), toolFinished(id), completed(fullText), failed(String) }`.
- `KnightConversationStore`: conversations persisted as JSON in Application Support/Knight/ (id = "km-<uuid>", title = first user message
  truncated, updatedAt, messages [role, text, toolSteps, addedTracks, date]). Instant display from disk; newest first.
- `ToolStepLabel`: friendly labels from tool name + arguments (arguments is JSON; for `terminal` read the `command` field):
  yt-dlp → "Downloading audio", ffmpeg → "Tagging & embedding cover", itunes.apple.com → "Fetching cover art", lrclib → "Fetching synced lyrics",
  search_files/ls/find → "Checking your library", skill_view → "Reading music skill", web_search/browser → "Searching the web", else "Working…".
  SF Symbol per label.
- `KnightAddedParser`: extract the LAST fenced block ```knight-added … ``` from the final text → `[AddedTrack {artist,title,album,folder,playlist?}]`;
  strip the block from the displayed text.
- `HermesService` (@MainActor @Observable, owned by AppModel, injected into the environment): sends messages, holds the live streaming state
  per conversation (current text, steps with running/done, isRunning), saves to the store, and after completion with added tracks runs
  `ArrivalWatcher`: call `app.refresh(force: false)` (check the AppModel API) every 5s for up to 90s, each time matching every AddedTrack
  against the local DB (`library.search` by title, then compare artist case-insensitively) until all are found; publish matched `Song`s
  into the message (persist their ids). Then `ui.showToast("Added <title> to your library")` and prefetch animated artwork for them
  (AnimatedArtworkService.prefetch). If not found after 90s, mark "Still importing — pull to refresh later".

## UI/Knight (Liquid Glass, Apple-quality)
- `KnightView` = conversation list (NavigationStack root): "Knight" large title, "New Chat" toolbar button (square.and.pencil), rows
  (title, last message preview, relative date), swipe to delete. Empty state: sparkles icon, "Ask Knight", "Ask for any song, album or
  playlist — Knight adds it to your library." + 4 suggestion chips ("Add the latest Travis Scott album", "Make me a chill rai playlist",
  "Add Blinding Lights by The Weeknd", "What did I add this week?").
  When not configured: EmptyStateView with "Connect Hermes" button → settings sheet.
- `KnightChatView(conversationId)`: scrolling transcript (LazyVStack, auto-scroll to bottom while streaming, respects manual scroll),
  user bubbles right (accent tint, rounded 20), assistant text left (no bubble, 17pt, Markdown via `AttributedString(markdown:)` with
  `.inlineOnlyPreservingWhitespace`), live tool steps as a compact vertical list of chips under the assistant message (ProgressView
  while running → checkmark when done, smooth transitions), typing shimmer before the first token.
  Added tracks: horizontal cards (ArtworkView 64pt, title, artist) with Play and "Play Next" buttons (player.play / enqueue), and an
  "Importing…" state with ProgressView while the ArrivalWatcher runs.
  Composer pinned at the bottom: multi-line TextField ("Ask Knight…") inside a capsule with `.glassEffect(.regular.interactive(), in: .capsule)`,
  trailing send button (arrow.up.circle.fill, accent) that becomes a stop button (stop.circle.fill) while running; mic button for dictation
  using `SFSpeechRecognizer` on-device (`requiresOnDeviceRecognition = true` when supported) + AVAudioEngine; tap to start/stop, live text
  into the field. Add NSMicrophoneUsageDescription + NSSpeechRecognitionUsageDescription to project.yml info properties.
  Composer must sit above the mini player / tab bar correctly (use `.safeAreaInset(edge: .bottom)`).
- `HermesSettingsView`: Form with Server URL, API Key (SecureField), "Test Connection" (health + auth → green "Connected · hermes-agent 0.21.3"
  or red error), footer explaining it should be a Tailscale-only address. Reachable from Settings (new row "Knight AI (Hermes)" with sparkles
  icon in the Playback/Storage section) and from KnightView when unconfigured.
- Navigation: add a "Knight" tab (systemImage "sparkles") in BOTH tab sets of MainTabsView: iPad sidebar right after Search; iPhone between
  Library and Settings. `UIState.Tab.knight`. Add to UIState: `var knightDraft: String?` and
  `func askKnight(_ prompt: String) { knightDraft = prompt; selectedTab = .knight }` — KnightView opens a new chat with the draft
  pre-filled (not auto-sent) when knightDraft is set, then clears it. (Other screens will call ui.askKnight later.)
- Screenshot mode: add `knight` to the routing (debugScreen "knight" → select the Knight tab) and append `knight` to SCREENS in
  scripts/screens.sh (you may edit that one line). In demo mode Hermes is not configured — the unconfigured empty state must look great.

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
