import CarPlay
import Foundation
import UIKit

/// Manages the "Listen Now" CarPlay tab.
@MainActor
final class CarPlayListenNowTab {
    let template: CPListTemplate
    private weak var coordinator: CarPlayCoordinator?

    private var recentQuery: LiveQuery<[Album]>?
    private var newestQuery: LiveQuery<[Album]>?
    private var frequentQuery: LiveQuery<[Album]>?

    private var recentTask: Task<Void, Never>?
    private var newestTask: Task<Void, Never>?
    private var frequentTask: Task<Void, Never>?

    private var isObserving = false

    init(coordinator: CarPlayCoordinator) {
        self.coordinator = coordinator
        self.template = CPListTemplate(title: "Listen Now", sections: [])
        self.template.tabTitle = "Listen Now"
        self.template.tabImage = UIImage(systemName: "play.circle.fill")
    }

    func start() {
        guard !isObserving, let coordinator else { return }
        isObserving = true

        recentQuery = coordinator.library.homeList(.recent)
        newestQuery = coordinator.library.homeList(.newest)
        frequentQuery = coordinator.library.homeList(.frequent)

        if let recentQuery { recentTask = Task { await recentQuery.run() } }
        if let newestQuery { newestTask = Task { await newestQuery.run() } }
        if let frequentQuery { frequentTask = Task { await frequentQuery.run() } }

        rebuildSections()
        observe()
    }

    func stop() {
        isObserving = false
        recentTask?.cancel()
        newestTask?.cancel()
        frequentTask?.cancel()
        recentTask = nil
        newestTask = nil
        frequentTask = nil
    }

    func rebuildSections() {
        guard let coordinator else { return }
        let scale = coordinator.scale
        let isOffline = coordinator.appModel.isOffline

        var recent = recentQuery?.value ?? []
        var newest = newestQuery?.value ?? []
        var frequent = frequentQuery?.value ?? []

        if isOffline {
            Task { [weak self] in
                guard let self, let coordinator = self.coordinator else { return }
                let playableIds = await coordinator.playableFilter.fetchPlayableAlbumIds()
                self.applySections(
                    recent: recent.filter { playableIds.contains($0.id) },
                    newest: newest.filter { playableIds.contains($0.id) },
                    frequent: frequent.filter { playableIds.contains($0.id) },
                    scale: scale
                )
            }
        } else {
            applySections(recent: recent, newest: newest, frequent: frequent, scale: scale)
        }
    }

