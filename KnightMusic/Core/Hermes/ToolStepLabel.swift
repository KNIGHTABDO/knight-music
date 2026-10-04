import Foundation

/// Maps tool names and their execution arguments into human-friendly status labels and SF Symbols.
enum ToolStepLabel {
    struct Info: Sendable {
        let label: String
        let systemImage: String
    }

    /// Derives a friendly label and SF Symbol from the tool name and arguments JSON string.
    static func label(for name: String, argumentsJSON: String) -> Info {
        let lowerName = name.lowercased()
        let lowerArgs = argumentsJSON.lowercased()

        var command = ""
        if let data = argumentsJSON.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cmd = dict["command"] as? String {
            command = cmd.lowercased()
        }

        let combined = "\(lowerName) \(lowerArgs) \(command)"

        if combined.contains("yt-dlp") {
            return Info(label: "Downloading audio", systemImage: "arrow.down.circle")
        }
        if combined.contains("ffmpeg") {
            return Info(label: "Tagging & embedding cover", systemImage: "tag")
        }
        if combined.contains("itunes.apple.com") || lowerName.contains("itunes") {
            return Info(label: "Fetching cover art", systemImage: "photo")
        }
        if combined.contains("lrclib") {
            return Info(label: "Fetching synced lyrics", systemImage: "quote.bubble")
        }
        if lowerName == "search_files" || lowerName == "ls" || lowerName == "find"
            || command.contains("find ") || command.contains("ls ") || combined.contains("search_files") {
            return Info(label: "Checking your library", systemImage: "folder")
        }
        if lowerName == "skill_view" || combined.contains("skill_view") {
            return Info(label: "Reading music skill", systemImage: "book")
        }
        if combined.contains("web_search") || combined.contains("browser") {
            return Info(label: "Searching the web", systemImage: "globe")
        }
        return Info(label: "Working…", systemImage: "gearshape")
    }
}
