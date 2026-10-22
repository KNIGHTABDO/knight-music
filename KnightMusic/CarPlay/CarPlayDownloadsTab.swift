import CarPlay
import Foundation
import UIKit

/// Manages the "Downloads" CarPlay tab.
@MainActor
final class CarPlayDownloadsTab {
    let template: CPListTemplate
    private weak var coordinator: CarPlayCoordinator?

    private var downloadedQuery: LiveQuery<[Song]>?
    private var downloadedTask: Task<Void, Never>?
    private var isObserving = false

    init(coordinator: CarPlayCoordinator) {
        self.coordinator = coordinator
        self.template = CPListTemplate(title: "Downloads", sections: [])
        self.template.tabTitle = "Downloads"
        self.template.tabImage = UIImage(systemName: "arrow.down.circle.fill")
        self.template.emptyViewTitleVariants = ["No downloads"]
        self.template.emptyViewSubtitleVariants = ["Download music on your iPhone to play it anywhere."]
    }

    func start() {
        guard !isObserving, let coordinator else { return }
        isObserving = true

        downloadedQuery = coordinator.library.downloadedSongs()
        if let downloadedQuery {
            downloadedTask = Task { await downloadedQuery.run() }
        }

        rebuildSections()
        observe()
    }

    func stop() {
        isObserving = false
        downloadedTask?.cancel()
        downloadedTask = nil
    }

    func rebuildSections() {
        guard let coordinator else { return }
        let songs = downloadedQuery?.value ?? []

        if songs.isEmpty {
            template.emptyViewTitleVariants = ["No downloads"]
            template.emptyViewSubtitleVariants = ["Download music on your iPhone to play it anywhere."]
            if !template.sections.isEmpty {
                template.updateSections([])
            }
            return
        }

        let shuffleItem = CPListItem(text: "Shuffle", detailText: "\(songs.count) songs", image: UIImage(systemName: "shuffle"), accessoryImage: nil, accessoryType: .none)
        shuffleItem.userInfo = "downloads-shuffle"
        shuffleItem.handler = { [weak coordinator] _, completion in
            defer { completion() }
            coordinator?.playSongs(songs, shuffle: true)
        }

        let maxItems = CPListTemplate.maximumItemCount
        let maxSections = CPListTemplate.maximumSectionCount
        let grouped = Dictionary(grouping: songs, by: { CarPlayItemFactory.letterBucket(for: $0.title) })
        let sortedLetters = CarPlayItemFactory.sortLetters(Array(grouped.keys))

        var sections: [CPListSection] = []

        if (songs.count + 1) <= maxItems && (sortedLetters.count + 1) <= maxSections {
            // A–Z Sections
            sections.append(CPListSection(items: [shuffleItem]))

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
        } else {
            // Letter List
            var letterItems: [CPListTemplateItem] = [shuffleItem]

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
            sections.append(CPListSection(items: letterItems))
        }

        let clamped = CarPlayItemFactory.clampSections(sections)
        if !CarPlayItemFactory.areSectionsEqual(template.sections, clamped) {
            template.updateSections(clamped)
        }
    }

    private func observe() {
        guard isObserving else { return }
        withObservationTracking {
            _ = downloadedQuery?.value
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.rebuildSections()
                self.observe()
            }
        }
    }
}
