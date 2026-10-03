import SwiftUI
import CryptoKit

// TEMPORARY — showcases the design-system components with real demo.navidrome.org covers.
// The integrator deletes this file (and the RootView hook) once real screens exist.

private struct DemoCoverProvider: CoverArtURLProviding {
    static let base = URL(string: "https://demo.navidrome.org")!

    /// Fresh random salt on every call, exactly like the real client: proves the stable cache key works.
    static func authItems() -> [URLQueryItem] {
        let salt = String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement() ?? "a" })
        let token = Insecure.MD5.hash(data: Data(("demo" + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        return [
            URLQueryItem(name: "u", value: "demo"), URLQueryItem(name: "t", value: token), URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"), URLQueryItem(name: "c", value: "KnightMusic"), URLQueryItem(name: "f", value: "json")
        ]
    }

    func coverArtURL(id: String, size: Int?) -> URL {
        var comps = URLComponents(url: Self.base.appendingPathComponent("rest/getCoverArt.view"), resolvingAgainstBaseURL: false)
        var items = Self.authItems() + [URLQueryItem(name: "id", value: id)]
        if let size { items.append(URLQueryItem(name: "size", value: String(size))) }
        comps?.queryItems = items
        return comps?.url ?? Self.base
    }

    static func rest(_ method: String, _ extra: [URLQueryItem]) async -> [String: Any]? {
        var comps = URLComponents(url: base.appendingPathComponent("rest/\(method).view"), resolvingAgainstBaseURL: false)
        comps?.queryItems = authItems() + extra
        guard let url = comps?.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return root["subsonic-response"] as? [String: Any]
    }
}

@MainActor @Observable
private final class CatalogModel {
    var albums: [Album] = []
    var songs: [Song] = []
    var palette: ArtworkPalette = .fallback
    let parachutes = Song(id: "catalog-parachutes", title: "Yellow", album: "Parachutes", albumId: "catalog-parachutes",
                          artist: "Coldplay", duration: 266)
    var animated: AnimatedArtwork?
    var animatedStatus = "Looking up Coldplay – Parachutes…"

    func load(service: AnimatedArtworkService) async {
        async let animatedTask: Void = loadAnimated(service)
        if let reply = await DemoCoverProvider.rest("getAlbumList2", [URLQueryItem(name: "type", value: "newest"), URLQueryItem(name: "size", value: "24")]),
           let list = (reply["albumList2"] as? [String: Any])?["album"] as? [[String: Any]] {
            albums = list.compactMap { a in
                guard let id = a["id"] as? String, let name = a["name"] as? String else { return nil }
                return Album(id: id, name: name, artist: a["artist"] as? String, coverArt: a["coverArt"] as? String,
                             songCount: a["songCount"] as? Int, duration: a["duration"] as? Int)
            }
        }
        if let first = albums.first {
            async let paletteTask = ArtworkPalette.palette(for: first.coverArt)
            if let reply = await DemoCoverProvider.rest("getAlbum", [URLQueryItem(name: "id", value: first.id)]),
               let list = (reply["album"] as? [String: Any])?["song"] as? [[String: Any]] {
                songs = list.prefix(6).compactMap { s in
                    guard let id = s["id"] as? String, let title = s["title"] as? String else { return nil }
                    return Song(id: id, title: title, album: s["album"] as? String, albumId: s["albumId"] as? String,
                                artist: s["artist"] as? String, track: s["track"] as? Int, coverArt: s["coverArt"] as? String,
                                duration: s["duration"] as? Int)
                }
            }
            palette = await paletteTask
        }
        await animatedTask
    }

    private func loadAnimated(_ service: AnimatedArtworkService) async {
        if let art = await service.animatedArtwork(for: parachutes) {
            animated = art
            animatedStatus = "Coldplay – Parachutes · m8tec animated artwork (tall \(art.tallVideoURL != nil ? "yes" : "no"))"
        } else {
            animatedStatus = "No animated artwork returned (offline, metered, or none)"
        }
    }
}

struct DesignSystemCatalog: View {
    @State private var model = CatalogModel()
    @State private var service = AnimatedArtworkService()
    @State private var rating = 3
    @State private var lastLetter = "—"
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let coldplayCover = "demo-none"

    init() {
        ArtworkLoader.configure(provider: DemoCoverProvider())
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 36) {
                        shelves.id("shelves")
                        grid.id("grid")
                        artists.id("artists")
                        songs.id("songs")
                        playlists.id("playlists")
                        hero.id("hero")
                        player.id("player")
                        misc.id("misc")
                        tokens.id("tokens")
                    }
                    .padding(.vertical, 12)
                    .padding(.bottom, 80)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .task {
                    await model.load(service: service)
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if let target = Self.target { withAnimation(nil) { proxy.scrollTo(target, anchor: .top) } }
                }
            }
            .background(Theme.background)
            .navigationTitle("Design System")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Shuffle", systemImage: "shuffle") {} }
            }
        }
        .environment(service)
        .tint(Theme.accent)
    }

    /// CI shots launch with -KMScreen <name>; map each to a catalog section so every shot shows something different.
    private static var target: String? {
        switch UserDefaults.standard.string(forKey: "KMScreen") {
        case "home": return nil
        case "search": return "grid"
        case "artists", "artist": return "artists"
        case "albums": return "grid"
        case "songs", "queue", "downloads": return "songs"
        case "playlists": return "playlists"
        case "album": return "hero"
        case "player": return "player"
        case "lyrics", "settings": return "misc"
        case "server", "onboarding": return "tokens"
        default: return nil
        }
    }

    // MARK: Sections

    private var shelves: some View {
        VStack(alignment: .leading, spacing: 28) {
            if model.albums.isEmpty {
                SkeletonTileGrid(count: 4)
            } else {
                ShelfSection(title: "Recently Played", items: Array(model.albums.prefix(10)), onHeaderTap: {}) { album in
                    AlbumTile(album: album)
                }
                ShelfSection(title: "Recently Added", items: Array(model.albums.dropFirst(8).prefix(10)), onHeaderTap: {}) { album in
                    AlbumTile(album: album)
                }
            }
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Albums").padding(.horizontal, Theme.margin)
            AdaptiveAlbumGrid(items: Array(model.albums.prefix(10))) { album in AlbumTile(album: album) }
        }
    }

    private var artists: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Artists").padding(.horizontal, Theme.margin)
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(model.albums.prefix(6).enumerated()), id: \.element.id) { index, album in
                        ArtistRow(name: album.artist ?? "Unknown Artist", coverArt: album.coverArt,
                                  subtitle: index.isMultiple(of: 2) ? "1 Album" : nil)
                            .padding(.vertical, 8)
                        Divider().padding(.leading, 70)
                    }
                    if model.albums.isEmpty { SkeletonRowList(count: 4, circularLeading: true) }
                }
                .padding(.leading, Theme.margin)
                AlphabetIndexScrubber(activeLetters: ["#", "A", "B", "C", "D", "M", "S", "T"]) { lastLetter = $0 }
                    .frame(height: 360)
                    .padding(.horizontal, 6)
            }
            Text("Index → \(lastLetter)").font(.kmTileSubtitle).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, Theme.margin)
        }
    }

    private var songs: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Songs").padding(.horizontal, Theme.margin).padding(.bottom, 6)
            if model.songs.isEmpty {
                SkeletonRowList(count: 5)
            } else {
                ForEach(Array(model.songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, showsArtwork: index < 3, isPlaying: index == 1, isDownloaded: index.isMultiple(of: 2)) {
                        Button("Play Next", systemImage: "text.insert") {}
                        Button("Add to Playlist", systemImage: "text.badge.plus") {}
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, Theme.margin)
                    Divider().padding(.leading, index < 3 ? 76 : 56)
                }
            }
        }
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Playlists").padding(.horizontal, Theme.margin).padding(.bottom, 6)
            PlaylistRow(name: "Road Trip", coverArts: model.albums.prefix(4).map(\.coverArt), songCount: 67, duration: 12180)
                .padding(.horizontal, Theme.margin).padding(.vertical, 6)
            Divider().padding(.leading, 90)
            PlaylistRow(name: "Late Night", coverArts: model.albums.dropFirst(4).prefix(2).map(\.coverArt), songCount: 1, duration: 215)
                .padding(.horizontal, Theme.margin).padding(.vertical, 6)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Hero artwork").padding(.horizontal, Theme.margin)
            HStack(alignment: .top, spacing: 16) {
                heroSquare
                    .frame(maxWidth: sizeClass == .regular ? 380 : .infinity)
                Text(model.animatedStatus)
                    .font(.kmTileSubtitle).foregroundStyle(Theme.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(sizeClass == .regular ? 1 : 0).frame(height: sizeClass == .regular ? nil : 0)
            }
            .padding(.horizontal, Theme.margin)
            if sizeClass != .regular {
                Text(model.animatedStatus).font(.kmTileSubtitle).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, Theme.margin)
            }
        }
    }

    /// Square animated artwork (m8tec square master) over the static cover.
    private var heroSquare: some View {
        ZStack {
            ArtworkView(coverArt: model.albums.first?.coverArt, pointSize: 340, cornerRadius: Theme.Radius.large, fillsContainer: true)
            if let animated = model.animated {
                AnimatedArtworkView(url: animated.squareVideoURL)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    private var player: some View {
        let width: CGFloat = sizeClass == .regular ? 360 : 270
        return ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .fill(model.palette.backgroundGradient)
            VStack(spacing: 16) {
                ZStack {
                    Color(uiColor: .systemGray6)
                    if let tall = model.animated?.tallVideoURL ?? model.animated?.squareVideoURL {
                        AnimatedArtworkView(url: tall)
                    } else {
                        Image(systemName: "music.note").font(.system(size: 44)).foregroundStyle(Theme.tertiaryLabel)
                    }
                }
                .frame(width: width, height: width * 4 / 3)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 28, y: 14)

                VStack(spacing: 2) {
                    Text("Yellow").font(.kmPlayerTitle).foregroundStyle(.white)
                    Text("Coldplay").font(.system(size: 17)).foregroundStyle(.white.opacity(0.7))
                }
                GlassCapsuleBar(spacing: 14) {
                    GlassIconButton(systemName: "backward.fill", size: 48) {}
                    GlassIconButton(systemName: "pause.fill", size: 56, tint: Theme.accent) {}
                    GlassIconButton(systemName: "forward.fill", size: 48) {}
                }
            }
            .padding(.vertical, 28)
        }
        .padding(.horizontal, Theme.margin)
        .overlay(alignment: .topLeading) {
            Text("Player background · palette \(model.palette.colors.count) colors")
                .font(.kmTileSubtitle).foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, Theme.margin + 16).padding(.top, 12)
        }
    }

    private var misc: some View {
        VStack(alignment: .leading, spacing: 22) {
            SectionHeader(title: "Controls").padding(.horizontal, Theme.margin)
            HStack(spacing: 18) {
                StarRatingView(rating: $rating)
                NowPlayingIndicator(isAnimating: true, size: 22)
                NowPlayingIndicator(isAnimating: false, size: 22)
            }
            .padding(.horizontal, Theme.margin)
            HStack(spacing: 12) {
                GlassIconButton(systemName: "heart") {}
                GlassIconButton(systemName: "airplayaudio") {}
                GlassIconButton(systemName: "list.bullet") {}
                Button("Play") {}.buttonStyle(.glassProminent)
                Button("Shuffle") {}.buttonStyle(.glass)
            }
            .padding(.horizontal, Theme.margin)
            EmptyStateView(title: "No Downloads", systemImage: "arrow.down.circle",
                           message: "Songs you download appear here.", actionTitle: "Browse Library") {}
                .frame(height: 260)
            SkeletonRowList(count: 2)
            Text("Formats: \(KMFormat.duration(235)) · \(KMFormat.totalDuration(12180)) · \(KMFormat.songCount(67))")
                .font(.kmTileSubtitle).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, Theme.margin)
        }
    }

    private var tokens: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Tokens").padding(.horizontal, Theme.margin)
            Text("Large title 34 bold").font(.kmLargeTitle).foregroundStyle(Theme.label).padding(.horizontal, Theme.margin)
            Text("Section title 22 bold").font(.kmSectionTitle).foregroundStyle(Theme.label).padding(.horizontal, Theme.margin)
            Text("Tile title 15").font(.kmTileTitle).foregroundStyle(Theme.label).padding(.horizontal, Theme.margin)
            Text("Tile subtitle 13 secondary").font(.kmTileSubtitle).foregroundStyle(Theme.secondaryLabel).padding(.horizontal, Theme.margin)
            HStack(spacing: 10) {
                swatch(Theme.accent, "accent")
                swatch(Theme.secondaryBackground, "gray6")
                swatch(Theme.secondaryLabel, "secondary")
                swatch(Theme.tertiaryLabel, "tertiary")
                ForEach(Array(model.palette.swiftUIColors.enumerated()), id: \.offset) { _, c in swatch(c, "palette") }
            }
            .padding(.horizontal, Theme.margin)
        }
    }

    private func swatch(_ color: Color, _ name: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color).frame(width: 44, height: 44)
            Text(name).font(.system(size: 10)).foregroundStyle(Theme.secondaryLabel)
        }
    }
}