    private func applySections(recent: [Album], newest: [Album], frequent: [Album], scale: CGFloat) {
        guard let coordinator else { return }
        var sections: [CPListSection] = []

        // Section 1: Recently Played Image Row
        if !recent.isEmpty {
            let recentAlbums = Array(recent.prefix(8))
            let rowTargetSize = CPListImageRowItem.maximumImageSize

            var images = recentAlbums.map { album -> UIImage in
                coordinator.artwork.placeholder(symbol: "square.stack", targetSize: rowTargetSize, scale: scale)
            }

            let imageRow = CPListImageRowItem(text: "Recently Played", images: images)
            imageRow.userInfo = "recently-played-row"

            imageRow.handler = { [weak coordinator, weak self] _, completion in
                defer { completion() }
                guard let coordinator, let recentQuery = self?.recentQuery else { return }
                if coordinator.canPush {
                    let list = CarPlayDetailTemplates.makeAlbumList(title: "Recently Played", query: recentQuery, coordinator: coordinator)
                    coordinator.push(list)
                }
            }

            imageRow.listImageRowHandler = { [weak coordinator] _, index, completion in
                defer { completion() }
                guard let coordinator, recentAlbums.indices.contains(index) else { return }
                let album = recentAlbums[index]
                if coordinator.canPush {
                    let detail = CarPlayDetailTemplates.makeAlbumDetail(albumId: album.id, coordinator: coordinator)
                    coordinator.push(detail)
                } else {
                    coordinator.playAlbum(album, shuffle: false)
                }
            }

            for (index, album) in recentAlbums.enumerated() {
                _ = coordinator.artwork.loadCover(art: album.coverArt, targetSize: rowTargetSize, scale: scale, placeholderSymbol: "square.stack", for: template) { [weak imageRow] loaded in
                    guard let imageRow, images.indices.contains(index) else { return }
                    images[index] = loaded
                    imageRow.update(images)
                }
            }

            sections.append(CPListSection(items: [imageRow]))
        }

        // Section 2: Mixes
        let shuffleAllItem = CPListItem(text: "Shuffle All", detailText: nil, image: UIImage(systemName: "shuffle"), accessoryImage: nil, accessoryType: .none)
        shuffleAllItem.userInfo = "mix-shuffle-all"
        shuffleAllItem.handler = { [weak coordinator] _, completion in
            defer { completion() }
            coordinator?.shuffleLibrary()
        }

        let favoritesItem = CPListItem(text: "Favorites", detailText: nil, image: UIImage(systemName: "heart.fill"), accessoryImage: nil, accessoryType: .none)
        favoritesItem.userInfo = "mix-favorites"
        favoritesItem.handler = { [weak coordinator] _, completion in
            defer { completion() }
            coordinator?.playFavoriteSongs()
        }

        let downloadedItem = CPListItem(text: "Downloaded", detailText: nil, image: UIImage(systemName: "arrow.down.circle.fill"), accessoryImage: nil, accessoryType: .none)
        downloadedItem.userInfo = "mix-downloaded"
        downloadedItem.handler = { [weak coordinator] _, completion in
            defer { completion() }
            coordinator?.playDownloadedSongs()
        }

        sections.append(CPListSection(items: [shuffleAllItem, favoritesItem, downloadedItem], header: "Mixes", sectionIndexTitle: nil))

        // Section 3: Recently Added
        let itemTargetSize = CPListItem.maximumImageSize
        if !newest.isEmpty {
            let slice = Array(newest.prefix(10))
            var newestItems: [CPListTemplateItem] = slice.map { album -> CPListItem in
                let detail = CarPlayItemFactory.albumDetailText(artist: album.artist, year: album.year)
                let item = CPListItem(text: album.name, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
                item.userInfo = album.id

                let initial = coordinator.artwork.loadCover(art: album.coverArt, targetSize: itemTargetSize, scale: scale, placeholderSymbol: "square.stack", for: template) { [weak item] loaded in
                    item?.setImage(loaded)
                }
                item.setImage(initial)

                item.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    guard let coordinator else { return }
                    if coordinator.canPush {
                        let detailTemplate = CarPlayDetailTemplates.makeAlbumDetail(albumId: album.id, coordinator: coordinator)
                        coordinator.push(detailTemplate)
                    } else {
                        coordinator.playAlbum(album, shuffle: false)
                    }
                }
                return item
            }

            if newest.count > 10, let newestQuery {
                let seeAll = CPListItem(text: "See All", detailText: "\(newest.count) albums", image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
                seeAll.userInfo = "newest-see-all"
                seeAll.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    guard let coordinator else { return }
                    if coordinator.canPush {
                        let list = CarPlayDetailTemplates.makeAlbumList(title: "Recently Added", query: newestQuery, coordinator: coordinator)
                        coordinator.push(list)
                    }
                }
                newestItems.append(seeAll)
            }

            sections.append(CPListSection(items: newestItems, header: "Recently Added", sectionIndexTitle: nil))
        }

        // Section 4: Most Played
        if !frequent.isEmpty {
            let slice = Array(frequent.prefix(10))
            var frequentItems: [CPListTemplateItem] = slice.map { album -> CPListItem in
                let detail = CarPlayItemFactory.albumDetailText(artist: album.artist, year: album.year)
                let item = CPListItem(text: album.name, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
                item.userInfo = album.id

                let initial = coordinator.artwork.loadCover(art: album.coverArt, targetSize: itemTargetSize, scale: scale, placeholderSymbol: "square.stack", for: template) { [weak item] loaded in
                    item?.setImage(loaded)
                }
                item.setImage(initial)

                item.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    guard let coordinator else { return }
                    if coordinator.canPush {
                        let detailTemplate = CarPlayDetailTemplates.makeAlbumDetail(albumId: album.id, coordinator: coordinator)
                        coordinator.push(detailTemplate)
                    } else {
                        coordinator.playAlbum(album, shuffle: false)
                    }
                }
                return item
            }

            if frequent.count > 10, let frequentQuery {
                let seeAll = CPListItem(text: "See All", detailText: "\(frequent.count) albums", image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
                seeAll.userInfo = "frequent-see-all"
                seeAll.handler = { [weak coordinator] _, completion in
                    defer { completion() }
                    guard let coordinator else { return }
                    if coordinator.canPush {
                        let list = CarPlayDetailTemplates.makeAlbumList(title: "Most Played", query: frequentQuery, coordinator: coordinator)
                        coordinator.push(list)
                    }
                }
                frequentItems.append(seeAll)
            }

            sections.append(CPListSection(items: frequentItems, header: "Most Played", sectionIndexTitle: nil))
        }

        let clamped = CarPlayItemFactory.clampSections(sections)
        if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
            template.updateSections(clamped)
        }
    }

    private func observe() {
        guard isObserving else { return }
        withObservationTracking {
            _ = recentQuery?.value
            _ = newestQuery?.value
            _ = frequentQuery?.value
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.rebuildSections()
                self.observe()
            }
        }
    }
}
