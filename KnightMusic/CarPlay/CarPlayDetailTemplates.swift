import CarPlay
import Foundation
import UIKit

/// Factory creating detail templates for albums, artists, genres, playlists and radio.
@MainActor
final class CarPlayDetailTemplates {
    // MARK: - Album Detail

    static func makeAlbumDetail(albumId: String, coordinator: CarPlayCoordinator) -> CPListTemplate {
        let template = CPListTemplate(title: "Album", sections: [])
        let albumQuery = coordinator.library.album(id: albumId)

        var queryTask: Task<Void, Never>?
        var isObserving = true

        let rebuild = {
            let content = albumQuery.value
            guard let album = content.album else {
                if albumQuery.isLoaded {
                    template.emptyViewTitleVariants = ["Album Not Found"]
                    template.emptyViewSubtitleVariants = ["This album is no longer available in your library."]
                    template.updateSections([])
                }
                return
            }

            template.title = album.name
            let songs = coordinator.playableFilter.filterSongs(content.songs)

            if songs.isEmpty {
                let isOffline = coordinator.appModel.isOffline
                template.emptyViewTitleVariants = [isOffline ? "Not available offline" : "No Songs"]
                template.emptyViewSubtitleVariants = [isOffline ? "This album has no downloaded songs." : "There are no songs in this album."]
                template.updateSections([])
                return
            }

            let scale = coordinator.scale
            let targetSize = CPListItem.maximumImageSize

            // Multi-disc detection
            let discNumbers = Set(songs.compactMap { $0.discNumber ?? 1 })
            let isMultiDisc = discNumbers.count > 1

            let playItem = CPListItem(text: "Play", detailText: nil, image: UIImage(systemName: "play.fill"), accessoryImage: nil, accessoryType: .none)
            playItem.userInfo = "album-play"
            playItem.handler = { [weak coordinator] _, completion in
                defer { completion() }
                coordinator?.playSongs(songs, startAt: 0, shuffle: false)
            }

            let shuffleItem = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"), accessoryImage: nil, accessoryType: .none)
            shuffleItem.userInfo = "album-shuffle"
            shuffleItem.handler = { [weak coordinator] _, completion in
                defer { completion() }
                coordinator?.playSongs(songs, shuffle: true)
            }

            var sections: [CPListSection] = []

            if isMultiDisc {
                sections.append(CPListSection(items: [playItem, shuffleItem]))

                for disc in discNumbers.sorted() {
                    let discSongs = songs.filter { ($0.discNumber ?? 1) == disc }
                    let discItems = discSongs.enumerated().map { (discIndex, song) -> CPListItem in
                        let trackNumber = song.track != nil ? "\(song.track!). " : ""
                        let songTitle = "\(trackNumber)\(song.title)"
                        let diffArtist = (song.artist != album.artist && song.artist?.isEmpty == false) ? song.artist : nil

                        let item = CPListItem(text: songTitle, detailText: diffArtist, image: nil, accessoryImage: nil, accessoryType: .none)
                        item.userInfo = song.id
                        item.isPlaying = (song.id == coordinator.player.currentSong?.id)
                        item.playingIndicatorLocation = .trailing
                        coordinator.registerSongItem(item, songId: song.id)

                        item.handler = { [weak coordinator] _, completion in
                            defer { completion() }
                            if let globalIndex = songs.firstIndex(where: { $0.id == song.id }) {
                                coordinator?.playSongs(songs, startAt: globalIndex, shuffle: false)
                            }
                        }
                        return item
                    }
                    sections.append(CPListSection(items: discItems, header: "Disc \(disc)", sectionIndexTitle: nil))
                }
            } else {
                var sectionItems: [CPListTemplateItem] = [playItem, shuffleItem]
                for (index, song) in songs.enumerated() {
                    let trackNumber = song.track != nil ? "\(song.track!). " : ""
                    let songTitle = "\(trackNumber)\(song.title)"
                    let diffArtist = (song.artist != album.artist && song.artist?.isEmpty == false) ? song.artist : nil

                    let item = CPListItem(text: songTitle, detailText: diffArtist, image: nil, accessoryImage: nil, accessoryType: .none)
                    item.userInfo = song.id
                    item.isPlaying = (song.id == coordinator.player.currentSong?.id)
                    item.playingIndicatorLocation = .trailing
                    coordinator.registerSongItem(item, songId: song.id)

                    item.handler = { [weak coordinator] _, completion in
                        defer { completion() }
                        coordinator?.playSongs(songs, startAt: index, shuffle: false)
                    }
                    sectionItems.append(item)
                }
                sections.append(CPListSection(items: sectionItems))
            }

            let clamped = CarPlayItemFactory.clampSections(sections)
            if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
                template.updateSections(clamped)
            }
        }

