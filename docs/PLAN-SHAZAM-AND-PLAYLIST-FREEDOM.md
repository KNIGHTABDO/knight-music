# Architecture & Implementation Plan: Universal Playlist Freedom & Shazam Music Recognition with iOS Control Center

**Project:** Knight Music (iOS / iPadOS)  
**Target Release:** v0.8.0  
**Design Contract:** Strict pixel perfection, zero UI regressions, Apple HIG alignment, seamless user control.

---

## Part 1: Playlist Modification Fix & Universal Freedom

### 1. Root Cause Analysis (Subsonic Server Error 50)
- **Error Observed:** `Could not add to playlist. Server error 50: User is not authorized for the given operation` (Screenshot `IMG_0055.jpg`).
- **Subsonic / Navidrome Security Model:**
  - Every playlist in Navidrome has an `owner`.
  - Only the owner has permission to modify a playlist via `/rest/updatePlaylist.view` (`songIdToAdd`, `songIndexToRemove`).
  - **Public / Shared Playlists:** Other users can stream songs from them, but cannot modify them.
  - **Smart Playlists (`.nsp`) & Synced Files (`.m3u`):** Treated by Navidrome as strictly read-only through the API.
- **Flaw in Current Implementation:**
  `PlaylistPickerSheet` calls `library.playlists()`, which fetches all playlists indiscriminately. When a user taps a playlist owned by another user or a smart playlist, it blindly fires `updatePlaylist`, causing Navidrome to reject the call with Error 50.

### 2. The Solution: "User Can Do Anything He Wants"
Rather than restricting the user, Knight Music empowers the user with seamless forking and instant duplication:

1. **Intelligent UI Categorization in `PlaylistPickerSheet` & `PlaylistsView`:**
   - Detect ownership: Compare `playlist.owner` with the active user account (`settings.username`).
   - Group into two distinct sections:
     - **My Playlists** (Editable by user).
     - **Shared & Smart Playlists** (Read-only, marked with a subtle `person.2.fill` or `sparkles` badge).
2. **Instant "Duplicate & Add" (Forking) Flow:**
   - When the user taps a playlist in the **Shared & Smart Playlists** section:
     Instead of failing with Error 50, present a sleek, native confirmation dialog:
     > **Shared Playlist**  
     > *"[Playlist Name]" is managed by the server or shared by another user. Create your own editable copy with this song added?*  
     > **[Create Copy & Add]** / **[Cancel]**
   - Tapping **"Create Copy & Add"**:
     1. Fetches the existing playlist's tracks.
     2. Appends the requested song(s).
     3. Calls `createPlaylist` on Navidrome under the user's name as `"[Playlist Name] (My Copy)"`.
     4. Displays a success toast and haptic feedback: `Created "[Playlist Name] (My Copy)"`.
3. **Automatic Error 50 Interceptor (Safety Net):**
   - In `LibraryRepository.addToPlaylist`, catch Subsonic Error 50 specifically.
   - If caught, instead of presenting an ugly red error banner, post an event to prompt the user: *"Would you like to duplicate this playlist to your library?"*
4. **Context Menu "Duplicate to My Playlists":**
   - Added to `PlaylistRow` in `PlaylistsView` so any shared playlist can be cloned with a single tap.

---

## Part 2: Shazam Music Recognition & iOS Control Center Integration

### 1. ShazamKit Engine (`KnightMusic/Core/Recognition/`)
- **Apple First-Party Framework:** `import ShazamKit`.
  - Zero external API keys, zero paid tiers, runs on-device and queries Apple's global Shazam catalog.
- **Audio Capture Service (`ShazamService.swift`):**
  - Manages `AVAudioEngine` and `SHSession`.
  - Taps the microphone input node (`AVAudioPCMBuffer`) and feeds audio chunks to `session.matchStreamingBuffer(buffer, at: time)`.
  - Conforms to `SHSessionDelegate`:
    - `session(_:didFind:)`: Extracts `SHMatchedMediaItem` (`title`, `artist`, `artworkURL`, `appleMusicID`, `isrc`).
    - `session(_:didNotFindMatchFor:error:)`: Handles silence, timeout, or network unavailability.

