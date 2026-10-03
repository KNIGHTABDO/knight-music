# Full screen player, lyrics, queue

Allowed files: everything in KnightMusic/UI/Player/ (rewrite FullPlayerView.swift, add files there).
Visual target: the Arpeggi player screenshot described in CLAUDE.md "Full player" + Apple Music iOS 26 now playing.

## FullPlayerView
- Presented full screen by the shell (it sets `ui.isPlayerPresented`). Dismiss: chevron.down button and swipe down
  (DragGesture on the whole view with rubber-band offset, dismiss past 120pt or fast velocity).
- Background: if animated artwork exists for the current song (`await artworkService.animatedArtwork(for:)`, check
  AnimatedArtworkService in KnightMusic/Core/Artwork; `@Environment(AnimatedArtworkService.self)`), play it FULL-BLEED behind everything
  (`AnimatedArtworkView`, tall 3:4 file on iPhone portrait, square on iPad/landscape) with a dark gradient at the bottom third for
  legibility — this is the hero feature, make it gorgeous. Otherwise: `ArtworkPalette` gradient (palette(for: coverArt)) animated slowly
  (two gradients crossfading/ MeshGradient using the palette colors, subtle movement), never flat gray. Crossfade on song change.
- Layout (iPhone portrait): when NO animated artwork: big square artwork (width - 48, 12pt radius, shadow; scales down to 85% with a spring
  when paused like Apple Music). With animated artwork full-bleed: no separate square artwork.
  Then: title (22 semibold, marquee if too long — or truncation) + artist (17, secondary);
  row: heart (toggle star via `player.toggleStarCurrent()`), `StarRatingView` (5 stars, `library.setRating`), ••• Menu (SongActionsMenu).
  Scrubber: custom slider (thin 6pt capsule that grows to 12pt while dragging, white fill, haptic at ends) bound to
  `player.beginScrubbing()/scrub(to:)/endScrubbing(at:)`; below it: elapsed "0:00" left, `player.formatDescription` centered
  (11pt secondary, e.g. "Streaming • MP3 • 249 kbps"), remaining "-3:55" right; buffered fraction drawn as a lighter track.
  Transport: shuffle (accent when on) · backward.fill · play/pause (large 44pt symbol, `.contentTransition(.symbolEffect(.replace))`) ·
  forward.fill · repeat (repeat / repeat.1, accent when on). Previous/next with `.symbolEffect(.bounce)` on tap.
  Volume: a row with speaker icons and a system volume slider (MPVolumeView wrapped in UIViewRepresentable, styled minimal) — iPhone only.
  Bottom bar: AirPlay (AVRoutePickerView wrapped; tint white/accent) · Playback settings (gearshape → sheet with quick toggles: gapless,
  replay gain mode, streaming quality — use AppSettings) · chevron.down (dismiss) · lyrics (quote.bubble; accent when panel = lyrics) ·
  queue (list.bullet; accent when panel = queue) · sleep timer (moon.zzz; Menu with presets from `player.sleepTimer` + "End of Song" +
  "Turn Off", shows remaining time when active).
  Put the bottom bar controls in a `GlassEffectContainer` with each control `.glassEffect(.regular.interactive(), in: .circle)`;
  transport buttons plain (no glass) on top of the background.
- iPad / landscape: two columns — left: artwork (or animated artwork in a rounded card when not full-bleed) ; right: info, scrubber,
  transport, and the lyrics/queue panel inline.
- Panels (`ui.playerPanel`): `.artwork` default; `.lyrics` → LyricsView replaces the artwork area (artwork shrinks to a 56pt thumbnail
  row with title/artist at the top, like Apple Music); `.queue` → QueueView likewise. Animate with matchedGeometryEffect on the artwork.

## LyricsView
- `await library.lyrics(songId:)` (check return type: StructuredLyrics array). Prefer synced lyrics.
- Synced: big bold lines (28pt semibold, iPad 34), current line white, others white 35% opacity + slight blur on far lines; auto-scroll
  to keep the current line at ~1/3 height with `.smooth` animation, driven by `player.currentTime` (+ lyrics offset). Tap a line → seek to it.
  User scrolling pauses auto-scroll for 3s.
- Unsynced: plain scrollable text. None: "No lyrics available" centered secondary. Loading: ProgressView.

## QueueView
- Header: "Playing Next" + shuffle/repeat toggles (glass capsule buttons) + "Clear" (clearUpcoming).
- History collapsed section "History" (last 20) above; current song row highlighted; upcoming List with `.onMove`
  (`player.move(fromOffsets:toOffset:)`) and swipe-to-delete (`remove(at:)`), always-on drag handles (EditMode active), tap → skip there.
- Rows: ArtworkView 44pt + title + artist; transparent background over the player background.

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
