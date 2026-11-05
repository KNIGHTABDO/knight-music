import AppIntents

struct AddCurrentSongToNavidromeIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Current Song to Navidrome"
    static var description = IntentDescription("Adds the currently playing YouTube song to your Navidrome library.")
    static var openAppWhenRun: Bool = true

    @MainActor func perform() async throws -> some IntentResult {
        let (app, _) = try await prepareAppForPlayback()
        guard let song = app.player.currentSong, song.isYouTube else {
            throw IntentError.message("Play a YouTube song first.")
        }
        AppActionRouter.shared.submit("import")
        return .result()
    }
}
