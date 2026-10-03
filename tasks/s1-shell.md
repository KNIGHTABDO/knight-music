# App shell, mini player, login and screenshot routing [shots]

Allowed files: KnightMusic/UI/Shell/RootView.swift (rewrite), new files in KnightMusic/UI/Shell/, KnightMusic/UI/Onboarding/LoginView.swift
(rewrite) + new files in KnightMusic/UI/Onboarding/, KnightMusic/App/DebugLaunch.swift (routing part only).
DELETE KnightMusic/UI/DesignSystem/DesignSystemCatalog.swift (temporary file). Do not edit other files.

## RootView
- Owns `@State private var ui = UIState()` and injects `.environment(ui)`.
- If `app.session` is `.loggedOut` or `.failed` (and no active account) → `LoginView()`. `.connecting` with no account → LoginView showing progress.
  Otherwise → `MainTabsView`.
- Toast: when `ui.toast` is set, show a small capsule at the top with `.glassEffect(.regular, in: .capsule)`, auto-dismiss after 2.5s, smooth transition.
- Also surface `library.lastError` / `player.lastError` changes as toasts (read their types).

## MainTabsView (TabView, real iOS 26 API)
- `TabView(selection:)` bound to `ui.selectedTab`, `.tabViewStyle(.sidebarAdaptable)`, `.tabBarMinimizeBehavior(.onScrollDown)`.
- Regular width (iPad, like ref/IMG_1160.PNG sidebar): `Tab("Home", systemImage: "house", value: .home)`,
  `Tab(value: .search, role: .search)`, `Tab("Settings", systemImage: "gearshape", value: .settings)`, then
  `TabSection("Library") { ... }` with one Tab each (value `.section(route)`): Artists (music.mic) → .artists,
  Albums (square.stack) → .albums, Songs (music.note) → .songs, Favorite Artists (heart.fill) → .favoriteArtists,
  Favorite Albums (heart.fill) → .albumList(.favorites), Favorite Songs (heart.fill) → .songList(.favorites),
  Downloaded Songs (arrow.down.circle) → .songList(.downloaded), Radio Stations (dot.radiowaves.left.and.right) → .radioStations,
  Genres (guitars) → .genres, Playlists (music.note.list) → .playlists, Recently Played (clock) → .albumList(.recentlyPlayed),
  Recently Added (plus.square.on.square) → .albumList(.recentlyAdded), Frequently Played (flame) → .albumList(.frequentlyPlayed),
  Random (shuffle) → .albumList(.random).
  Each tab content = `NavigationStack { <root view for that route> .withAppRoutes() }`. For a section tab, the root view is
  the same view `withAppRoutes` would show for that Route (write a small `RouteRootView(route:)` switch).
  Sidebar header: the account display name (`app.activeAccount?.name`) in large bold text like "KNIGHT" in the ref
  (use `.tabViewSidebarHeader { }` if available in the SDK; otherwise skip the header — don't fake a sidebar).
- Compact width (iPhone): tabs Home, Library (`LibraryHubView()`, systemImage "square.stack.fill", value .library),
  Settings, and Search (role .search). Same NavigationStack + withAppRoutes per tab.
  Switch between the two tab sets with `@Environment(\.horizontalSizeClass)`; keep `ui.selectedTab` valid when switching.
- Mini player: `.tabViewBottomAccessory { MiniPlayerView() }` only when `player.currentSong != nil` (use the
  `tabViewBottomAccessory(isEnabled:)` overload if the SDK has it, else conditional content).
- Full player: `.fullScreenCover(isPresented: $ui.isPlayerPresented) { FullPlayerView() }` with
  `.navigationTransition(.zoom(sourceID: "nowPlayingArtwork", in: namespace))` and the mini player artwork marked
  `.matchedTransitionSource(id: "nowPlayingArtwork", in: namespace)` (pass the Namespace.ID to MiniPlayerView).

## MiniPlayerView (Apple Music style, ref bottom bar in ref/IMG_1160.PNG)
- Reads `@Environment(\.tabViewBottomAccessoryPlacement)`: `.expanded` → artwork 40pt (6pt radius) + title (15 semibold) + artist
  (13 secondary), then controls: (iPad/regular only: shuffle) previous, play/pause (bigger), next, (regular only: repeat in accent when on).
  `.inline` (collapsed) → artwork + title + play/pause + next only.
- Tap anywhere except buttons → `ui.isPlayerPresented = true`. Swipe up also opens it.
- Buttons are plain SF Symbols (the accessory itself is already glass — don't add glass inside). Haptic on play/pause.
- Show a thin progress line? NO (Apple Music doesn't in the accessory).

## LoginView (first launch; like Arpeggi's add-server form)
- Black background, app name "Knight Music" large, subtitle "Connect to your Navidrome server".
- Form fields (rounded dark fields): Server name (default "Navidrome"), Server address (URL keyboard, no autocorrect,
  placeholder "https://music.example.com"), Username, Password (SecureField). An "Additional addresses" disclosure where the user
  can add more addresses (e.g. LAN + Tailscale), each removable.
- "Connect" `.buttonStyle(.glassProminent)` full width, disabled until valid; shows ProgressView while `app.login(...)` runs;
  error text in red under the button from the thrown error's localizedDescription.
- Normalize addresses with `AddressResolver.normalize(_:)` (read its signature).

## Screenshot routing (DebugLaunch.swift + shell)
`app.debugScreen` (set by DebugLaunch in demo mode). After the session is `.ready` and the first sync finished, RootView applies once:
home → .home; search → .search; artists → .section(.artists) on iPad / .library tab then push Route.artists on iPhone
(keep a NavigationPath per tab so you can push programmatically); albums, songs, playlists → same pattern; album → push
Route.album(first album id from the DB sorted by name); artist → Route.artist(first artist id); player / lyrics / queue →
start playing the first album's songs (`player.play(..)` then `player.pause()`), set `ui.playerPanel` (.artwork/.lyrics/.queue)
and `ui.isPlayerPresented = true`; settings → .settings; server → .settings + push the server status page if SettingsView
exposes one (else just settings); downloads → Route.songList(.downloaded); onboarding → show LoginView regardless of session.
Read DebugLaunch.swift and AppModel (waitForSync, debugScreen) for what exists.

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
