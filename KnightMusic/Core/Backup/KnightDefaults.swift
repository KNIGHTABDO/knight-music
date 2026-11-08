import Foundation

/// Pre-filled, editable defaults for Knight's own setup, so a fresh install only needs the password.
enum KnightDefaults {
    static let serverName = "Knight"
    static let username = "knight"
    /// Reachable anywhere (Tailscale Funnel).
    static let navidromeAddress = "https://desktop-1rsqaqq.tail7d75d9.ts.net"
    /// Faster at home; tried first.
    static let navidromeLANAddress = "http://192.168.11.106:4533"
    /// Hermes agent behind "Knight" (the AI tab).
    static let knightAIAddress = "https://desktop-1rsqaqq.tail7d75d9.ts.net:8643"
}
