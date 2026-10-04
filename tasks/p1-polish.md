# Polish pass 1: sidebar, accessory, player fixes [shots]

Allowed files: KnightMusic/UI/Shell/*, KnightMusic/UI/Player/*, KnightMusic/UI/Library/AlbumsView.swift, KnightMusic/App/DebugLaunch.swift.
Screenshots of the current app were reviewed; fix exactly these problems:

1. iPad must open with the SIDEBAR visible (like ref/IMG_1160.PNG), not the top floating tab bar. In MainTabsView (regular width) apply
   `.defaultAdaptableTabBarPlacement(.sidebar)` to the TabView (iPadOS 18+ API). Keep `.tabViewStyle(.sidebarAdaptable)`.
   If the compiler rejects that modifier name, do NOT invent alternatives — leave it out and say so in your summary.
   Also add the sidebar header showing the account name in big bold text ("KNIGHT" style) with `.tabViewSidebarHeader { }` if it isn't there yet.
2. The bottom accessory (mini player) currently shows as an EMPTY glass bar when nothing is playing. It must not appear at all
   when `player.currentSong == nil`. Use `if #available(iOS 26.1, *) { .tabViewBottomAccessory(isEnabled: player.currentSong != nil) { ... } }`
   and for iOS 26.0 fall back to attaching the accessory only when a song exists (two branches of the view, e.g. a ViewModifier
   with an `if`). Check every place the accessory is attached.
3. On iPhone, launching with `-KMScreen player` or `-KMScreen lyrics` shows the Home screen instead of the full player
   (on iPad it works; `-KMScreen queue` works on iPhone). Find why in the routing (DebugLaunch.applyRouting / RootView / MainTabsView —
   probably the fullScreenCover is attached to a view that isn't in the hierarchy yet in compact width, or isPlayerPresented is set
   before the compact TabView appears). Make presentation reliable in both size classes (e.g. present after the tab view's onAppear,
   or attach the fullScreenCover at the RootView level).
4. iPad full player: the artwork in the left column is far too small (about a quarter of the width with huge empty space). In regular
   width the artwork must be large: side = min(leftColumnWidth - 64, availableHeight * 0.62), centered vertically in its column,
   12pt radius, shadow. Use GeometryReader for the size.
5. AlbumsView: the trailing AlphabetIndexScrubber overlaps the right column of album tiles on iPhone. Add trailing padding to the grid
   equal to the scrubber width (~22pt) when the scrubber is visible.
6. Accent color from Settings → Customize is stored in `settings.accentColorHex` but not applied. In RootView apply
   `.tint(<Color from settings.accentColorHex>)` at the top level (check AppSettings for an existing `accentColor` computed property).

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
