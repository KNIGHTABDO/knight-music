# Error Handling Audit Report (`try?` Audit)

## Category Breakdown

- **Category 1 (Kept as is):** 113 sites
  - Cancellable asynchronous sleeps (`Task.sleep`)
  - Optional cache decodes / file reads where cache miss is normal behavior
  - Best-effort file and directory removal / cleanup of temporary resources
  - Directory creation immediately followed by operations that fail with explicit errors
  - Static regular expression compilations with known-safe patterns
  - Debug-only paths (`#if DEBUG` launch automation)
- **Category 2 (Log only):** 31 sites
  - Background database operations, background cache writes, widget snapshot data preparation, fallback keychain reads/removals, audio session category restoration.
- **Category 3 (Surface to user):** 21 sites
  - User-initiated operations: star/unstar toggle, star ratings, playlist creations/renames/deletions/reordering/modifications, shuffle all, cache clearing, download deletions.
- **Total Audited Sites:** 165

---

## Changed Sites Summary

### Category 2: Log Only

- `KnightMusic/Core/Library/LibraryDatabase.swift:45` → Logs database pool closure error to `Log.database.error`.
- `KnightMusic/Core/Library/LibraryDatabase.swift:55` → Logs sync state database read error to `Log.database.error`.
- `KnightMusic/Core/Library/LibraryRepository.swift:214` → Logs batch songs database read failure to `Log.database.error`.
- `KnightMusic/Core/Library/LibraryRepository.swift:228` → Logs album content database read failure to `Log.database.error`.
- `KnightMusic/Core/Library/LibraryRepository.swift:241` → Logs cached lyrics database read failure to `Log.database.warning`.
- `KnightMusic/Core/Library/LibraryRepository.swift:263` → Logs lyrics database cache write failure to `Log.database.warning`.
- `KnightMusic/Core/Library/LibraryRepository.swift:284` → Logs cached artist info database read failure to `Log.database.warning`.
- `KnightMusic/Core/Library/LibraryRepository.swift:301` → Logs artist info database cache write failure to `Log.database.warning`.
- `KnightMusic/Core/Library/LibraryRepository.swift:345` → Logs local play count and played timestamp database write failure to `Log.database.warning`.
- `KnightMusic/Core/Library/LibraryRepository.swift:401` → Logs rollback database write failure for star status to `Log.database.error`.
- `KnightMusic/Core/Library/LibraryRepository.swift:418` → Logs local star status database write failure to `Log.database.error`.
- `KnightMusic/Core/Library/LibraryRepository.swift:439` → Logs rollback database write failure for rating to `Log.database.error`.
- `KnightMusic/Core/Library/LibraryRepository.swift:536` → Logs rollback database write failure for remove-from-playlist to `Log.database.error`.
- `KnightMusic/Core/Library/LibraryRepository.swift:560` → Logs rollback database write failure for move-playlist-entries to `Log.database.error`.
- `KnightMusic/Core/Support/WidgetBridge.swift:123` → Logs now-playing artwork atomic disk write failure to `Log.app.warning`.
- `KnightMusic/Core/Support/WidgetBridge.swift:168` → Logs recent album artwork atomic disk write failure to `Log.app.warning`.
- `KnightMusic/Core/Support/WidgetBridge.swift:192` → Logs newest album artwork atomic disk write failure to `Log.app.warning`.
- `KnightMusic/Core/Support/WidgetBridge.swift:247` → Logs recent albums database read failure to `Log.app.warning`.
- `KnightMusic/Core/Support/WidgetBridge.swift:262` → Logs newest albums database read failure to `Log.app.warning`.
- `KnightMusic/Core/AutoMix/AutoMixClient.swift:160` → Logs AutoMix plan disk cache write failure to `Log.playback.warning`.
- `KnightMusic/Core/Playback/PlaybackSupport.swift:173` → Logs failure when excluding URL from backup to `Log.playback.warning`.
- `KnightMusic/Core/API/Keychain.swift:76` → Logs credential fallback file read/decode failure to `Log.app.error`.
- `KnightMusic/Core/API/Keychain.swift:105` → Logs credential fallback file removal failure to `Log.app.error`.
- `KnightMusic/Core/Artwork/ArtworkLoader.swift:36` → Logs artwork disk cache (`DataCache`) initialization failure to `Log.artwork.error`.
- `KnightMusic/Core/Hermes/KnightConversationStore.swift:146` → Logs conversation atomic disk write failure to `Log.app.error`.
- `KnightMusic/Core/Hermes/SpeechDictationManager.swift:139` → Logs audio session playback category restoration failure to `Log.playback.error`.
- `KnightMusic/Core/Hermes/ArrivalWatcher.swift:160` → Logs pending arrival watches encoding failure to `Log.hermes.error`.
- `KnightMusic/Core/Hermes/ArrivalWatcher.swift:371` → Logs arrival track database search failure to `Log.database.error`.
- `KnightMusic/Core/Hermes/HermesService.swift:161` → Logs cancel run request failure to `Log.app.warning`.
- `KnightMusic/Core/Hermes/HermesSettings.swift:28` → Logs Hermes API key keychain save failure to `Log.app.error`.
- `KnightMusic/UI/Search/SearchView.swift:75` → Logs search database query failure to `Log.database.error`.

