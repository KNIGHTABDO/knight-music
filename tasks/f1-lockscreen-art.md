# Lock screen animated artwork fix + diagnostics

Allowed files: KnightMusic/Core/Artwork/* and KnightMusic/Core/Playback/NowPlayingCenter.swift only.

Context: on a real iPad (iPadOS 26) the in-app animated artwork works, and the lock screen shows the static cover full-screen,
but the lock screen / Notification Center never animate. The app supplies MPMediaItemAnimatedArtwork (see
Core/Artwork/NowPlayingAnimatedArtwork.swift and AnimatedArtworkService.nowPlayingEntries; NowPlayingCenter merges the entries).
Read those files and HLSArtwork.swift / AnimatedArtworkStore.swift / AnimatedImageConverter.swift completely first.

1. Lock-screen-compatible video files. The cached m8tec files are FRAGMENTED MP4 (an HLS byte-range file: init segment + moof/mdat
   fragments). The system now-playing UI very likely needs a regular (non-fragmented, moov-first, faststart) MP4/MOV. After a
   download (and for already-cached files, lazily on first lock-screen request), produce a sibling file `<albumId>-square.lock.mp4` /
   `<albumId>-tall.lock.mp4` by re-muxing WITHOUT re-encoding: AVAssetExportSession with preset AVAssetExportPresetPassthrough,
   outputFileType .mp4, shouldOptimizeForNetworkUse = true, video track only (no audio). If passthrough export fails, fall back to
   AVAssetExportPresetHighestQuality (H.264). Also make sure the WebP→MP4 converter output is already a normal MP4 with
   shouldOptimizeForNetworkUse (it is written by AVAssetWriter — set `writer.shouldOptimizeForNetworkUse = true`).
   The lock-screen handlers must return the `.lock.mp4` URL; the in-app AnimatedArtworkView can keep using the original file.
   Keep total cache bookkeeping (index.json) consistent; delete .lock files when their source is deleted.
2. Handlers: re-check NowPlayingAnimatedArtwork against the iOS 26 SDK: artworkID must be stable per album+variant; the
   preview-image handler must return a UIImage close to the requested CGSize (render the first video frame with AVAssetImageGenerator
   at that size, appliesPreferredTrackTransform = true; fall back to the static cover scaled); the video handler must return the
   local file URL. Handlers may be called on any thread — make them thread-safe and never block the main thread.
3. Refresh: if the animated file becomes ready AFTER the song's now-playing info was first published (download still running),
   NowPlayingCenter must republish nowPlayingInfo with the animated keys once ready (only if the same song is still current).
4. Diagnostics: log through `Log` (KnightMusic/Core/Support/Log.swift — check its API and pick the artwork category or add a case
   ONLY if Log has an extensible category enum in your allowed files; otherwise use an existing category) every step:
   "lockscreen art: lookup album=<id> found square=<bool> tall=<bool>", "remux ok/failed <error>", "published keys: <list of keys>",
   "preview handler called size=<w>x<h>", "video handler called size=<w>x<h> -> <file name>". These lines show up in
   Settings → Diagnostics so the user can tell whether the system ever asks for the video.
