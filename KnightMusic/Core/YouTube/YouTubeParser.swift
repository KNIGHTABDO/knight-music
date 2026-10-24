import Foundation

/// Turns YouTube Music (WEB_REMIX) InnerTube JSON into models. Everything is optional: YouTube reshapes
/// these payloads often, so a missing field drops one value or one row, never the whole page.
enum YouTubeParser {
    typealias JSON = [String: Any]

    // MARK: Helpers

    static func dig(_ object: Any?, _ path: Any...) -> Any? {
        var current = object
        for key in path {
            if let index = key as? Int {
                guard let array = current as? [Any], index >= 0, index < array.count else { return nil }
                current = array[index]
            } else if let name = key as? String {
                guard let dict = current as? JSON else { return nil }
                current = dict[name]
            }
        }
        return current
    }

    static func runs(_ text: Any?) -> [JSON] { (text as? JSON)?["runs"] as? [JSON] ?? [] }

    static func text(_ value: Any?) -> String? {
        let joined = runs(value).compactMap { $0["text"] as? String }.joined()
        if !joined.isEmpty { return joined }
        return (value as? JSON)?["simpleText"] as? String
    }

    /// Every value stored under `key` anywhere below `object` (depth first, in document order).
    static func findAll(_ key: String, in object: Any?) -> [Any] {
        var out: [Any] = []
        // Dictionaries are unordered; walk arrays in order and keys sorted so results are stable.
        func walk(_ node: Any?) {
            if let dict = node as? JSON {
                for k in dict.keys.sorted() {
                    if k == key, let v = dict[k] { out.append(v) } else { walk(dict[k]) }
                }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(object)
        return out
    }

    static func thumbnail(_ object: Any?) -> String? {
        let candidates: [Any?] = [
            dig(object, "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
            dig(object, "thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
            dig(object, "thumbnail", "croppedSquareThumbnailRenderer", "thumbnail", "thumbnails"),
            dig(object, "thumbnail", "thumbnails"),
            dig(object, "foregroundThumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"),
        ]
        for case let list as [JSON] in candidates {
            if let url = list.last?["url"] as? String { return url.hasPrefix("//") ? "https:" + url : url }
        }
        return nil
    }

    static func pageType(_ run: Any?) -> String? {
        dig(run, "navigationEndpoint", "browseEndpoint", "browseEndpointContextSupportedConfigs",
            "browseEndpointContextMusicConfig", "pageType") as? String
    }

    static func browseId(_ run: Any?) -> String? {
        dig(run, "navigationEndpoint", "browseEndpoint", "browseId") as? String
    }

    static func seconds(_ string: String?) -> Int? {
        guard let string, string.range(of: #"^\d+(:\d\d)+$"#, options: .regularExpression) != nil else { return nil }
        return string.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    static func year(_ string: String) -> Int? {
        guard string.range(of: #"^(19|20)\d\d$"#, options: .regularExpression) != nil else { return nil }
        return Int(string)
    }

    private static let separators: Set<String> = ["•", "&", ",", "", "·"]

    private struct Byline {
        var artists: [YTArtistRef] = []
        var album: (String, String)?
        var duration: Int?
        var year: Int?
        var extras: [String] = []
    }

    private static func byline(_ runList: [JSON]) -> Byline {
        var b = Byline()
        for run in runList {
            let value = (run["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            switch pageType(run) {
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
                b.artists.append(YTArtistRef(name: value, browseId: browseId(run)))
            case "MUSIC_PAGE_TYPE_ALBUM":
                if let id = browseId(run) { b.album = (value, id) }
            default:
                if separators.contains(value) { continue }
                if let d = seconds(value) { b.duration = d } else if let y = year(value) { b.year = y } else { b.extras.append(value) }
            }
        }
        return b
    }

    private static let kindWords: Set<String> = ["Song", "Video", "Album", "Single", "EP", "Artist", "Playlist",
                                                 "Episode", "Podcast", "Profile", "Station"]

    // MARK: Items

    /// A row (search result, album/playlist track, artist top song).
    static func listItem(_ r: JSON) -> YTItem? {
        let columns = (r["flexColumns"] as? [Any] ?? []).map { dig($0, "musicResponsiveListItemFlexColumnRenderer", "text") }
        guard let title = columns.first.flatMap({ text($0) }), !title.isEmpty else { return nil }
        let rest = columns.dropFirst().flatMap { runs($0) }
        var b = byline(rest)
        for fixed in r["fixedColumns"] as? [Any] ?? [] {
            if let d = seconds(text(dig(fixed, "musicResponsiveListItemFixedColumnRenderer", "text"))) { b.duration = d }
        }
        // Plain-text artists ("Daft Punk" without a link) show up as the first extra on some rows.
        let extras = b.extras.filter { !kindWords.contains($0) && !$0.hasSuffix(" plays") && !$0.hasSuffix(" views") }

        let watch = dig(r, "overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer",
                        "playNavigationEndpoint", "watchEndpoint")
        if let videoId = (dig(r, "playlistItemData", "videoId") as? String) ?? (dig(watch, "videoId") as? String) {
            let videoType = dig(watch, "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType") as? String
            let artists = b.artists.isEmpty ? extras.prefix(1).map { YTArtistRef(name: $0, browseId: nil) } : b.artists
            let track = Int(text(r["index"]) ?? "")
            return .song(YTSong(videoId: videoId, title: title, artists: artists, album: b.album?.0, albumId: b.album?.1,
                                duration: b.duration, thumbnail: thumbnail(r),
                                isVideo: videoType.map { $0 != "MUSIC_VIDEO_TYPE_ATV" } ?? false,
                                year: b.year, track: track))
        }
        guard let id = dig(r, "navigationEndpoint", "browseEndpoint", "browseId") as? String else { return nil }
        let type = pageType(r) ?? ""
        let subtitle = rest.compactMap { $0["text"] as? String }.joined()
        switch type {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            return .album(YTAlbumItem(browseId: id, title: title, subtitle: subtitle, artists: b.artists, year: b.year, thumbnail: thumbnail(r)))
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
            return .artist(YTArtistItem(browseId: id, name: title, subtitle: extras.last, thumbnail: thumbnail(r)))
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist(YTPlaylistItem(browseId: id, title: title, subtitle: subtitle, thumbnail: thumbnail(r)))
        default:
            return nil
        }
    }

    /// A carousel/grid tile.
    static func twoRowItem(_ r: JSON) -> YTItem? {
        guard let titleRun = runs(r["title"]).first, let title = titleRun["text"] as? String else { return nil }
        let subtitleRuns = runs(r["subtitle"])
        let subtitle = text(r["subtitle"])
        let b = byline(subtitleRuns)
        if let videoId = dig(r, "navigationEndpoint", "watchEndpoint", "videoId") as? String {
            return .song(YTSong(videoId: videoId, title: title, artists: b.artists, album: b.album?.0, albumId: b.album?.1,
                                duration: b.duration, thumbnail: thumbnail(r), isVideo: true, year: b.year, track: nil))
        }
        let endpoint = dig(r, "navigationEndpoint", "browseEndpoint") as? JSON
        guard let id = endpoint?["browseId"] as? String else { return nil }
        let type = pageType(r) ?? pageType(titleRun) ?? ""
        switch type {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            return .album(YTAlbumItem(browseId: id, title: title, subtitle: subtitle, artists: b.artists, year: b.year, thumbnail: thumbnail(r)))
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
            return .artist(YTArtistItem(browseId: id, name: title, subtitle: subtitle, thumbnail: thumbnail(r)))
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            return .playlist(YTPlaylistItem(browseId: id, title: title, subtitle: subtitle, thumbnail: thumbnail(r)))
        default:
            return nil
        }
    }

    static func items(in object: Any?) -> [YTItem] {
        var out: [YTItem] = []
        collectItems(object, into: &out)
        return out
    }

    /// Rows and tiles in document order.
    private static func collectItems(_ node: Any?, into out: inout [YTItem]) {
        if let dict = node as? JSON {
            if let r = dict["musicResponsiveListItemRenderer"] as? JSON {
                if let item = listItem(r) { out.append(item) }
                return
            }
            if let r = dict["musicTwoRowItemRenderer"] as? JSON {
                if let item = twoRowItem(r) { out.append(item) }
                return
            }
            for key in dict.keys.sorted() { collectItems(dict[key], into: &out) }
        } else if let array = node as? [Any] {
            for element in array { collectItems(element, into: &out) }
        }
    }

    static func continuation(in object: Any?) -> String? {
        if let token = findAll("nextContinuationData", in: object).compactMap({ dig($0, "continuation") as? String }).first {
            return token
        }
        return findAll("continuationCommand", in: object).compactMap { dig($0, "token") as? String }.first
    }

    // MARK: Pages

    static func search(_ root: JSON) -> [YTItem] {
        items(in: findAll("musicShelfRenderer", in: root))
    }

    static func suggestions(_ root: JSON) -> [String] {
        findAll("searchSuggestionRenderer", in: root).compactMap { text(dig($0, "suggestion")) }
    }

    static func album(_ root: JSON, browseId: String) -> YTAlbumPage? {
        guard let header = findAll("musicResponsiveHeaderRenderer", in: root).first as? JSON,
              let title = text(header["title"]) else { return nil }
        let artistRuns = runs(header["straplineTextOne"])
        var artists = byline(artistRuns).artists
        if artists.isEmpty, let name = text(header["straplineTextOne"]) { artists = [YTArtistRef(name: name, browseId: nil)] }
        let sub = byline(runs(header["subtitle"]))
        let cover = thumbnail(header)
        let description = findAll("musicDescriptionShelfRenderer", in: root).first.flatMap { text(dig($0, "description")) }
            ?? text(dig(header, "description", "musicDescriptionShelfRenderer", "description"))
        let shelves = findAll("musicShelfRenderer", in: root)
        let songs: [YTSong] = items(in: shelves).compactMap {
            guard case .song(var s) = $0 else { return nil }
            if s.artists.isEmpty { s.artists = artists }
            s.album = title
            s.albumId = browseId
            if s.thumbnail == nil { s.thumbnail = cover }
            s.year = s.year ?? sub.year
            s.isVideo = false
            return s
        }
        let others: [YTAlbumItem] = items(in: findAll("musicCarouselShelfRenderer", in: root)).compactMap {
            if case .album(let a) = $0, a.browseId != browseId { return a }
            return nil
        }
        return YTAlbumPage(browseId: browseId, title: title, subtitle: text(header["subtitle"]), artists: artists,
                           year: sub.year, thumbnail: cover, description: description, songs: songs, otherVersions: others)
    }

    static func artist(_ root: JSON, browseId: String) -> YTArtistPage? {
        let header = (findAll("musicImmersiveHeaderRenderer", in: root).first ?? findAll("musicVisualHeaderRenderer", in: root).first) as? JSON
        guard let header, let name = text(header["title"]) else { return nil }
        let subscribers = text(dig(header, "subscriptionButton", "subscribeButtonRenderer", "subscriberCountText"))
            ?? text(header["monthlyListenerCount"])
        var topSongs: [YTSong] = []
        var topMore: YTBrowseTarget?
        if let shelf = findAll("musicShelfRenderer", in: root).first as? JSON {
            topSongs = items(in: shelf["contents"]).compactMap { if case .song(let s) = $0 { return s } else { return nil } }
            if let run = runs(shelf["title"]).first, let id = browseId(run) {
                topMore = YTBrowseTarget(browseId: id, params: dig(run, "navigationEndpoint", "browseEndpoint", "params") as? String)
            }
        }
        let shelves: [YTShelf] = findAllInOrder("musicCarouselShelfRenderer", in: root).compactMap { value in
            guard let carousel = value as? JSON else { return nil }
            let headerRuns = runs(dig(carousel, "header", "musicCarouselShelfBasicHeaderRenderer", "title"))
            guard let title = headerRuns.compactMap({ $0["text"] as? String }).first else { return nil }
            let list = items(in: carousel["contents"])
            guard !list.isEmpty else { return nil }
            var more: YTBrowseTarget?
            if let run = headerRuns.first, let id = browseId(run) {
                more = YTBrowseTarget(browseId: id, params: dig(run, "navigationEndpoint", "browseEndpoint", "params") as? String)
            }
            return YTShelf(title: title, items: list, more: more)
        }
        return YTArtistPage(browseId: browseId, name: name, thumbnail: thumbnail(header), subscribers: subscribers,
                            description: text(header["description"]), topSongs: topSongs, topSongsMore: topMore, shelves: shelves)
    }

    static func playlist(_ root: JSON, browseId: String) -> YTPlaylistPage? {
        let header = (findAll("musicResponsiveHeaderRenderer", in: root).first
            ?? findAll("musicDetailHeaderRenderer", in: root).first) as? JSON
        let title = text(header?["title"]) ?? text(dig(root, "header", "musicEditablePlaylistDetailHeaderRenderer", "header", "musicResponsiveHeaderRenderer", "title"))
        guard let title else { return nil }
        let shelves = findAll("musicPlaylistShelfRenderer", in: root) + findAll("musicShelfRenderer", in: root)
        let songs: [YTSong] = items(in: shelves).compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        return YTPlaylistPage(browseId: browseId, title: title, subtitle: text(header?["subtitle"]),
                              detail: text(header?["secondSubtitle"]), thumbnail: thumbnail(header),
                              songs: songs, continuation: continuation(in: shelves))
    }

    static func continuationSongs(_ root: JSON) -> (songs: [YTSong], continuation: String?) {
        let body = root["continuationContents"] ?? root["onResponseReceivedActions"]
        let songs: [YTSong] = items(in: body).compactMap { if case .song(let s) = $0 { return s } else { return nil } }
        return (songs, continuation(in: body))
    }

    static func grid(_ root: JSON) -> YTBrowseGrid {
        let title = text(dig(root, "header", "musicHeaderRenderer", "title"))
            ?? (findAll("musicResponsiveHeaderRenderer", in: root).first.flatMap { text(dig($0, "title")) })
            ?? ""
        return YTBrowseGrid(title: title, items: items(in: root["contents"]))
    }

    /// `next` with a radio playlist: the "Up next" queue.
    static func radio(_ root: JSON) -> [YTSong] {
        findAllInOrder("playlistPanelVideoRenderer", in: root).compactMap { value in
            guard let r = value as? JSON, let videoId = r["videoId"] as? String, let title = text(r["title"]) else { return nil }
            let b = byline(runs(r["longBylineText"]))
            let artists = b.artists.isEmpty ? b.extras.prefix(1).map { YTArtistRef(name: $0, browseId: nil) } : b.artists
            let videoType = dig(r, "navigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType") as? String
            return YTSong(videoId: videoId, title: title, artists: artists, album: b.album?.0, albumId: b.album?.1,
                          duration: b.duration ?? seconds(text(r["lengthText"])), thumbnail: thumbnail(r),
                          isVideo: videoType.map { $0 != "MUSIC_VIDEO_TYPE_ATV" } ?? false, year: b.year, track: nil)
        }
    }

    /// The browse id of the "Lyrics" tab in a `next` response.
    static func lyricsBrowseId(_ root: JSON) -> String? {
        for tab in findAll("tabRenderer", in: root) {
            if let id = dig(tab, "endpoint", "browseEndpoint", "browseId") as? String, id.hasPrefix("MPLY") { return id }
        }
        return nil
    }

    static func lyricsText(_ root: JSON) -> String? {
        findAll("musicDescriptionShelfRenderer", in: root).first.flatMap { text(dig($0, "description")) }
    }

    /// Like `findAll` but keeps array order and the natural nesting order for a key that appears in siblings.
    static func findAllInOrder(_ key: String, in object: Any?) -> [Any] {
        var out: [Any] = []
        func walk(_ node: Any?) {
            if let dict = node as? JSON {
                if let hit = dict[key] { out.append(hit); return }
                for k in dict.keys.sorted() { walk(dict[k]) }
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(object)
        return out
    }
}