### Category 3: Surface to User

- `KnightMusic/UI/Home/HomeView.swift:268` → Catches and logs shuffle-all database read failure to `Log.database.error` and displays toast notification: "Couldn’t load songs to shuffle."
- `KnightMusic/UI/Settings/StorageView.swift:202` → Logs artwork cache size calculation error to `Log.artwork.warning`.
- `KnightMusic/UI/Settings/StorageView.swift:243` → Catches artwork cache clearing failure, logs to `Log.artwork.error`, and displays toast notification: "Couldn’t clear artwork cache."
- `KnightMusic/UI/Settings/StorageView.swift:259` → Catches album songs database query failure when deleting album, logs to `Log.downloads.error`, and displays toast notification: "Couldn’t delete downloaded album."
- `KnightMusic/UI/Library/PlaylistsView.swift:110` → Catches playlist creation error, logs to `Log.sync.error`, and surfaces via `library.report` error banner/toast.
- `KnightMusic/UI/Library/PlaylistsView.swift:131` → Catches playlist deletion error, logs to `Log.sync.error`, and surfaces via `library.report` error banner/toast.
- `KnightMusic/UI/Library/LibraryComponents.swift:76` → Catches artist play-all database read error and logs to `Log.database.error`.
- `KnightMusic/UI/Library/LibraryComponents.swift:153` → Catches album star toggle error, logs to `Log.sync.error`, and surfaces via `library.report` error banner/toast.
- `KnightMusic/UI/Library/LibraryComponents.swift:188` → Catches artist star toggle error, logs to `Log.sync.error`, and surfaces via `library.report` error banner/toast.
- `KnightMusic/UI/Detail/AlbumDetailView.swift:295` → Catches album star toggle error, logs to `Log.sync.error`, and surfaces via `library.report` error banner/toast.
- `KnightMusic/UI/Detail/AlbumDetailView.swift:382` → Catches add-album-to-playlist error, logs to `Log.sync.error`, surfaces via `library.report`; displays success toast only on successful addition.
- `KnightMusic/UI/Detail/ArtistDetailView.swift:316` → Catches artist star toggle error, logs to `Log.sync.error`, and surfaces via `library.report` error banner/toast.
- `KnightMusic/UI/Detail/PlaylistDetailView.swift:79` → Catches playlist reorder error, logs to `Log.sync.error`, and surfaces via `library.report` error banner/toast.
- `KnightMusic/UI/Detail/PlaylistDetailView.swift:88` → Catches swipe remove-song error, logs to `Log.sync.error`, and surfaces via `library.report` error banner/toast.
- `KnightMusic/UI/Detail/PlaylistDetailView.swift:112` → Catches playlist rename error, logs to `Log.sync.error`, surfaces via `library.report`; displays success toast only on success.
- `KnightMusic/UI/Detail/PlaylistDetailView.swift:129` → Catches playlist delete error, logs to `Log.sync.error`, surfaces via `library.report`; displays dismiss toast only on success.
- `KnightMusic/UI/Detail/PlaylistDetailView.swift:253` → Catches context menu remove-song error, logs to `Log.sync.error`, surfaces via `library.report`.
- `KnightMusic/UI/Detail/PlaylistDetailView.swift:270` → Catches trailing swipe remove-song error, logs to `Log.sync.error`, surfaces via `library.report`.
- `KnightMusic/UI/Detail/SongActionsMenu.swift:44` → Catches add-song-to-playlist error, logs to `Log.sync.error`, surfaces via `library.report`; displays success toast only on success.
- `KnightMusic/UI/Detail/SongActionsMenu.swift:81` → Catches song star toggle error, logs to `Log.sync.error`, surfaces via `library.report`.
- `KnightMusic/UI/Detail/SongActionsMenu.swift:95` → Catches song rating update error, logs to `Log.sync.error`, surfaces via `library.report`.
- `KnightMusic/UI/Detail/SongActionsMenu.swift:113` → Catches song rating clear error, logs to `Log.sync.error`, surfaces via `library.report`.
- `KnightMusic/UI/Player/FullPlayerView.swift:100` → Catches player rating change error, logs to `Log.sync.error`, surfaces via `library.report`.
