import Foundation
import os

/// Thin wrapper over os.Logger that also keeps the most recent lines in memory for the Diagnostics screen.
/// Use either `Log.info("text", .sync)` or `Log.sync.info("text")`.
enum Log {
    enum Category: String, CaseIterable {
        case app, api, sync, database, playback, downloads, artwork, network, ui
    }

    enum Level: String {
        case debug, info, warning, error
    }

    static let subsystem = "com.knightabdo.knightmusic"

    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map { ($0, Logger(subsystem: subsystem, category: $0.rawValue)) }
    )
    private static let buffer = LogBuffer(capacity: 1500)

    static let app = CategoryLog(category: .app)
    static let api = CategoryLog(category: .api)
    static let sync = CategoryLog(category: .sync)
    static let database = CategoryLog(category: .database)
    static let playback = CategoryLog(category: .playback)
    static let downloads = CategoryLog(category: .downloads)
    static let artwork = CategoryLog(category: .artwork)
    static let network = CategoryLog(category: .network)
    static let ui = CategoryLog(category: .ui)

    static func debug(_ message: @autoclosure () -> String, _ category: Category = .app) { write(.debug, message(), category) }
    static func info(_ message: @autoclosure () -> String, _ category: Category = .app) { write(.info, message(), category) }
    static func warning(_ message: @autoclosure () -> String, _ category: Category = .app) { write(.warning, message(), category) }
    static func error(_ message: @autoclosure () -> String, _ category: Category = .app) { write(.error, message(), category) }

    static func write(_ level: Level, _ message: String, _ category: Category) {
        if let logger = loggers[category] {
            switch level {
            case .debug: logger.debug("\(message, privacy: .public)")
            case .info: logger.notice("\(message, privacy: .public)")
            case .warning: logger.warning("\(message, privacy: .public)")
            case .error: logger.error("\(message, privacy: .public)")
            }
        }
        buffer.append(level: level, category: category, message: message)
    }

    /// Most recent lines, oldest first.
    static var recentLines: [String] { buffer.lines() }

    static func clear() { buffer.clear() }

    /// Plain-text export (header + recent lines) for sharing from the Diagnostics screen.
    static func exportText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var out = "Knight Music \(version) (\(build))\n"
        out += "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Exported: \(Date().formatted(.iso8601))\n\n"
        out += recentLines.joined(separator: "\n")
        return out
    }
}

struct CategoryLog {
    let category: Log.Category
    func debug(_ message: @autoclosure () -> String) { Log.write(.debug, message(), category) }
    func info(_ message: @autoclosure () -> String) { Log.write(.info, message(), category) }
    func warning(_ message: @autoclosure () -> String) { Log.write(.warning, message(), category) }
    func error(_ message: @autoclosure () -> String) { Log.write(.error, message(), category) }
}

private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private let capacity: Int
    private let formatter: DateFormatter

    init(capacity: Int) {
        self.capacity = capacity
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        storage.reserveCapacity(capacity)
    }

    func append(level: Log.Level, category: Log.Category, message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(level.rawValue.uppercased())] [\(category.rawValue)] \(message)"
        storage.append(line)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}
