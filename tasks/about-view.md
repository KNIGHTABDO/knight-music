# About screen

Allowed path: create ONLY `KnightMusic/UI/Settings/AboutView.swift`.

Build `struct AboutView: View` — the Settings → About page of Knight Music (SwiftUI, iOS 26).
- A `List` with `.listStyle(.insetGrouped)`, `.navigationTitle("About")`.
- Header section (no section title): centered VStack with the app name "Knight Music" (title2, bold), and below it
  "Version X (Y)" where X = Bundle.main.infoDictionary["CFBundleShortVersionString"] and Y = "CFBundleVersion"
  (fallback "—"), secondary color.
- Section "Project": a `Link` row "GitHub" to https://github.com/KNIGHTABDO/knight-music, tinted with the accent color.
- Section "Acknowledgements": plain text rows "Navidrome", "GRDB.swift", "Nuke", "Animated artwork by artwork.m8tec.top".
- No other types, no previews needed. Only `import SwiftUI`.
