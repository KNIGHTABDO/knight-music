# Album, artist, playlist, genre pages and the song actions menu

Allowed files: everything in KnightMusic/UI/Detail/ (rewrite the stubs AlbumDetailView, ArtistDetailView, PlaylistDetailView,
GenreDetailView, SongActionsMenu; add files there).

## AlbumDetailView(albumId:) — Apple Music album page
- `library.album(id:)` LiveQuery (returns album + songs; check `AlbumContent`).
- Header (scrolls with content): large artwork centered (iPhone ~ 70% width, iPad 300pt; 10pt radius, soft shadow) — use
  `HeroArtworkView` so the animated artwork plays when available; album title (22 bold), artist name in accent color (17, tappable →
  `.artist(artistId)`), "Genre • Year" (13 secondary). iPad regular width: artwork left, info + buttons right (HStack) like Apple Music iPad.
- Two buttons: "Play" (play.fill) and "Shuffle" (shuffle) side by side, `.buttonStyle(.glass)`, accent tint, equal width.
- Track list: rows with track number (secondary, width 28) instead of artwork, title, (artist only if it differs from album artist),
  duration trailing, ••• Menu with SongActionsMenu, download badge, NowPlayingIndicator replacing the number when playing.
  Disc headers ("Disc 2") when multiple discs. Inset separators.
- Footer: "N songs, H hr M min" + release date/created (13 secondary).
- Toolbar: heart button (favorite toggle, filled accent when starred, haptic), download button (arrow.down.circle → download all;
  shows progress ring while downloading, checkmark when all downloaded; tap when done offers "Remove Download"), and a ••• Menu: Play Next,
  Add to Queue, Add to Playlist…, Go to Artist, Share (ShareLink with album name + artist).
- `.toolbar(.visible)` with transparent nav bar over the header; `.scrollEdgeEffectStyle(.soft, for: .top)`.
- Use `.backgroundExtensionEffect()` on the hero artwork for iPad width.
- More by the artist: shelf at the bottom "More by <artist>" (albums(artistId:) excluding this one).

## ArtistDetailView(artistId:)
- Header: big artist image (artistInfo largeImageUrl via `await library.artistInfo(artistId:)`, fallback ArtworkView of artist coverArt)
  as a full-width hero ~ 320pt tall with gradient fade to black at the bottom and the artist name (34 heavy) overlaid bottom-left, plus a
  play button (`.buttonStyle(.glassProminent)` circle with play.fill) bottom-right → plays top songs (or all songs).
- Sections: "Top Songs" (`library.topSongs(artistId:)`, first 5 rows with artwork, "See All" pushes full list in a simple List view
  you define), "Albums" (horizontal ShelfSection of `library.albums(artistId:)` sorted newest first), "Appears On" if data allows (skip if not),
  "About" (biography text from artistInfo, HTML tags stripped, 4 lines with "More" expanding), "Similar Artists" (circular tiles from
  artistInfo similar artists that exist in the local library → `.artist(id)`).
- Toolbar: favorite heart (setStarred .artist), ••• Menu: Shuffle All, Play Next (all songs), Download All.

## PlaylistDetailView(playlistId:)
- Header: `PlaylistMosaic` (big, 240pt) or playlist coverArt, name (22 bold), "N Songs • duration", owner/comment secondary.
- Play / Shuffle glass buttons. Song rows with artwork + ••• SongActionsMenu (plus "Remove from Playlist").
- Edit mode (toolbar "Edit" button): `.onMove` → `library.movePlaylistEntries`, `.onDelete` → `library.removeFromPlaylist(id:indexes:)`.
  Toolbar ••• Menu: Rename (alert with text field → renamePlaylist), Download All, Delete Playlist (confirmation, then pop).
- Live: updates when sync/mutations change it (LiveQuery).

## GenreDetailView(genre:)
- Title = genre. Segmented Picker "Albums" / "Songs". Albums: AdaptiveAlbumGrid of `library.albums(genre:)`; Songs: SongRows of
  `library.songs(genre:)` with Play/Shuffle buttons.

## SongActionsMenu(song:) (used everywhere as menu content — only Buttons/Menus/Dividers, no layout)
- Play Next (`player.enqueue([song], next: true)`) and Add to Queue (`next: false`) → toast via `ui.showToast("Added to Queue")`.
- Add to Playlist → submenu listing existing playlists from `library.playlists()` (a LiveQuery: read `.value`; start it with `.observing` on a parent or fetch once) → `library.addToPlaylist`. Creating new playlists lives in PlaylistsView, not here.
- Download / Remove Download (check `downloads.status(for:)`/`isDownloaded`).
- Favorite / Unfavorite (`library.setStarred` for songs) with haptic.
- Rate submenu: 1–5 stars + "Clear Rating" (`library.setRating`).
- Go to Album (NavigationLink(value: Route.album) works inside menus), Go to Artist.
- Share (ShareLink with "title — artist").

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
