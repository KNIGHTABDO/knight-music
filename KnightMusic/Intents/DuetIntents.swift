import AppIntents

/// Duet shortcuts. Plain intents (the AppShortcutsProvider is full), so they show up in the Shortcuts app and
/// can be bound to Back Tap or the Action button.
struct OpenStreamoraIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Streamora"
    static var description = IntentDescription("Opens Duet on the Streamora side.")
    static var openAppWhenRun: Bool = true

    @MainActor func perform() async throws -> some IntentResult {
        AppActionRouter.shared.submit("streamora")
        return .result()
    }
}

struct OpenKnightMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Knight Music"
    static var description = IntentDescription("Opens Duet on the Knight Music side.")
    static var openAppWhenRun: Bool = true

    @MainActor func perform() async throws -> some IntentResult {
        AppActionRouter.shared.submit("music")
        return .result()
    }
}

struct SwitchDuetSideIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Duet Side"
    static var description = IntentDescription("Switches between Knight Music and Streamora.")
    static var openAppWhenRun: Bool = true

    @MainActor func perform() async throws -> some IntentResult {
        AppActionRouter.shared.submit("switchapp")
        return .result()
    }
}
