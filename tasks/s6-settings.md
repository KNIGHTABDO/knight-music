# Settings screens

Allowed files: everything in KnightMusic/UI/Settings/ (rewrite SettingsView.swift, keep AboutView.swift, add files there).
Visual target: ref/IMG_1166.PNG … IMG_1172.PNG (inset grouped dark cards, red action rows, green "Online").

## SettingsView (ref/IMG_1167 + IMG_1168)
List `.insetGrouped`, title "Settings":
1. Account card: red circle with person.fill (60pt), account name bold, "Manage servers, addresses, sync..." secondary → ServersView.
2. "Status" row: "Online" green / "Offline" red / "Checking…" (from app.isOffline / serverReachable / syncStatus) → ServerStatusView;
   footer text "navidrome <version>" (from ping/scan status — check what AppModel/client exposes; fetch serverVersion via ping if needed).
3. Offline Mode: row "Offline Mode" with a Menu picker Automatic/Manual (accent text + chevron.up.chevron.down like the ref); when Manual,
   a Toggle "Enabled" (`settings.manualOfflineEnabled`). Footer explains.
4. Playback → PlaybackSettingsView; Storage → StorageView; Customize → CustomizeView.
5. "Log Out" red row (confirmation dialog → app.logout()).
6. "App Version 0.1.0 (1)" → AboutView. 7. Diagnostics → DiagnosticsView. 8. GitHub link row (accent) → https://github.com/KNIGHTABDO/knight-music.

## ServersView ("Manage Servers", ref/IMG_1169)
- Section "Servers": each account (name, created date) with red checkmark on the active one; tap → switchAccount; swipe delete (removeAccount).
  Toolbar "+" (glass circle, accent) → sheet reusing `LoginView()` content (login adds a new account).
- Section "Current Server": Display Name, Username, "Manage Addresses  N ›" → AddressesView, plus the current resolved address (secondary).
- Section "Sync Status": Status (Synced green / Syncing… with progress / Error red), Last Sync date, "Re-sync with Server" (arrow.clockwise in red circle)
  → `app.refresh(force: true)`; footer "If you notice data inconsistencies with your server please try to Re-Sync to refresh the local app database."
- Section "Library": counts (Artists, Albums, Songs, Playlists) from `library.counts()`.

## AddressesView
Ordered list of the account's addresses with the active one marked (green dot), add (alert with URL field, normalized), delete, reorder (EditButton);
footer "Knight Music tries addresses in this order and uses the first reachable one (e.g. home LAN first, then Tailscale)." Persist via
AccountStore/AppModel (check what API exists to update an account's addresses; if none, add a minimal `updateAddresses` on AppModel is NOT
allowed — instead ask for nothing: if no API exists, make this view read-only with a note "Edit addresses by re-adding the server" — but first look carefully).

## ServerStatusView (ref/IMG_1166, IMG_1171, IMG_1172)
- Title "Server Status". Sections: "Server Status": Status Online/Offline, Type (from ping `type`, e.g. "Navidrome"), Version.
  "Server Scan Status": Remote Folder Count, Remote Song Count, Last Scan (relative "1 Minute ago"), "Force Quick Scan" red action
  (`library.startScan(full: false)`, then poll getScanStatus every 2s showing "Scanning… N" until done, then trigger app.refresh()).
  Also "Full Scan" action in a confirmation. "Extensions": list from getOpenSubsonicExtensions: name left, versions "[1, 2]" right.
- Data via `app.client` (async calls; check SubsonicClient method names), with loading + error states, pull to refresh.

## PlaybackSettingsView
- "Streaming Quality": Wi-Fi (Picker: Original, 320, 256, 192, 128 kbps) and Cellular (same) → wifiMaxBitRate / cellularMaxBitRate (0 = Original);
  Format picker (Original/raw, MP3, Opus, AAC) per network (wifiFormat/cellularFormat).
- "Downloads": quality picker (downloadMaxBitRate/downloadFormat).
- Toggles: Gapless Playback, Scrobble to Server, Sync Play Queue with Server, Show Ratings.
- ReplayGain picker (Off/Track/Album). "Artwork": Animated Artwork toggle, Lock Screen Animated Artwork toggle.

## StorageView
- Downloads size, Stream cache size (StorageManager — read its API; create it with `StorageManager(downloads: downloads, cache: player.streamCache)`),
  Animated artwork cache size (compute folder size of Caches/AnimatedArtwork), image cache (Nuke DataCache size if exposed, else skip).
- Stream cache limit Picker (512 MB, 1 GB, 2 GB, 5 GB, 10 GB → settings.streamCacheLimitMB).
- Red actions with confirmations: Clear Stream Cache, Clear Artwork Cache, Delete All Downloads.
- "Downloads by Album" list from StorageManager.albumBreakdown() with sizes, swipe to delete an album's downloads.

## CustomizeView
- Accent color: grid of swatches (Red #FA2D48 default, Pink, Purple, Blue, Teal, Green, Orange, Yellow, Gold) → settings.accentColorHex;
  live preview. (If the app's accent isn't driven by settings yet, still store it — the integrator will apply it.)

## DiagnosticsView
- Recent log lines from `Log` ring buffer (monospaced 11pt, newest last, auto-scroll), Share button exporting `Log.exportText()`
  via ShareLink, "Copy" button. Device/app info section (iOS version, app version, active address, offline state).

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
