import XCTest

/// UI audit (CI only, .github/workflows/ui-audit.yml). Drives the app in demo mode (-KMDemo YES) on a simulator,
/// screenshots every screen in the requested orientation, rotates live screens, crawls Settings/Library rows
/// and dumps the accessibility tree so layout and VoiceOver problems can be reviewed offline.
/// Environment (passed as TEST_RUNNER_<NAME> by xcodebuild): SHOTS_DIR, SHOTS_LABEL, SHOTS_ORIENTATION, SHOTS_SCREENS.
final class ScreenAuditTests: XCTestCase {
    static let defaultScreens = [
        "home", "search", "discover", "artists", "albums", "songs", "playlists", "genres", "radio", "replay",
        "favorite-artists", "recent-albums", "favorite-songs", "album", "artist", "playlist", "genre",
        "player", "lyrics", "queue", "song-info", "settings", "customize", "icons", "downloads", "onboarding",
        "knight", "recognized", "recognize", "identified", "playlist-picker", "streamora", "duet-pill", "duet",
    ]
    static let rotationScreens = ["home", "albums", "album", "artist", "player", "lyrics", "queue", "search", "settings", "knight"]

    private let env = ProcessInfo.processInfo.environment
    private var label: String { env["SHOTS_LABEL"] ?? "device" }
    private var landscape: Bool { env["SHOTS_ORIENTATION"] == "landscape" }
    private var orientation: UIDeviceOrientation { landscape ? .landscapeLeft : .portrait }
    private var tag: String { "\(label)-\(landscape ? "land" : "port")" }
    private var outDir: URL {
        let url = URL(fileURLWithPath: env["SHOTS_DIR"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var screens: [String] {
        let list = env["SHOTS_SCREENS"] ?? ""
        return list.isEmpty ? Self.defaultScreens : list.split(separator: ",").map(String.init)
    }

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: - Passes (alphabetical order = run order: a, b, c)

    func test_a_everyScreen() {
        let app = launch(screen: "home", wait: 45)   // first launch logs in to the demo server and syncs
        capture(app, "home")
        for screen in screens where screen != "home" {
            let app = launch(screen: screen, wait: 10)
            capture(app, screen)
        }
    }

    func test_b_rotateLiveScreens() {
        let other: UIDeviceOrientation = landscape ? .portrait : .landscapeRight
        for screen in Self.rotationScreens where screens.contains(screen) {
            let app = launch(screen: screen, wait: 10)
            XCUIDevice.shared.orientation = other
            sleep(3)
            capture(app, "\(screen)-rotated")
            XCUIDevice.shared.orientation = orientation
            sleep(3)
            capture(app, "\(screen)-rotated-back")
        }
    }

    func test_c_crawlSettingsAndLibrary() {
        crawl(screen: "settings", prefix: "crawl-settings")
        crawl(screen: "library-hub", prefix: "crawl-library")
    }

    // MARK: - Helpers

    private func launch(screen: String, wait seconds: UInt32) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        XCUIDevice.shared.orientation = orientation
        app.launchArguments = ["-KMDemo", "YES", "-KMScreen", screen]
        app.launch()
        sleep(seconds)
        return app
    }

    private static let unsafeWords = ["log out", "sign out", "delete", "remove", "clear", "reset", "erase", "force", "restore", "disconnect", "forget"]

    /// Taps every visible row of the screen's list once (depth 1), screenshots the destination, then goes back.
    private func crawl(screen: String, prefix: String) {
        var app = launch(screen: screen, wait: 10)
        capture(app, prefix)
        var visited = Set<String>()
        var stalls = 0
        var step = 0
        while stalls < 3, step < 60 {
            let candidates = rowLabels(app).filter { !visited.contains($0) }
            guard let next = candidates.first else {
                app.swipeUp()
                sleep(1)
                if rowLabels(app).allSatisfy({ visited.contains($0) }) { stalls += 1 }
                continue
            }
            visited.insert(next)
            stalls = 0
            step += 1
            if Self.unsafeWords.contains(where: { next.lowercased().contains($0) }) { continue }
            let cell = app.cells.containing(NSPredicate(format: "label == %@", next)).firstMatch
            let target = cell.exists ? cell : app.buttons[next].firstMatch
            guard target.exists, target.isHittable else { continue }
            target.tap()
            sleep(3)
            let safe = next.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            capture(app, "\(prefix)-\(step)-\(safe)")
            if app.state != .runningForeground {
                record("CRASH after tapping '\(next)' on \(screen)")
                app = launch(screen: screen, wait: 10)
                continue
            }
            goBack(app)
        }
    }

    private func rowLabels(_ app: XCUIApplication) -> [String] {
        guard let snapshot = try? app.snapshot() else { return [] }
        var labels: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .cell, !node.frame.isEmpty {
                let text = node.label.isEmpty ? firstText(node) : node.label
                if let text, !text.isEmpty, !node.children.contains(where: { $0.elementType == .switch }) {
                    labels.append(text)
                }
                return
            }
            node.children.forEach(walk)
        }
        walk(snapshot)
        return labels
    }

    private func firstText(_ node: XCUIElementSnapshot) -> String? {
        if node.elementType == .staticText, !node.label.isEmpty { return node.label }
        for child in node.children { if let text = firstText(child) { return text } }
        return nil
    }

    private func goBack(_ app: XCUIApplication) {
        let sheetIsUp = app.sheets.count > 0 || app.otherElements["PopoverDismissRegion"].exists
        if sheetIsUp {
            app.otherElements["PopoverDismissRegion"].firstMatch.tap()
        }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable, !back.label.isEmpty, back.label != "Close" {
            back.tap()
        } else {
            app.swipeDown(velocity: .fast)   // dismiss a sheet or a cover
        }
        sleep(2)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let file = "\(tag)-\(name)"
        if app.state != .runningForeground { record("NOT RUNNING (crash?) at \(name)") }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        do {
            try png.write(to: outDir.appendingPathComponent("\(file).png"))
        } catch {
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = file
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        writeAccessibilityReport(app, file: file)
    }

    /// One line per element: type, label, frame. Flags icon buttons with no label and text clipped by the window.
    private func writeAccessibilityReport(_ app: XCUIApplication, file: String) {
        guard let snapshot = try? app.snapshot() else { return }
        let window = snapshot.frame
        var lines: [String] = []
        var issues: [String] = []
        func walk(_ node: XCUIElementSnapshot, depth: Int) {
            let f = node.frame
            if !f.isEmpty {
                lines.append("\(String(repeating: " ", count: depth))\(typeName(node.elementType)) '\(node.label)' id=\(node.identifier) [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]")
                if node.elementType == .button, node.label.isEmpty, node.identifier.isEmpty, f.intersects(window) {
                    issues.append("UNLABELED BUTTON at \(f)")
                }
                if node.elementType == .staticText, f.minY < window.maxY, f.maxY > window.minY,
                   f.width < window.width, f.minX < window.minX - 2 || f.maxX > window.maxX + 2,
                   f.minX > window.minX - f.width / 2, f.maxX < window.maxX + f.width / 2 {
                    issues.append("TEXT CLIPPED BY EDGE '\(node.label)' \(f)")
                }
                if [.button, .cell, .link].contains(node.elementType), f.intersects(window), f.width < 28 || f.height < 28,
                   f.width > 1, f.height > 1 {
                    issues.append("SMALL TAP TARGET '\(node.label)' \(Int(f.width))x\(Int(f.height))")
                }
            }
            node.children.forEach { walk($0, depth: depth + 1) }
        }
        walk(snapshot, depth: 0)
        let text = (issues.isEmpty ? [] : ["## ISSUES"] + issues + ["## TREE"]) + lines
        try? text.joined(separator: "\n").write(to: outDir.appendingPathComponent("\(file).ax.txt"), atomically: true, encoding: .utf8)
    }

    private func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: "button"
        case .staticText: "text"
        case .cell: "cell"
        case .image: "image"
        case .switch: "switch"
        case .slider: "slider"
        case .textField: "field"
        case .searchField: "search"
        case .navigationBar: "navbar"
        case .tabBar: "tabbar"
        case .collectionView: "collection"
        case .scrollView: "scroll"
        case .table: "table"
        case .window: "window"
        case .other: "other"
        case .link: "link"
        case .menu: "menu"
        case .sheet: "sheet"
        case .alert: "alert"
        case .progressIndicator: "progress"
        case .activityIndicator: "spinner"
        case .segmentedControl: "segmented"
        case .toolbar: "toolbar"
        default: "type\(type.rawValue)"
        }
    }

    private func record(_ message: String) {
        let line = "\(tag): \(message)\n"
        let url = outDir.appendingPathComponent("\(tag)-events.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        XCTFail(message)
    }
}
