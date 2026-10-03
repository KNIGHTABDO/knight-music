# Wire playback, downloads and artwork into AppModel

The modules were built separately and are now merged. Connect them. Allowed files: create
`KnightMusic/App/ServiceWiring.swift`; minimal edits to `KnightMusic/App/AppModel.swift`,
`KnightMusic/App/KnightMusicApp.swift`, and (only if needed for step 5) `KnightMusic/Core/Library/LibraryRepository.swift`.
Do not change any other file. Read these files completely first: App/AppModel.swift, App/KnightMusicApp.swift,
Core/Playback/PlaybackSupport.swift, Core/Playback/PlayerEngine.swift (configure/servicesDidChange/settingsDidChange/
networkDidChange/onStarChanged/songStarChanged), Core/Downloads/DownloadManager.swift (configure, networkDidChange,
backgroundCompletionHandler), Core/Artwork/ArtworkLoader.swift, Core/Artwork/AnimatedArtworkService.swift,
Core/API/SubsonicClient.swift (exact method signatures for scrobble, savePlayQueue, getPlayQueue, star, unstar),
Core/API/APITypes.swift (PlayQueueState), Core/Support/AppSettings.swift, Core/Support/NetworkMonitor.swift,
Core/Library/LibraryDatabase.swift (`pool`), Core/Library/LibraryRepository.swift (setStarred, markPlayed).

## 1. ServiceWiring.swift
- `extension SubsonicClient: PlaybackURLProvider {}` — only if SubsonicClient's existing nonisolated
  `streamURL(songId:maxBitRate:format:timeOffset:)` and `downloadURL(songId:)` already match the protocol exactly
  (Int?, String?, Int?). If not, write a small `struct ClientURLs: PlaybackURLProvider` that forwards.
- `struct SubsonicServerActions: PlaybackServerActions { let client: SubsonicClient }` forwarding to the real client
  methods: scrobble, savePlayQueue, getPlayQueue (map the client's play-queue result type to `ServerPlayQueue`:
  songs, currentSongId, positionMs, changed, changedBy), setStarred (star or unstar with the song id).
- `final class ArtworkBridge: ArtworkProviding` holding the `AnimatedArtworkService`:
  `image(coverArt:size:)` → `await ArtworkLoader.shared.image(coverArt:size:)`;
  `nowPlayingEntries(for:)` → `await service.nowPlayingEntries(for:)`.
- `extension AppModel { func installServiceWiring() }` doing everything below. Keep a `PlaybackServices` instance
  as a stored property on AppModel (add `@ObservationIgnored let playbackServices = PlaybackServices()` to AppModel).

## 2. Providers
- `playbackServices.artwork = ArtworkBridge(service: artwork)` (once).
- `settingsProvider`: build `PlaybackSettings` from AppSettings on every call:
  wifiMaxBitRate, cellularMaxBitRate (same names in AppSettings); transcodeFormat = the format for the current
  network (cellularFormat on cellular, wifiFormat otherwise), but nil when that string is empty or "raw";
  downloadMaxBitRate/downloadFormat likewise ("raw"/empty → nil); gapless = gaplessEnabled;
  replayGain = `ReplayGainMode(rawValue: settings.replayGainMode.rawValue) ?? .off` (two different enums, same raw values);
  scrobblingEnabled; offlineMode = `self.isOffline`; streamCacheLimitMB; serverQueueSyncEnabled = syncPlayQueueWithServer.
  Leave other fields at their defaults.
- `networkProvider`: `.offline` when `!network.isConnected`, `.cellular` when the monitor says expensive/cellular,
  otherwise `.wifi`. Use the real NetworkMonitor property names.

## 3. Session changes
Call `addSessionObserver { app in ... }` (fires immediately and on every login/logout/switch/address change):
- `ArtworkLoader.configure(provider:)` with the client when non-nil (read ArtworkLoader for the exact static API and how
  to clear it on logout, if any).
- `playbackServices.urls = client` (or the forwarding struct), `playbackServices.server = client.map(SubsonicServerActions.init)`.
- When `database` changed (track the last configured `ObjectIdentifier(database)` in an @ObservationIgnored var):
  `downloads.configure(services: playbackServices, database: db.pool)` then
  `player.configure(services: playbackServices, downloads: downloads, database: db.pool)`.
- Always end with `player.servicesDidChange()`.

## 4. Settings + network changes
- Network: in AppModel's existing `networkChanged()` add `player.networkDidChange()` and `downloads.networkDidChange()`.
- Settings: a private func using `withObservationTracking({ _ = settings.<every property used in settingsProvider> },
  onChange: { Task { @MainActor in self.player.settingsDidChange(); self.observeSettings() } })` that re-arms itself.
  Start it from installServiceWiring.

## 5. Star sync + play counts
- `player.onStarChanged = { songId, starred in ... }`: the player already told the server, so ONLY update the local
  DB row (`song.starred = starred ? Date() : nil`) — if LibraryRepository has no local-only method, add a small
  `func applyLocalStar(songId: String, starred: Bool) async` that writes via the database pool.
- When the UI stars a song through LibraryRepository.setStarred for kind song, the player must learn it: add an
  `@ObservationIgnored var onSongStarChanged: ((String, Bool) -> Void)?` to LibraryRepository called after a
  successful song star/unstar, and set it to `player.songStarChanged(songId:starred:)`.

## 6. Background downloads
In KnightMusicApp add a `UIApplicationDelegate` via `@UIApplicationDelegateAdaptor` (or extend the existing one) whose
`application(_:handleEventsForBackgroundURLSession:completionHandler:)` stores the handler in
`DownloadManager.backgroundCompletionHandler` (read its exact declaration).

## 7. Call it
At the end of `AppModel.init()` call `installServiceWiring()`.

Write complete, compiling code. Every name you use must exist — open the file and check.
