import AppIntents
import WidgetKit

/// Runs inside the widget extension, so tapping refresh updates the widget without opening the app.
struct RefreshKickLiveIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Kick Live"

    func perform() async throws -> some IntentResult {
        _ = await KickLiveStore.refresh()
        WidgetCenter.shared.reloadTimelines(ofKind: KickLiveWidget.kind)
        return .result()
    }
}