        func observe() {
            guard isObserving else { return }
            withObservationTracking {
                _ = albumQuery.value
            } onChange: {
                Task { @MainActor in
                    guard isObserving else { return }
                    rebuild()
                    observe()
                }
            }
        }

        queryTask = Task { await albumQuery.run() }
        rebuild()
        observe()

        coordinator.trackDisappearance(of: template) {
            isObserving = false
            queryTask?.cancel()
            queryTask = nil
        }

        return template
    }

    // MARK: - Artist Detail

    static func makeArtistDetail(artistId: String, coordinator: CarPlayCoordinator) -> CPListTemplate {
        let template = CPListTemplate(title: "Artist", sections: [])
        let artistQuery = coordinator.library.artist(id: artistId)
        let topSongsQuery = coordinator.library.topSongs(artistId: artistId)
        let albumsQuery = coordinator.library.albums(artistId: artistId)
        let allSongsQuery = coordinator.library.songs(artistId: artistId)

        var artistTask: Task<Void, Never>?
        var topSongsTask: Task<Void, Never>?
        var albumsTask: Task<Void, Never>?
        var allSongsTask: Task<Void, Never>?
        var isObserving = true

        let rebuild = {
            guard let artist = artistQuery.value else {
                if artistQuery.isLoaded {
                    template.emptyViewTitleVariants = ["Artist Not Found"]
                    template.emptyViewSubtitleVariants = ["This artist is no longer available in your library."]
                    template.updateSections([])
                }
                return
            }

            template.title = artist.name
            let allSongs = coordinator.playableFilter.filterSongs(allSongsQuery.value)
            let topSongs = coordinator.playableFilter.filterSongs(topSongsQuery.value)
            let albums = albumsQuery.value

            var section0Items: [CPListTemplateItem] = []

            if !allSongs.isEmpty {
                let shuffleItem = CPListItem(text: "Shuffle", detailText: "\(allSongs.count) songs", image: UIImage(systemName: "shuffle"), accessoryImage: nil, accessoryType: .none)
                shuffleItem.userInfo = "artist-shuffle"
                shuffleItem.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    coordinator?.playSongs(allSongs, shuffle: true)
                }
                section0Items.append(shuffleItem)
            }

            if !topSongs.isEmpty {
                let topItem = CPListItem(text: "Top Songs", detailText: "\(topSongs.count) songs", image: UIImage(systemName: "star.fill"), accessoryImage: nil, accessoryType: .disclosureIndicator)
                topItem.userInfo = "artist-top-songs"
                topItem.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    guard let coordinator else { return }
                    if coordinator.canPush {
                        let topTemplate = makeArtistTopSongs(artistId: artistId, artistName: artist.name, coordinator: coordinator)
                        coordinator.push(topTemplate)
                    } else {
                        coordinator.playSongs(topSongs, startAt: 0, shuffle: false)
                    }
                }
                section0Items.append(topItem)
            }

            var sections: [CPListSection] = []
            if !section0Items.isEmpty {
                sections.append(CPListSection(items: section0Items))
            }

            if !albums.isEmpty {
                let scale = coordinator.scale
                let targetSize = CPListItem.maximumImageSize

                let albumItems = albums.map { album -> CPListItem in
                    let detail = CarPlayItemFactory.albumDetailText(artist: album.year.map(String.init), year: nil)
                    let item = CPListItem(text: album.name, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
                    item.userInfo = album.id

                    let initialImg = coordinator.artwork.loadCover(art: album.coverArt, targetSize: targetSize, scale: scale, placeholderSymbol: "square.stack", for: template) { [weak item] loaded in
                        item?.setImage(loaded)
                    }
                    item.setImage(initialImg)

                    item.handler = { [weak coordinator] _, completion in
                        defer { completion() }
                        guard let coordinator else { return }
                        if coordinator.canPush {
                            let albumDetail = makeAlbumDetail(albumId: album.id, coordinator: coordinator)
                            coordinator.push(albumDetail)
                        } else {
                            coordinator.playAlbum(album, shuffle: false)
                        }
                    }
                    return item
                }
                sections.append(CPListSection(items: albumItems, header: "Albums", sectionIndexTitle: nil))
            }

            let clamped = CarPlayItemFactory.clampSections(sections)
            if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
                template.updateSections(clamped)
            }
        }

        func observe() {
            guard isObserving else { return }
            withObservationTracking {
                _ = artistQuery.value
                _ = topSongsQuery.value
                _ = albumsQuery.value
                _ = allSongsQuery.value
            } onChange: {
                Task { @MainActor in
                    guard isObserving else { return }
                    rebuild()
                    observe()
                }
            }
        }

        artistTask = Task { await artistQuery.run() }
        topSongsTask = Task { await topSongsQuery.run() }
        albumsTask = Task { await albumsQuery.run() }
        allSongsTask = Task { await allSongsQuery.run() }

        rebuild()
        observe()

        coordinator.trackDisappearance(of: template) {
            isObserving = false
            artistTask?.cancel()
            topSongsTask?.cancel()
            albumsTask?.cancel()
            allSongsTask?.cancel()
        }

        return template
    }

    // MARK: - Artist Top Songs

    static func makeArtistTopSongs(artistId: String, artistName: String, coordinator: CarPlayCoordinator) -> CPListTemplate {
        let template = CPListTemplate(title: "Top Songs", sections: [])
        let topSongsQuery = coordinator.library.topSongs(artistId: artistId)

        var queryTask: Task<Void, Never>?
        var isObserving = true

        let rebuild = {
            let songs = coordinator.playableFilter.filterSongs(topSongsQuery.value)
            guard !songs.isEmpty else {
                if topSongsQuery.isLoaded {
                    let isOffline = coordinator.appModel.isOffline
                    template.emptyViewTitleVariants = [isOffline ? "Not available offline" : "No Top Songs"]
                    template.emptyViewSubtitleVariants = [isOffline ? "No top songs are downloaded." : "No top songs available for \(artistName)."]
                    template.updateSections([])
                }
                return
            }

            let playItem = CPListItem(text: "Play", detailText: nil, image: UIImage(systemName: "play.fill"), accessoryImage: nil, accessoryType: .none)
            playItem.userInfo = "top-play"
            playItem.handler = { [weak coordinator] _, completion in
                defer { completion() }
                coordinator?.playSongs(songs, startAt: 0, shuffle: false)
            }

            let shuffleItem = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"), accessoryImage: nil, accessoryType: .none)
            shuffleItem.userInfo = "top-shuffle"
            shuffleItem.handler = { [weak coordinator] _, completion in
                defer { completion() }
                coordinator?.playSongs(songs, shuffle: true)
            }

            var items: [CPListTemplateItem] = [playItem, shuffleItem]
            for (index, song) in songs.enumerated() {
                let item = CPListItem(text: song.title, detailText: song.album, image: nil, accessoryImage: nil, accessoryType: .none)
                item.userInfo = song.id
                item.isPlaying = (song.id == coordinator.player.currentSong?.id)
                item.playingIndicatorLocation = .trailing
                coordinator.registerSongItem(item, songId: song.id)

                item.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    coordinator?.playSongs(songs, startAt: index, shuffle: false)
                }
                items.append(item)
            }

            let clamped = CarPlayItemFactory.clampSections([CPListSection(items: items)])
            if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
                template.updateSections(clamped)
            }
        }

        func observe() {
            guard isObserving else { return }
            withObservationTracking {
                _ = topSongsQuery.value
            } onChange: {
                Task { @MainActor in
                    guard isObserving else { return }
                    rebuild()
                    observe()
                }
            }
        }

        queryTask = Task { await topSongsQuery.run() }
        rebuild()
        observe()

        coordinator.trackDisappearance(of: template) {
            isObserving = false
            queryTask?.cancel()
        }

        return template
    }

    // MARK: - Playlist Detail

    static func makePlaylistDetail(playlistId: String, coordinator: CarPlayCoordinator) -> CPListTemplate {
        let template = CPListTemplate(title: "Playlist", sections: [])
        let playlistQuery = coordinator.library.playlist(id: playlistId)
        let songsQuery = coordinator.library.playlistSongs(id: playlistId)

        var playlistTask: Task<Void, Never>?
        var songsTask: Task<Void, Never>?
        var isObserving = true

        let rebuild = {
            guard let playlist = playlistQuery.value else {
                if playlistQuery.isLoaded {
                    template.emptyViewTitleVariants = ["Playlist Not Found"]
                    template.emptyViewSubtitleVariants = ["This playlist is no longer available in your library."]
                    template.updateSections([])
                }
                return
            }

            template.title = playlist.name
            let songs = coordinator.playableFilter.filterSongs(songsQuery.value)

            if songs.isEmpty {
                let isOffline = coordinator.appModel.isOffline
                template.emptyViewTitleVariants = [isOffline ? "Not available offline" : "No Songs"]
                template.emptyViewSubtitleVariants = [isOffline ? "This playlist has no downloaded songs." : "This playlist is empty."]
                template.updateSections([])
                return
            }

            let playItem = CPListItem(text: "Play", detailText: nil, image: UIImage(systemName: "play.fill"), accessoryImage: nil, accessoryType: .none)
            playItem.userInfo = "playlist-play"
            playItem.handler = { [weak coordinator] _, completion in
                defer { completion() }
                coordinator?.playSongs(songs, startAt: 0, shuffle: false)
            }

            let shuffleItem = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"), accessoryImage: nil, accessoryType: .none)
            shuffleItem.userInfo = "playlist-shuffle"
            shuffleItem.handler = { [weak coordinator] _, completion in
                defer { completion() }
                coordinator?.playSongs(songs, shuffle: true)
            }

            var items: [CPListTemplateItem] = [playItem, shuffleItem]
            for (index, song) in songs.enumerated() {
                let item = CPListItem(text: song.title, detailText: song.artist, image: nil, accessoryImage: nil, accessoryType: .none)
                item.userInfo = song.id
                item.isPlaying = (song.id == coordinator.player.currentSong?.id)
                item.playingIndicatorLocation = .trailing
                coordinator.registerSongItem(item, songId: song.id)

                item.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    coordinator?.playSongs(songs, startAt: index, shuffle: false)
                }
                items.append(item)
            }

            let clamped = CarPlayItemFactory.clampSections([CPListSection(items: items)])
            if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
                template.updateSections(clamped)
            }
        }

        func observe() {
            guard isObserving else { return }
            withObservationTracking {
                _ = playlistQuery.value
                _ = songsQuery.value
            } onChange: {
                Task { @MainActor in
                    guard isObserving else { return }
                    rebuild()
                    observe()
                }
            }
        }

        playlistTask = Task { await playlistQuery.run() }
        songsTask = Task { await songsQuery.run() }
        rebuild()
        observe()

        coordinator.trackDisappearance(of: template) {
            isObserving = false
            playlistTask?.cancel()
            songsTask?.cancel()
        }

        return template
    }

    // MARK: - Genre Detail

    static func makeGenreDetail(genre: String, coordinator: CarPlayCoordinator) -> CPListTemplate {
        let template = CPListTemplate(title: genre, sections: [])
        let albumsQuery = coordinator.library.albums(genre: genre)

        var queryTask: Task<Void, Never>?
        var isObserving = true

        let rebuild = {
            let albums = albumsQuery.value
            if albums.isEmpty {
                if albumsQuery.isLoaded {
                    let isOffline = coordinator.appModel.isOffline
                    template.emptyViewTitleVariants = [isOffline ? "Not available offline" : "No Albums"]
                    template.emptyViewSubtitleVariants = [isOffline ? "No albums in this genre are downloaded." : "No albums found for \(genre)."]
                    template.updateSections([])
                }
                return
            }

            let scale = coordinator.scale
            let targetSize = CPListItem.maximumImageSize

            let items = albums.map { album -> CPListItem in
                let detail = CarPlayItemFactory.albumDetailText(artist: album.artist, year: album.year)
                let item = CPListItem(text: album.name, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
                item.userInfo = album.id

                let initial = coordinator.artwork.loadCover(art: album.coverArt, targetSize: targetSize, scale: scale, placeholderSymbol: "square.stack", for: template) { [weak item] loaded in
                    item?.setImage(loaded)
                }
                item.setImage(initial)

                item.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    guard let coordinator else { return }
                    if coordinator.canPush {
                        let albumDetail = makeAlbumDetail(albumId: album.id, coordinator: coordinator)
                        coordinator.push(albumDetail)
                    } else {
                        coordinator.playAlbum(album, shuffle: false)
                    }
                }
                return item
            }

            let clamped = CarPlayItemFactory.clampSections([CPListSection(items: items)])
            if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
                template.updateSections(clamped)
            }
        }

        func observe() {
            guard isObserving else { return }
            withObservationTracking {
                _ = albumsQuery.value
            } onChange: {
                Task { @MainActor in
                    guard isObserving else { return }
                    rebuild()
                    observe()
                }
            }
        }

        queryTask = Task { await albumsQuery.run() }
        rebuild()
        observe()

        coordinator.trackDisappearance(of: template) {
            isObserving = false
            queryTask?.cancel()
        }

        return template
    }

    // MARK: - Radio Detail

    static func makeRadioDetail(coordinator: CarPlayCoordinator) -> CPListTemplate {
        let template = CPListTemplate(title: "Radio", sections: [])
        let stationsQuery = coordinator.library.radioStations()

        var queryTask: Task<Void, Never>?
        var isObserving = true

        let rebuild = {
            let stations = stationsQuery.value
            if stations.isEmpty {
                if stationsQuery.isLoaded {
                    template.emptyViewTitleVariants = ["No Radio Stations"]
                    template.emptyViewSubtitleVariants = ["Add radio stations on your Navidrome server."]
                    template.updateSections([])
                }
                return
            }

            let radioIcon = UIImage(systemName: "antenna.radiowaves.left.and.right")
            let items = stations.map { station -> CPListItem in
                let item = CPListItem(text: station.name, detailText: "Live Radio", image: radioIcon, accessoryImage: nil, accessoryType: .none)
                item.userInfo = station.id
                item.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    coordinator?.player.playRadio(station)
                    coordinator?.pushNowPlayingIfNeeded()
                }
                return item
            }

            let clamped = CarPlayItemFactory.clampSections([CPListSection(items: items)])
            if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
                template.updateSections(clamped)
            }
        }

        func observe() {
            guard isObserving else { return }
            withObservationTracking {
                _ = stationsQuery.value
            } onChange: {
                Task { @MainActor in
                    guard isObserving else { return }
                    rebuild()
                    observe()
                }
            }
        }

        queryTask = Task { await stationsQuery.run() }
        rebuild()
        observe()

        coordinator.trackDisappearance(of: template) {
            isObserving = false
            queryTask?.cancel()
        }

        return template
    }

    // MARK: - Full Album List (See All)

    static func makeAlbumList(title: String, query: LiveQuery<[Album]>, coordinator: CarPlayCoordinator) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        var queryTask: Task<Void, Never>?
        var isObserving = true

        let rebuild = {
            let albums = query.value
            if albums.isEmpty {
                if query.isLoaded {
                    template.emptyViewTitleVariants = ["No Albums"]
                    template.emptyViewSubtitleVariants = ["No albums found."]
                    template.updateSections([])
                }
                return
            }

            let scale = coordinator.scale
            let targetSize = CPListItem.maximumImageSize

            let items = albums.map { album -> CPListItem in
                let detail = CarPlayItemFactory.albumDetailText(artist: album.artist, year: album.year)
                let item = CPListItem(text: album.name, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
                item.userInfo = album.id

                let initial = coordinator.artwork.loadCover(art: album.coverArt, targetSize: targetSize, scale: scale, placeholderSymbol: "square.stack", for: template) { [weak item] loaded in
                    item?.setImage(loaded)
                }
                item.setImage(initial)

                item.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    guard let coordinator else { return }
                    if coordinator.canPush {
                        let albumDetail = makeAlbumDetail(albumId: album.id, coordinator: coordinator)
                        coordinator.push(albumDetail)
                    } else {
                        coordinator.playAlbum(album, shuffle: false)
                    }
                }
                return item
            }

            let clamped = CarPlayItemFactory.clampSections([CPListSection(items: items)])
            if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
                template.updateSections(clamped)
            }
        }

        func observe() {
            guard isObserving else { return }
            withObservationTracking {
                _ = query.value
            } onChange: {
                Task { @MainActor in
                    guard isObserving else { return }
                    rebuild()
                    observe()
                }
            }
        }

        queryTask = Task { await query.run() }
        rebuild()
        observe()

        coordinator.trackDisappearance(of: template) {
            isObserving = false
            queryTask?.cancel()
        }

        return template
    }

    // MARK: - Letter Pushed Lists

    static func makeLetterSongsList(title: String, songs: [Song], coordinator: CarPlayCoordinator) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        let maxItems = CPListTemplate.maximumItemCount
        let clampedSongs = Array(songs.prefix(maxItems))

        let items = clampedSongs.enumerated().map { (index, song) -> CPListItem in
            let item = CPListItem(text: song.title, detailText: song.artist, image: nil, accessoryImage: nil, accessoryType: .none)
            item.userInfo = song.id
            item.isPlaying = (song.id == coordinator.player.currentSong?.id)
            item.playingIndicatorLocation = .trailing
            coordinator.registerSongItem(item, songId: song.id)

            item.handler = { [weak coordinator] _, completion in
                defer { completion() }
                coordinator?.playSongs(clampedSongs, startAt: index, shuffle: false)
            }
            return item
        }

        template.updateSections([CPListSection(items: items)])
        return template
    }

    static func makeLetterAlbumsList(title: String, albums: [Album], coordinator: CarPlayCoordinator) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        let maxItems = CPListTemplate.maximumItemCount
        let clampedAlbums = Array(albums.prefix(maxItems))
        let scale = coordinator.scale
        let targetSize = CPListItem.maximumImageSize

        let items = clampedAlbums.map { album -> CPListItem in
            let detail = CarPlayItemFactory.albumDetailText(artist: album.artist, year: album.year)
            let item = CPListItem(text: album.name, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
            item.userInfo = album.id

            let initial = coordinator.artwork.loadCover(art: album.coverArt, targetSize: targetSize, scale: scale, placeholderSymbol: "square.stack", for: template) { [weak item] loaded in
                item?.setImage(loaded)
            }
            item.setImage(initial)

            item.handler = { [weak coordinator] _, completion in
                defer { completion() }
                guard let coordinator else { return }
                if coordinator.canPush {
                    let albumDetail = makeAlbumDetail(albumId: album.id, coordinator: coordinator)
                    coordinator.push(albumDetail)
                } else {
                    coordinator.playAlbum(album, shuffle: false)
                }
            }
            return item
        }

        template.updateSections([CPListSection(items: items)])
        return template
    }

    static func makeLetterArtistsList(title: String, artists: [Artist], coordinator: CarPlayCoordinator) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        let maxItems = CPListTemplate.maximumItemCount
        let clampedArtists = Array(artists.prefix(maxItems))
        let scale = coordinator.scale
        let targetSize = CPListItem.maximumImageSize

        let items = clampedArtists.map { artist -> CPListItem in
            let count = artist.albumCount ?? 0
            let detail = count > 0 ? (count == 1 ? "1 album" : "\(count) albums") : nil
            let item = CPListItem(text: artist.name, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
            item.userInfo = artist.id

            let initial = coordinator.artwork.loadCover(art: artist.coverArt, targetSize: targetSize, scale: scale, placeholderSymbol: "person.crop.circle", for: template) { [weak item] loaded in
                item?.setImage(loaded)
            }
            item.setImage(initial)

            item.handler = { [weak coordinator] _, completion in
                defer { completion() }
                guard let coordinator else { return }
                if coordinator.canPush {
                    let artistDetail = makeArtistDetail(artistId: artist.id, coordinator: coordinator)
                    coordinator.push(artistDetail)
                } else {
                    coordinator.playArtist(artist, shuffle: false)
                }
            }
            return item
        }

        template.updateSections([CPListSection(items: items)])
        return template
    }
}
