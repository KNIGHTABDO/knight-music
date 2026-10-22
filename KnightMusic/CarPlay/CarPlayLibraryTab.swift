import CarPlay
import Foundation
import UIKit

/// Manages the "Library" CarPlay tab.
@MainActor
final class CarPlayLibraryTab {
    let template: CPListTemplate
    private weak var coordinator: CarPlayCoordinator?

    private var radioQuery: LiveQuery<[RadioStation]>?
    private var radioTask: Task<Void, Never>?
    private var isObserving = false

    init(coordinator: CarPlayCoordinator) {
        self.coordinator = coordinator
        self.template = CPListTemplate(title: "Library", sections: [])
        self.template.tabTitle = "Library"
        self.template.tabImage = UIImage(systemName: "square.stack.fill")
    }

    func start() {
        guard !isObserving, let coordinator else { return }
        isObserving = true

        radioQuery = coordinator.library.radioStations()
        if let radioQuery {
            radioTask = Task { await radioQuery.run() }
        }

        rebuildSections()
        observe()
    }

    func stop() {
        isObserving = false
        radioTask?.cancel()
        radioTask = nil
    }

    func rebuildSections() {
        guard let coordinator else { return }
        var items: [CPListTemplateItem] = []

        // 1. Artists
        let artistsItem = CPListItem(text: "Artists", detailText: nil, image: UIImage(systemName: "music.mic"), accessoryImage: nil, accessoryType: .disclosureIndicator)
        artistsItem.userInfo = "lib-artists"
        artistsItem.handler = { [weak self] _, completion in
            defer { completion() }
            self?.pushArtists()
        }
        items.append(artistsItem)

        // 2. Albums
        let albumsItem = CPListItem(text: "Albums", detailText: nil, image: UIImage(systemName: "square.stack"), accessoryImage: nil, accessoryType: .disclosureIndicator)
        albumsItem.userInfo = "lib-albums"
        albumsItem.handler = { [weak self] _, completion in
            defer { completion() }
            self?.pushAlbums()
        }
        items.append(albumsItem)

        // 3. Songs (favorites)
        let songsItem = CPListItem(text: "Songs", detailText: nil, image: UIImage(systemName: "music.note"), accessoryImage: nil, accessoryType: .disclosureIndicator)
        songsItem.userInfo = "lib-songs"
        songsItem.handler = { [weak self] _, completion in
            defer { completion() }
            self?.pushSongs()
        }
        items.append(songsItem)

        // 4. Genres
        let genresItem = CPListItem(text: "Genres", detailText: nil, image: UIImage(systemName: "guitars"), accessoryImage: nil, accessoryType: .disclosureIndicator)
        genresItem.userInfo = "lib-genres"
        genresItem.handler = { [weak self] _, completion in
            defer { completion() }
            self?.pushGenres()
        }
        items.append(genresItem)

        // 5. Radio (only if any stations and not offline)
        let radioStations = radioQuery?.value ?? []
        if !radioStations.isEmpty && !coordinator.appModel.isOffline {
            let radioItem = CPListItem(text: "Radio", detailText: nil, image: UIImage(systemName: "antenna.radiowaves.left.and.right"), accessoryImage: nil, accessoryType: .disclosureIndicator)
            radioItem.userInfo = "lib-radio"
            radioItem.handler = { [weak self] _, completion in
                defer { completion() }
                self?.pushRadio()
            }
            items.append(radioItem)
        }

        let section = CPListSection(items: items)
        let clamped = CarPlayItemFactory.clampSections([section])
        if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
            template.updateSections(clamped)
        }
    }

    func pushArtists() {
        guard let coordinator, coordinator.canPush else { return }
        Task { @MainActor in
            let artists = await coordinator.library.artists().load()

            if coordinator.appModel.isOffline {
                Task { [weak self, weak coordinator] in
                    guard let coordinator else { return }
                    let playableIds = await coordinator.playableFilter.fetchPlayableArtistIds()
                    let filtered = artists.filter { playableIds.contains($0.id) }
                    self?.presentArtistsList(filtered, coordinator: coordinator)
                }
            } else {
                presentArtistsList(artists, coordinator: coordinator)
            }
        }
    }

    private func presentArtistsList(_ artists: [Artist], coordinator: CarPlayCoordinator) {
        let template = CPListTemplate(title: "Artists", sections: [])
        if artists.isEmpty {
            let isOffline = coordinator.appModel.isOffline
            template.emptyViewTitleVariants = [isOffline ? "Not available offline" : "No Artists"]
            template.emptyViewSubtitleVariants = [isOffline ? "No artists have downloaded music." : "Your artist library is empty."]
            coordinator.push(template)
            return
        }

        let maxItems = CPListTemplate.maximumItemCount
        let maxSections = CPListTemplate.maximumSectionCount
        let grouped = Dictionary(grouping: artists, by: { CarPlayItemFactory.letterBucket(for: $0.name) })
        let sortedLetters = CarPlayItemFactory.sortLetters(Array(grouped.keys))

        if artists.count <= maxItems && sortedLetters.count <= maxSections {
            // A–Z Sections
            let scale = coordinator.scale
            let targetSize = CPListItem.maximumImageSize

            var sections: [CPListSection] = []
            for letter in sortedLetters {
                guard let letterArtists = grouped[letter] else { continue }
                let items = letterArtists.map { artist -> CPListItem in
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
                            let detail = CarPlayDetailTemplates.makeArtistDetail(artistId: artist.id, coordinator: coordinator)
                            coordinator.push(detail)
                        } else {
                            coordinator.playArtist(artist, shuffle: false)
                        }
                    }
                    return item
                }
                sections.append(CPListSection(items: items, header: letter, sectionIndexTitle: letter))
            }
            template.updateSections(CarPlayItemFactory.clampSections(sections))
        } else {
            // Letter List
            var letterItems: [CPListTemplateItem] = []
            for letter in sortedLetters {
                guard let letterArtists = grouped[letter] else { continue }
                let count = letterArtists.count
                let detail = count == 1 ? "1 artist" : "\(count) artists"
                let item = CPListItem(text: letter, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
                item.userInfo = "letter-\(letter)"
                item.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    guard let coordinator, coordinator.canPush else { return }
                    let letterTemplate = CarPlayDetailTemplates.makeLetterArtistsList(title: letter, artists: letterArtists, coordinator: coordinator)
                    coordinator.push(letterTemplate)
                }
                letterItems.append(item)
            }
            template.updateSections(CarPlayItemFactory.clampSections([CPListSection(items: letterItems)]))
        }

        coordinator.push(template)
    }

    func pushAlbums() {
        guard let coordinator, coordinator.canPush else { return }
        Task { @MainActor in
            let albums = await coordinator.library.albums(sort: .name).load()

            if coordinator.appModel.isOffline {
                Task { [weak self, weak coordinator] in
                    guard let coordinator else { return }
                    let playableIds = await coordinator.playableFilter.fetchPlayableAlbumIds()
                    let filtered = albums.filter { playableIds.contains($0.id) }
                    self?.presentAlbumsList(filtered, coordinator: coordinator)
                }
            } else {
                presentAlbumsList(albums, coordinator: coordinator)
            }
        }
    }

    private func presentAlbumsList(_ albums: [Album], coordinator: CarPlayCoordinator) {
        let template = CPListTemplate(title: "Albums", sections: [])
        if albums.isEmpty {
            let isOffline = coordinator.appModel.isOffline
            template.emptyViewTitleVariants = [isOffline ? "Not available offline" : "No Albums"]
            template.emptyViewSubtitleVariants = [isOffline ? "No albums have downloaded music." : "Your album library is empty."]
            coordinator.push(template)
            return
        }

        let maxItems = CPListTemplate.maximumItemCount
        let maxSections = CPListTemplate.maximumSectionCount
        let grouped = Dictionary(grouping: albums, by: { CarPlayItemFactory.letterBucket(for: $0.name) })
        let sortedLetters = CarPlayItemFactory.sortLetters(Array(grouped.keys))

        if albums.count <= maxItems && sortedLetters.count <= maxSections {
            // A–Z Sections
            let scale = coordinator.scale
            let targetSize = CPListItem.maximumImageSize

            var sections: [CPListSection] = []
            for letter in sortedLetters {
                guard let letterAlbums = grouped[letter] else { continue }
                let items = letterAlbums.map { album -> CPListItem in
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
                            let detail = CarPlayDetailTemplates.makeAlbumDetail(albumId: album.id, coordinator: coordinator)
                            coordinator.push(detail)
                        } else {
                            coordinator.playAlbum(album, shuffle: false)
                        }
                    }
                    return item
                }
                sections.append(CPListSection(items: items, header: letter, sectionIndexTitle: letter))
            }
            template.updateSections(CarPlayItemFactory.clampSections(sections))
        } else {
            // Letter List
            var letterItems: [CPListTemplateItem] = []
            for letter in sortedLetters {
                guard let letterAlbums = grouped[letter] else { continue }
                let count = letterAlbums.count
                let detail = count == 1 ? "1 album" : "\(count) albums"
                let item = CPListItem(text: letter, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
                item.userInfo = "letter-\(letter)"
                item.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    guard let coordinator, coordinator.canPush else { return }
                    let letterTemplate = CarPlayDetailTemplates.makeLetterAlbumsList(title: letter, albums: letterAlbums, coordinator: coordinator)
                    coordinator.push(letterTemplate)
                }
                letterItems.append(item)
            }
            template.updateSections(CarPlayItemFactory.clampSections([CPListSection(items: letterItems)]))
        }

        coordinator.push(template)
    }

    private func pushSongs() {
        guard let coordinator, coordinator.canPush else { return }
        Task { @MainActor in
            let favoriteSongs = await coordinator.library.favoriteSongs().load()
            let songs = coordinator.playableFilter.filterSongs(favoriteSongs)
            let template = CPListTemplate(title: "Songs", sections: [])

            if songs.isEmpty {
                let isOffline = coordinator.appModel.isOffline
                template.emptyViewTitleVariants = [isOffline ? "Not available offline" : "No Favorite Songs"]
                template.emptyViewSubtitleVariants = [isOffline ? "No favorite songs are downloaded." : "Favorite songs on your iPhone to see them here."]
                coordinator.push(template)
                return
            }

            let maxItems = CPListTemplate.maximumItemCount
            let maxSections = CPListTemplate.maximumSectionCount
            let grouped = Dictionary(grouping: songs, by: { CarPlayItemFactory.letterBucket(for: $0.title) })
            let sortedLetters = CarPlayItemFactory.sortLetters(Array(grouped.keys))

            if songs.count <= maxItems && sortedLetters.count <= maxSections {
                // A–Z Sections
                var sections: [CPListSection] = []
                for letter in sortedLetters {
                    guard let letterSongs = grouped[letter] else { continue }
                    let items = letterSongs.map { song -> CPListItem in
                        let item = CPListItem(text: song.title, detailText: song.artist, image: nil, accessoryImage: nil, accessoryType: .none)
                        item.userInfo = song.id
                        item.isPlaying = (song.id == coordinator.player.currentSong?.id)
                        item.playingIndicatorLocation = .trailing
                        coordinator.registerSongItem(item, songId: song.id)

                        item.handler = { [weak coordinator] _, completion in
                            defer { completion() }
                            if let index = songs.firstIndex(where: { $0.id == song.id }) {
                                coordinator?.playSongs(songs, startAt: index, shuffle: false)
                            }
                        }
                        return item
                    }
                    sections.append(CPListSection(items: items, header: letter, sectionIndexTitle: letter))
                }
                template.updateSections(CarPlayItemFactory.clampSections(sections))
            } else {
                // Letter List
                var letterItems: [CPListTemplateItem] = []
                for letter in sortedLetters {
                    guard let letterSongs = grouped[letter] else { continue }
                    let count = letterSongs.count
                    let detail = count == 1 ? "1 song" : "\(count) songs"
                    let item = CPListItem(text: letter, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
                    item.userInfo = "letter-\(letter)"
                    item.handler = { [weak coordinator] _, completion in
                        defer { completion() }
                        guard let coordinator, coordinator.canPush else { return }
                        let letterTemplate = CarPlayDetailTemplates.makeLetterSongsList(title: letter, songs: letterSongs, coordinator: coordinator)
                        coordinator.push(letterTemplate)
                    }
                    letterItems.append(item)
                }
                template.updateSections(CarPlayItemFactory.clampSections([CPListSection(items: letterItems)]))
            }

            coordinator.push(template)
        }
    }

    private func pushGenres() {
        guard let coordinator, coordinator.canPush else { return }
        Task { @MainActor in
            let genres = await coordinator.library.genres().load()
            let template = CPListTemplate(title: "Genres", sections: [])

            if genres.isEmpty {
                let isOffline = coordinator.appModel.isOffline
                template.emptyViewTitleVariants = [isOffline ? "Not available offline" : "No Genres"]
                template.emptyViewSubtitleVariants = ["No music genres found in your library."]
                coordinator.push(template)
                return
            }

            let items = genres.map { genre -> CPListItem in
                let count = genre.albumCount ?? 0
                let detail = count == 1 ? "1 album" : "\(count) albums"
                let item = CPListItem(text: genre.value, detailText: detail, image: UIImage(systemName: "guitars"), accessoryImage: nil, accessoryType: .disclosureIndicator)
                item.userInfo = genre.id

                item.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    guard let coordinator, coordinator.canPush else { return }
                    let genreDetail = CarPlayDetailTemplates.makeGenreDetail(genre: genre.value, coordinator: coordinator)
                    coordinator.push(genreDetail)
                }
                return item
            }

            template.updateSections(CarPlayItemFactory.clampSections([CPListSection(items: items)]))
            coordinator.push(template)
        }
    }

    private func pushRadio() {
        guard let coordinator, coordinator.canPush else { return }
        let radioDetail = CarPlayDetailTemplates.makeRadioDetail(coordinator: coordinator)
        coordinator.push(radioDetail)
    }

    private func observe() {
        guard isObserving else { return }
        withObservationTracking {
            _ = radioQuery?.value
            _ = coordinator?.appModel.isOffline
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.rebuildSections()
                self.observe()
            }
        }
    }
}
