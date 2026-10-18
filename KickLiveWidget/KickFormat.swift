import Foundation

enum KickFormat {
    /// 977 · 4.7K · 12K · 1.2M
    static func viewers(_ count: Int) -> String {
        switch count {
        case ..<1_000: return "\(count)"
        case ..<9_950: return oneDecimal(Double(count) / 1_000) + "K"
        case ..<999_500: return "\(Int((Double(count) / 1_000).rounded()))K"
        default: return oneDecimal(Double(count) / 1_000_000) + "M"
        }
    }

    /// "2h 13m" or "45m"
    static func uptime(since start: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func oneDecimal(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