### 2. iOS Control Center Control Widget (`KnightMusicWidgets`)
- **iOS 18+ Controls API:**
  - Placed in iOS Control Center, Lock Screen bottom corners, and Action Button.
  - Implemented as a `ControlWidget`:
    ```swift
    @available(iOS 18.0, *)
    struct KnightRecognizeControl: ControlWidget {
        static let kind = "com.knightabdo.knightmusic.recognizeControl"

        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(kind: Self.kind) {
                ControlWidgetButton(action: RecognizeMusicIntent()) {
                    Label("Recognize Music", systemImage: "shazam.logo.fill")
                }
            }
            .displayName("Recognize Music")
            .description("Identify songs playing around you with Knight Music.")
        }
    }
    ```
- **Execution & Privacy Architecture:**
  - Because iOS sandbox security restricts background microphone recording from widget extensions without foreground authorization:
    - `RecognizeMusicIntent` is configured with `static var openAppWhenRun: Bool = true`.
    - When tapped from Control Center, it instantly activates Knight Music with an animated, non-intrusive frosted glass HUD:
      *"Knight Music is Listening…"* with an animated audio waveform ring.
    - Recognition typically matches in **2 to 4 seconds**.
    - Once recognized:
      - Shows the song artwork, title, and artist.
      - Automatically checks if the song exists in the local Navidrome library (`library.search(title)`).
      - If in library: Shows **[Play Now]** badge: `"In Your Library"`.
      - If not in library: Offers instant streaming via YouTube Music integration, or one-tap **[Save to Identified Songs]**.
- **Live Activity / Dynamic Island Integration (`ActivityKit`):**
  - If music recognition is triggered while Knight Music is already in the background playing music, it uses `ActivityKit` to display the listening wave in the Dynamic Island without interrupting playback.

### 3. In-App Recognition UI
1. **Search Tab Recognition Button:**
   - In `SearchView`, placed in the navigation bar or search field: a discreet, glowing Shazam icon (`shazam.logo.fill`).
   - Tapping opens the interactive `MusicRecognitionView` overlay.
2. **"Identified Songs" Section in Library:**
   - A dedicated history shelf/list under Library: tracks every song identified, with timestamp, artwork, artist, and quick actions:
     - **Play**
     - **Add to Playlist**
     - **Share Link**

---

## Part 3: Technical Implementation Checklist

### Core Models & Database
- [ ] Add `isOwned(by:)` to `Playlist` model.
- [ ] Add `recognized_song` table in GRDB schema for offline history.

### Repository & Network
- [ ] Add `duplicatePlaylist(id:newName:additionalSongs:)` in `LibraryRepository`.
- [ ] Enhance `addToPlaylist` with Error 50 interceptor and fallback.
- [ ] Create `ShazamService.swift` wrapping `AVAudioEngine` and `SHSession`.
- [ ] Create `ShazamMatchResolver.swift` to search Navidrome & YouTube for recognized tracks.

### UI & Widgets
- [ ] Update `PlaylistPickerSheet.swift` with grouped sections and duplicate-and-add sheet.
- [ ] Add `KnightRecognizeControl` in `KnightMusicWidgets`.
- [ ] Add `MusicRecognitionSheet.swift` with animated frosted glass equalizer rings.
- [ ] Add `IdentifiedSongsView.swift` to Library.
- [ ] Add microphone entitlement `NSMicrophoneUsageDescription` in `KnightMusic/Resources/Info.plist`.

---

## Part 4: Verification & Release Plan
- Verify compilation with `swiftc` on Linux.
- Push to branch `feat/v0.8-features` -> `main`.
- CI Build verification on macOS runners for simulator compilation and release IPA packaging.
- Ensure strict pixel perfection: test across iPhone 16 Pro, standard iPhone, and iPad.
