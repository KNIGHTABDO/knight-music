CarPlay app: template UI (Listen Now, Library, Playlists, Downloads) with Now Playing, Up Next and live playing indicators

Build Knight Music's full CarPlay audio UI with Apple's CarPlay framework (iOS 26 SDK). It must look and behave like Apple Music in
CarPlay: fast (reads only the local GRDB mirror), works offline, never blocks on the network, honours CarPlay limits. The scene
only connects on builds carrying the carplay-audio entitlement (simulator now; a paid account later), but the code must be complete
production code. Read first: KnightMusic/CarPlay/CarPlaySceneDelegate.swift (stub to replace), KnightMusic/App/KnightMusicApp.swift
(scene routing), KnightMusic/App/AppModel.swift (shared, session, startIfNeeded, library, player, sessionRevision, isOffline),
KnightMusic/Core/Library/LibraryRepository.swift + LiveQuery.swift + LibraryQueries.swift (all list APIs), KnightMusic/Core/API/Models.swift
(Song, Album, Artist, Playlist, Genre, RadioStation, AlbumContent fields), KnightMusic/Core/Playback/PlayerEngine.swift +
PlayerEngine+Queue.swift (play, playRadio, skip(to:), enqueue, setShuffle, setRepeat, toggleStarCurrent, currentSong, isPlaying,
currentIndex, order, queue, currentRadio, isPlayable), KnightMusic/Core/Artwork/ArtworkLoader.swift (`image(coverArt:size:) async`),
KnightMusic/Core/Support/AppSettings.swift, and how the phone UI implements "Shuffle library" / home shelves (UI/Home) so you reuse
the same calls (do not reinvent queries).

