# Knight: reliable import detection (no more endless "Importing…")

Other Gemini agents are editing OTHER parts of the Knight feature at the same time. Stay strictly inside your allowed files/functions so the merge is clean. Read the files you touch completely first.
Allowed: create KnightMusic/Core/Hermes/ArrivalWatcher.swift; in KnightMusic/Core/Hermes/HermesService.swift edit ONLY the functions
`runArrivalWatcher(...)` and `appendMatchedSong(...)` (keep their names/signatures so the call site in sendMessage still compiles);
KnightMusic/UI/Knight/KnightChatView.swift: ONLY the added-tracks card section (the "Importing…" state) to add a "Check again" button.

Bug: after Hermes adds a song, the card stays "Importing…" forever until the user forces a scan in Settings. Navidrome's file
watcher doesn't always pick up the new folder, and `app.refresh(force: false)` only re-syncs when the server's lastScan changed.
Fix, in ArrivalWatcher (called by runArrivalWatcher):
1. Immediately ask Navidrome for a quick scan: `try await client.startScan(fullScan: false)` (check SubsonicClient's exact method) —
   the user's Navidrome is 0.64; then poll `getScanStatus()` every 2s until `scanning == false` (max 120s).
2. Then `await app.refresh(force: true)` (check AppModel's API) so the local DB definitely re-reads the library.
3. Match each AddedTrack against the local DB with normalization: lowercase, strip diacritics, remove "(feat. …)", "[…]", "(…)",
   punctuation and extra spaces; title must match (equal after normalization, or one contains the other) AND artist overlaps
   (any artist token match; the DB artist may be "A/B" or "A, B" or "A feat. B"). If no DB match, ask the server
   `client.search3(query: <title>, songCount: 10, ...)` and match the same way; if the server has it but the DB doesn't yet, do one more
   forced refresh and re-match.
4. Retry steps 2–3 every 5s up to 3 minutes total. Persist the pending watch (conversationId, messageId, tracks) in the conversation
   store's message (use existing fields if present, else a small UserDefaults JSON) so after an app relaunch / foreground
   (`UIApplication.willEnterForegroundNotification`) unfinished watches resume.
5. On success attach the songs (existing appendMatchedSong) + toast; on timeout set the card to "Not found yet" with "Check again"
   (which re-runs the whole watch). Log every step through `Log` (check its API) so Settings → Diagnostics shows what happened.

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
