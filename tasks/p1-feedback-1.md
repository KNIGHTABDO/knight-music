Reviewed the new screenshots. Sidebar default, iPhone player, empty accessory and the scrubber padding are fixed — great. Remaining:

1. iPad HOME (and likely other screens): content is drawn UNDER the sidebar. The large title "Navidrome Demo" is hidden behind the
   sidebar and the first shelf tiles are cut off at the left. The content must start to the right of the sidebar (respect the leading
   safe area). Find any `.ignoresSafeArea()` / `.edgesIgnoringSafeArea` applied to screen CONTENT (ScrollView/List/VStack) in
   KnightMusic/UI/** (Shell, Home, Library, Detail, Search, Settings) and change it so only the black background ignores safe areas:
   `.background(Color.black.ignoresSafeArea())`. Horizontal shelves may scroll under the sidebar edge only through
   `.scrollClipDisabled()`-style overflow, but their FIRST item must start aligned with the title. Check all screens on iPad.
   You may edit files in KnightMusic/UI/Home, UI/Library, UI/Detail, UI/Search, UI/Settings for this fix only.
2. iPad FULL PLAYER (landscape) is still wrong: artwork is tiny (~220pt on a 1180pt-wide screen) and the right column has the title at
   the very top and controls at the very bottom with a huge empty middle. Rebuild the regular-width layout like Apple Music iPad:
   `GeometryReader { geo in HStack(spacing: 48) { artwork; controlsColumn } .padding(.horizontal, 56) }` where
   artwork side = min(geo.size.width * 0.42, geo.size.height * 0.72) applied with `.frame(width: side, height: side)` (no
   maxWidth wrappers that let it shrink), and controlsColumn = a VStack(spacing: 28) vertically CENTERED, max width 480:
   title/artist + heart/stars/••• row, scrubber + times/format, transport row, volume row, bottom glass button row.
   When the lyrics/queue panel is open on iPad, the panel takes the artwork's place on the left (artwork shrinks into the header row).
3. NEW: sidebar customization ("Edit" button like ref/IMG_1160.PNG top-left). Use Apple's API:
   `@AppStorage("sidebarCustomization") private var customization: TabViewCustomization` (TabViewCustomization is Codable/RawRepresentable
   in the SDK — if AppStorage rejects it, keep it in `@State` and persist with JSONEncoder to UserDefaults) and
   `.tabViewCustomization($customization)` on the TabView, plus `.customizationID("<stable id>")` on EVERY Tab and TabSection
   (e.g. "tab.home", "library.artists"...). Home/Search/Settings: `.customizationBehavior(.disabled, for: .sidebar, .tabBar)` so they
   can't be hidden. This gives users the native Edit button to reorder/hide library items and remembers the layout.
