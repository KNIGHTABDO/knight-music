# Library list screens

Allowed files: everything in KnightMusic/UI/Library/ (rewrite all stubs there, add files there).

- `ArtistsView` (ref/IMG_1163.PNG): `.navigationTitle("Artists")`, `.searchable(prompt: "Search")`, List of `ArtistRow` grouped in
  sections by first letter ("#" for digits/symbols, Arabic and other non-Latin names grouped under "#" or their own letter — sensible),
  section headers like the ref, trailing `AlphabetIndexScrubber` overlay that scrolls (ScrollViewReader) to the section.
  Row → `.artist(id)`. Sort menu in toolbar (Name, Album count). Context menu: Play All / Shuffle (songs of the artist via library), Favorite.
- `FavoriteArtistsView`: same layout with `library.favoriteArtists()`, title "Favorite Artists", empty state "No Favorite Artists".
- `AlbumsView` (ref/IMG_1164.PNG): title "Albums", `.searchable(prompt: "Search in Albums...")`, `AdaptiveAlbumGrid` of AlbumTiles
  sectioned by letter with a circular letter badge header like the ref ("#" in a dark circle, accent text), trailing AlphabetIndexScrubber.
  Toolbar sort Menu: Name, Artist, Year, Recently Added, Most Played, Recently Played (no letter sections unless sorted by name/artist).
  Tile → `.album(id)`; tile context menu: Play, Shuffle, Play Next, Add to Queue, Download, Favorite.
- `SongsView`: title "Songs", searchable, List of SongRow (with artwork) for `library.songs(sort:search:)`, sort menu (Title, Artist,
  Album, Year, Recently Added, Most Played), top buttons row "Play" / "Shuffle" (`.buttonStyle(.glass)` side by side) playing the
  whole (filtered) list. Row tap plays the list from that row. Context menu + ••• menu with SongActionsMenu. Must stay smooth with
  thousands of songs (List, not VStack).
- `PlaylistsView` (ref/IMG_1165.PNG): title "Playlists", `.searchable(prompt: "Search in Playlists")`, List of PlaylistRow (mosaic,
  name, "67 Songs • 3 hrs, 23 min"), chevrons. Toolbar "+" → sheet to create a playlist (name field → `library.createPlaylist`).
  Swipe to delete with confirmation (`library.deletePlaylist`). Row → `.playlist(id)`.
  The mosaic needs up to 4 coverArts per playlist: get them from the playlist's songs (playlistSongs query) or the playlist coverArt — check what's available; keep it efficient.
- `GenresView`: title "Genres", searchable List: genre name + "N songs • M albums", → `.genre(name)`.
- `RadioStationsView`: title "Radio Stations", List of stations (antenna icon, name, homepage host); tap → `player.playRadio(station)`;
  playing station shows NowPlayingIndicator. Empty state "No Radio Stations" + hint "Add stations in Navidrome".
- `AlbumListView(kind:)`: title `kind.title`, AdaptiveAlbumGrid of the right data: recentlyPlayed → albums(sort: .recentlyPlayed),
  recentlyAdded → .recentlyAdded, frequentlyPlayed → .mostPlayed, random → homeList(.random) plus a toolbar "Shuffle again" button that
  re-fetches (`library.refreshHomeLists()`), favorites → favoriteAlbums(). Context menus like AlbumsView.
- `SongListView(kind:)`: favorites → favoriteSongs(), downloaded → downloadedSongs() (+ toolbar Menu: "Delete All Downloads" with
  confirmation, total size via StorageManager if easy), recentlyAdded → recentlyAddedSongs(). Play/Shuffle buttons row, SongRows with
  download badges, SongActionsMenu. Empty states per kind ("No Favorite Songs", "No Downloads — download albums or songs to listen offline").
- `LibraryHubView` (iPhone Library tab, like Apple Music's Library page): `.navigationTitle("Library")`, List with rows (accent SF Symbol +
  title + chevron) for: Playlists, Artists, Albums, Songs, Genres, Favorite Artists, Favorite Albums, Favorite Songs, Downloaded, Radio Stations,
  Recently Played, Frequently Played, Random — each a NavigationLink(value: Route...). Below the list: "Recently Added" AdaptiveAlbumGrid
  (first 12 of homeList(.newest)) like Apple Music.

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