## Files you own
New files under KnightMusic/CarPlay/ only (replace the stub delegate's bodies; keep its class name and the two method signatures).
One primary type per file, e.g. CarPlaySceneDelegate, CarPlayCoordinator, CarPlayListenNowTab, CarPlayLibraryTab, CarPlayPlaylistsTab,
CarPlayDownloadsTab, CarPlayDetailTemplates (album/artist/genre/playlist/radio), CarPlayNowPlaying, CarPlayItemFactory, CarPlayArtwork.
Prefix every new type with `CarPlay` (other agents are editing Core/Playback and Intents now; never edit those).

## CarPlay API you may use (exact names; do not use anything else from CarPlay.framework)
- `CPTemplateApplicationSceneDelegate`: `templateApplicationScene(_:didConnect:)`, `templateApplicationScene(_:didDisconnectInterfaceController:)`.
- `CPInterfaceController`: `setRootTemplate(_:animated:completion:)`, `pushTemplate(_:animated:completion:)`, `popTemplate(animated:completion:)`,
  `popToRootTemplate(animated:completion:)`, `presentTemplate(_:animated:completion:)`, `dismissTemplate(animated:completion:)`,
  `templates`, `topTemplate`, `carTraitCollection`, `delegate` (`CPInterfaceControllerDelegate`: `templateWillAppear/DidAppear/WillDisappear/DidDisappear(_:animated:)`).
- `CPTabBarTemplate(templates:)`, `updateTemplates(_:)`, `CPTabBarTemplate.maximumTabCount`. On each tab's template set `tabTitle` and `tabImage`.
- `CPListTemplate(title:sections:)`, `updateSections(_:)`, `sections`, `emptyViewTitleVariants`, `emptyViewSubtitleVariants`,
  `CPListTemplate.maximumItemCount`, `CPListTemplate.maximumSectionCount` (read them at build time; they shrink when the car limits UI).
- `CPListSection(items:header:sectionIndexTitle:)`, `CPListSection(items:)`.
- `CPListItem(text:detailText:image:accessoryImage:accessoryType:)`, `.handler = { item, completion in ...; completion() }`
  (ALWAYS call completion, on every path; CarPlay shows a spinner until you do — do async loading before calling it),
  `setImage(_:)`, `setText(_:)`, `setDetailText(_:)`, `isPlaying`, `playingIndicatorLocation = .trailing`, `accessoryType = .disclosureIndicator`,
  `isExplicitContent`, `userInfo`, `CPListItem.maximumImageSize`.
- `CPListImageRowItem(text:images:)`, `.handler` (title tap), `.listImageRowHandler = { item, index, completion in }`, `update(_ images: [UIImage])`,
  `CPListImageRowItem.maximumImageSize`.
- `CPNowPlayingTemplate.shared`: `updateNowPlayingButtons(_:)`, `isUpNextButtonEnabled`, `upNextTitle`, `isAlbumArtistButtonEnabled`,
  `add(_:)` / `remove(_:)` a `CPNowPlayingTemplateObserver` (`nowPlayingTemplateUpNextButtonTapped(_:)`, `nowPlayingTemplateAlbumArtistButtonTapped(_:)`).
  Buttons: `CPNowPlayingShuffleButton(handler:)`, `CPNowPlayingRepeatButton(handler:)`, `CPNowPlayingImageButton(image:handler:)`; `isSelected`, `isEnabled`.
  The shuffle/repeat button icons reflect `MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType` / `changeRepeatModeCommand.currentRepeatType`
  (RemoteCommands.refresh() keeps those in sync — you only call engine.setShuffle / setRepeat).
- `CPAlertTemplate(titleVariants:actions:)`, `CPAlertAction(title:style:handler:)`.
- Images: render with `UIGraphicsImageRenderer` using `UIGraphicsImageRendererFormat` whose `scale = interfaceController.carTraitCollection.displayScale`.

## Rules / limits
- Template depth: root counts as 1, Apple caps at 5 and the system may push Now Playing on top → never push beyond depth 4 of your own;
  at depth 4, rows that would push become play actions instead.
- Never more than `CPListTemplate.maximumItemCount` items per template (sum over sections) or `maximumSectionCount` sections.
  Long lists (artists, albums, songs): if count ≤ max, show A–Z sections with `sectionIndexTitle` (first letter, "#" for others, sorted by
  the same name sort the app uses); if count > max, show a letter list first (one row per letter with count in detailText), each pushing that letter's items.
- Text only, no custom views. Short strings. Detail text: album → artist · year; song → artist; playlist → "N songs".
- Never call `updateSections` unless the visible item ids/text actually changed (it resets the driver's scroll/rotary focus).
- All work `@MainActor`. Coordinator is `@MainActor final class CarPlayCoordinator`; delegate methods hop with `MainActor.assumeIsolated`.
- Errors go to Log / PlaybackLog (see Core/Support/Log.swift) and, when an action fails, a `CPAlertTemplate` with one "OK" action.

## Behaviour
1. Connect: `AppModel.shared?.startIfNeeded()`; build the coordinator; set root immediately (no awaiting): if `session` is not `.ready`
   and there is no account, root = a `CPListTemplate` titled "Knight Music" with no sections and empty-view title
   "Sign in on your iPhone" / subtitle "Open Knight Music on your iPhone to connect to your server.". Observe the AppModel
   (`withObservationTracking`, re-armed after each change, on `session` and `sessionRevision`) and swap to the tab bar when ready,
   and rebuild tabs on account switch. Disconnect: tear everything down (cancel tasks, remove Now Playing observer, drop LiveQuerys).
2. Tabs (4, in order):
   a. "Listen Now" (SF Symbol `play.circle.fill`): first section has one `CPListImageRowItem` "Recently Played" with up to 8 album covers from
      `homeList(.recent)` (tap an image → album detail; tap title → full Recently Played album list). Section "Mixes": "Shuffle All"
      (same call the phone UI uses for shuffle library), "Favorites" (favoriteSongs, shuffled), "Downloaded" (downloadedSongs, shuffled) —
      these play immediately and push Now Playing. Section "Recently Added" (homeList(.newest), up to 10 albums) and "Most Played"
      (homeList(.frequent), up to 10) with a final "See All" row pushing the full list.
   b. "Library" (`square.stack.fill`): rows Artists, Albums, Songs (favorites), Genres, Radio (only if any stations) — each pushes its list.
   c. "Playlists" (`music.note.list`): all playlists (name, "N songs", cover) → playlist detail.
   d. "Downloads" (`arrow.down.circle.fill`): "Shuffle" row then downloaded songs (A–Z rules above). Empty view: "No downloads" /
      "Download music on your iPhone to play it anywhere.".
3. Details: Album = rows "Play", "Shuffle", then songs (track number + title, detail = artist when it differs from album artist),
   disc headers as sections when multi-disc. Artist = "Shuffle" (all artist songs) + "Top Songs" (pushes topSongs) + albums (newest first).
   Playlist = "Play", "Shuffle", songs. Genre = albums. Radio = stations → `playRadio`, then push Now Playing.
   Tapping a song plays the containing list starting at that song (`play(songs, startAt:)`). After any play action push
   `CPNowPlayingTemplate.shared` unless it is already the top template.
4. Offline (`AppModel.isOffline` or server unreachable): song lists show only songs the engine can play now (downloaded or cached —
   use PlayerEngine.isPlayable / existing local-availability helpers), album/playlist rows with no playable songs are hidden, and the
   empty view says "Not available offline". Lists refresh when connectivity changes.
5. Live updates: keep each visible template's LiveQuery alive; observe its `value` and rebuild items only on real changes (compare ids+text).
   Playing indicators: every song row whose song id == `player.currentSong?.id` has `isPlaying = true` (updated within 100 ms of song changes
   via observation of the player; keep a weak map songId → [CPListItem], no updateSections needed for this).
6. Artwork: `CarPlayArtwork` loads covers via `ArtworkLoader.shared.image(coverArt:size:)` (size in pixels = maximumImageSize × displayScale,
   rounded up), scales to exactly the max size with the car's display scale, caches by "coverArt|size" in an NSCache, and calls
   `item.setImage` when done; items get a SF Symbol placeholder (`music.note` / `person.crop.circle` / `music.note.list`) tinted secondary
   until then. Load lazily only for items of templates currently on the stack; cancel loads when a template is popped.
7. Now Playing: buttons = [shuffle, repeat, favorite]. Favorite = `CPNowPlayingImageButton` with SF Symbol `heart` / `heart.fill`
   reflecting `currentSong?.starred != nil`, tap → `toggleStarCurrent()`; rebuild the buttons when the star state changes.
   Radio: buttons empty, Up Next and album/artist disabled. `isUpNextButtonEnabled` when there are upcoming songs; `upNextTitle = "Up Next"`.
   Up Next tap → push a list of upcoming queue entries (current shown first with isPlaying), tap → `skip(to:)` the index of that entry
   in `order`. Album/artist tap → push the current song's album detail (respect the depth rule).
