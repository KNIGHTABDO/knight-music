# Widgets, Control Center controls and Siri (App Intents) [shots]

Goal: home screen / lock screen widgets, Control Center controls and Siri phrases for Knight Music. Read CLAUDE.md, project.yml,
App/AppModel.swift, App/KnightMusicApp.swift, Core/Playback/PlayerEngine*.swift, Core/Library/LibraryRepository.swift + LibraryQueries.swift,
Core/Artwork/ArtworkLoader.swift before starting.

Allowed: project.yml (add the extension target), new folder `KnightMusicWidgets/` (extension sources + Info.plist + entitlements),
new folder `KnightMusic/Intents/` (App Intents in the app), new file `KnightMusic/Core/Support/WidgetBridge.swift`, new file
`KnightMusic/Resources/KnightMusic.entitlements`, and minimal hook calls in App/AppModel.swift (one line to start WidgetBridge).

## Shared data (App Group)
- App Group id `group.com.knightabdo.knightmusic` in BOTH targets' entitlements (CODE_SIGN_ENTITLEMENTS build setting in project.yml).
  The IPA is unsigned and re-signed by SideStore, which registers app groups for the user — so just declare the entitlement.
- `WidgetBridge` (@MainActor, in the app): observes PlayerEngine (currentSong, isPlaying, currentTime throttled to state changes only)
  and LibraryRepository home lists (recent/newest), and writes a small `WidgetSnapshot` JSON to the app group container:
  now playing (title, artist, album, albumId, isPlaying, duration, elapsed + timestamp), up to 8 recently played albums and 8 recently
  added albums (id, name, artist), and their cover thumbnails as JPEG files (300px, via ArtworkLoader.image) in the container
  `Artwork/` folder. Debounce writes (1s), skip identical snapshots, then `WidgetCenter.shared.reloadAllTimelines()` (or reloadTimelines(ofKind:)).
  If the app group container is nil (not provisioned), log once and do nothing — never crash.
- Put `WidgetSnapshot` (Codable) in a file compiled into BOTH targets (e.g. KnightMusicWidgets/Shared/WidgetSnapshot.swift added to the
  app target's sources too in project.yml). Keep shared code free of app-only types.

## Extension target `KnightMusicWidgets` (app-extension, WidgetKit + SwiftUI, iOS 26, embedded in the app)
- Bundle id `com.knightabdo.knightmusic.widgets`, NSExtensionPointIdentifier `com.apple.widgetkit-extension`. XcodeGen: type
  `app-extension`, dependency `- target: KnightMusicWidgets` on the app with `embed: true`.
- Widgets (StaticConfiguration, timelines from the snapshot):
  1. **Now Playing** (systemSmall, systemMedium, accessoryRectangular): artwork, title, artist, a progress bar (use Text(timerInterval:)
     / ProgressView(timerInterval:) when playing so it animates without reloads), and interactive buttons (previous/play-pause/next)
     using `Button(intent:)` with App Intents. Dark, glassy look matching the app: artwork-tinted background (dominant color is fine
     to precompute in the app snapshot as a hex), rounded artwork, white text, red accent. Use `.containerBackground(for: .widget)`.
     Empty state: app icon glyph + "Nothing playing" + "Tap to open".
  2. **Recently Played** (systemMedium, systemLarge): grid of 4 / 8 album covers with titles; each cover is a `Link` to
     `knightmusic://album/<id>`.
  3. **Lock screen**: accessoryCircular (play/pause glyph or artwork-progress gauge), accessoryInline ("♪ Title — Artist").
- **Control Center** (iOS 18+ ControlWidget): `ControlWidgetButton` "Play/Pause" and "Shuffle Library", backed by the same intents.

## App Intents (in the APP target, `KnightMusic/Intents/`, AND usable by the widget buttons)
- Playback intents: PlayPauseIntent, NextTrackIntent, PreviousTrackIntent, ShuffleLibraryIntent, PlayFavoritesIntent — conform to
  `AudioPlaybackIntent` (so they run in the app process without opening UI) and call into the running app's PlayerEngine. Provide a
  static accessor for the AppModel (e.g. `AppModel.shared` set in KnightMusicApp init — ONE line in AppModel/KnightMusicApp is OK).
  For the widget target, these intent types must also compile there: put the intent DECLARATIONS in a shared file with
  `perform()` routed through a protocol / `#if` so the widget target doesn't need app-only types (common pattern: shared file
  declares the struct; the app target adds `extension PlayPauseIntent { func perform() ... }` — check what compiles cleanly; another
  valid pattern is declaring them only in the app and using `openAppWhenRun = false` with the widget referencing them via a shared file).
- Siri / Shortcuts entity search: `AlbumEntity`, `ArtistEntity`, `PlaylistEntity` (AppEntity with EntityStringQuery searching the
  local DB through LibraryRepository/LibraryDatabase) and `PlayAlbumIntent(album:)`, `PlayArtistIntent(artist:)` (shuffles the artist's
  songs), `PlayPlaylistIntent(playlist:)`.
- `AppShortcutsProvider` with phrases (must contain `\(.applicationName)`): "Play \(\.$album) in \(.applicationName)",
  "Play \(\.$playlist) on \(.applicationName)", "Shuffle my library in \(.applicationName)", "Play my favorites in \(.applicationName)",
  "Pause \(.applicationName)", "Next song in \(.applicationName)". Short titles + SF Symbols.
- Deep links: handle `knightmusic://album/<id>` (add CFBundleURLTypes scheme `knightmusic` in project.yml info) — RootView is not
  yours, so expose `AppModel.pendingDeepLink` is NOT allowed either; instead post a `Notification.Name("KMOpenAlbum")` with the id from
  `.onOpenURL` attached in KnightMusicApp (one modifier) — the integrator wires navigation later. Say so in your summary.

Constraints: no SiriKit entitlement (App Intents + App Shortcuts need none). Everything must compile in CI for both targets.

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
