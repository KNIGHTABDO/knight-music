import CarPlay
import Foundation
import UIKit

/// Manages the "Playlists" CarPlay tab.
@MainActor
final class CarPlayPlaylistsTab {
    let template: CPListTemplate
    private weak var coordinator: CarPlayCoordinator?

    private var playlistsQuery: LiveQuery<[Playlist]>?
    private var playlistsTask: Task<Void, Never>?
    private var isObserving = false

    init(coordinator: CarPlayCoordinator) {
        self.coordinator = coordinator
        self.template = CPListTemplate(title: "Playlists", sections: [])
        self.template.tabTitle = "Playlists"
        self.template.tabImage = UIImage(systemName: "music.note.list")
    }

    func start() {
        guard !isObserving, let coordinator else { return }
        isObserving = true

        playlistsQuery = coordinator.library.playlists()
        if let playlistsQuery {
            playlistsTask = Task { await playlistsQuery.run() }
        }

        rebuildSections()
        observe()
    }

    func stop() {
        isObserving = false
        playlistsTask?.cancel()
        playlistsTask = nil
    }

    func rebuildSections() {
        guard let coordinator else { return }
        let playlists = playlistsQuery?.value ?? []
        let scale = coordinator.scale
        let isOffline = coordinator.appModel.isOffline

        if isOffline {
            Task { [weak self] in
                guard let self, let coordinator = self.coordinator else { return }
                let playableIds = await coordinator.playableFilter.fetchPlayablePlaylistIds()
                let filtered = playlists.filter { playableIds.contains($0.id) }
                self.applySections(playlists: filtered, scale: scale, isOffline: true)
            }
        } else {
            applySections(playlists: playlists, scale: scale, isOffline: false)
        }
    }

    private func applySections(playlists: [Playlist], scale: CGFloat, isOffline: Bool) {
        guard let coordinator else { return }

        if playlists.isEmpty {
            template.emptyViewTitleVariants = [isOffline ? "Not available offline" : "No Playlists"]
            template.emptyViewSubtitleVariants = [isOffline ? "No playlists have downloaded songs." : "Create playlists on your iPhone or server."]
            if !template.sections.isEmpty {
                template.updateSections([])
            }
            return
        }

        let targetSize = CPListItem.maximumImageSize
        let items = playlists.map { playlist -> CPListItem in
            let detail = CarPlayItemFactory.playlistDetailText(songCount: playlist.songCount)
            let item = CPListItem(text: playlist.name, detailText: detail, image: nil, accessoryImage: nil, accessoryType: .disclosureIndicator)
            item.userInfo = playlist.id

            let initial = coordinator.artwork.loadCover(art: playlist.coverArt, targetSize: targetSize, scale: scale, placeholderSymbol: "music.note.list", for: template) { [weak item] loaded in
                item?.setImage(loaded)
            }
            item.setImage(initial)

            item.handler = { [weak coordinator] _, completion in
                defer { completion() }
                guard let coordinator else { return }
                if coordinator.canPush {
                    let detailTemplate = CarPlayDetailTemplates.makePlaylistDetail(playlistId: playlist.id, coordinator: coordinator)
                    coordinator.push(detailTemplate)
                } else {
                    coordinator.playPlaylist(playlist, shuffle: false)
                }
            }
            return item
        }

        let clamped = CarPlayItemFactory.clampSections([CPListSection(items: items)])
        if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
            template.updateSections(clamped)
        }
    }

    private func observe() {
        guard isObserving else { return }
        withObservationTracking {
            _ = playlistsQuery?.value
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
