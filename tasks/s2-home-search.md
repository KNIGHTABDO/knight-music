# Home and Search screens

Allowed files: KnightMusic/UI/Home/* and KnightMusic/UI/Search/* (rewrite the stubs HomeView.swift / SearchView.swift, add files there).

## HomeView (match ref/IMG_1160.PNG)
- ScrollView with LazyVStack, `.navigationTitle(app.activeAccount?.name ?? "Home")`, large title (e.g. "KNIGHT").
- Shelves (each a `ShelfSection` with header "Title ›" whose tap pushes the full list via NavigationLink(value:)):
  1. "Up Next" — the player's upcoming queue (`player.queue` / `player.upcoming`), song tiles (artwork + title + artist); tapping
     plays from that index (`player.skip(toUpcomingOffset:)`). If empty show the secondary text "No items available..." exactly like the ref.
  2. "Recently Played" — `library.homeList(.recent)` → push `.albumList(.recentlyPlayed)`.
  3. "Recently Added" — `library.homeList(.newest)` → `.albumList(.recentlyAdded)`.
  4. "Most Played" — `.homeList(.frequent)` → `.albumList(.frequentlyPlayed)`.
  5. "Favorite Albums" — `.homeList(.starred)` → `.albumList(.favorites)` (hide the shelf if empty).
  6. "Random" — `.homeList(.random)` → `.albumList(.random)`.
  7. "Playlists" — horizontal shelf of playlist mosaics (`library.playlists()`), tap → `.playlist(id)`.
- Album tile tap → `.album(id)`; long-press context menu on album tiles: Play, Shuffle, Play Next, Add to Queue, Download, Favorite/Unfavorite
  (fetch songs with `await library.albumContent(id:)` for play actions; `downloads.download(songs:)`; `library.setStarred(.album, ...)` — check the kind enum).
- `.refreshable { await app.pullToRefresh(); await library.refreshHomeLists() }`.
- Top-right toolbar: a `Menu` (ellipsis.circle) with "Shuffle All" (plays random songs: use `library.songs(sort:..)` or a random
  query — check what exists; shuffle play the whole library) and "Refresh Library".
- Sync banner: while `app.syncStatus.isSyncing` on first full sync (library empty) show a compact progress row at the top with phase text and a ProgressView(value:).
- iPad: tiles ~200pt; iPhone ~150pt (ShelfSection handles sizing — check).

## SearchView (ref/IMG_1161.PNG)
- `.navigationTitle("Search")`, `.searchable(text: $query, prompt: "Search library...")`.
- Empty query: centered empty state with magnifying glass icon, "Search Library", "Search for artists, albums, or songs in your library." — exactly like the ref.
  Below it (when there is space) a "Recently Searched" list of the last 10 queries stored in UserDefaults (tap to reuse, "Clear" button).
- Typing: debounce 200ms, `library.search(query)` (check return type) → sections "Artists" (horizontal row of circular ArtistRow-style
  tiles or ArtistRow list, max 8, "See All" not needed), "Albums" (horizontal shelf of AlbumTiles), "Songs" (SongRow list with artwork,
  tap plays the song list starting there; context menu SongActionsMenu). Top hit: if the best match is an artist or album show it big first.
- Results update live as the user types without flicker (keep previous results until new ones arrive). Works with Arabic text.
- No results: EmptyStateView "No Results" with the query.

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
