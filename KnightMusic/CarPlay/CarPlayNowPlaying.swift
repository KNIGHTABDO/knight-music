import CarPlay
import Foundation
import UIKit

/// Manages CPNowPlayingTemplate.shared configuration, button states and the Up Next queue template.
@MainActor
final class CarPlayNowPlaying {
    private weak var coordinator: CarPlayCoordinator?
    private var isObserving = false

    init(coordinator: CarPlayCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        update()
        observePlayer()
    }

    func stop() {
        isObserving = false
    }

    /// Rebuilds Now Playing buttons and controls to match the current engine state.
    func update() {
        guard let coordinator else { return }
        let player = coordinator.player
        let template = CPNowPlayingTemplate.shared

        if player.currentRadio != nil {
            template.updateNowPlayingButtons([])
            template.isUpNextButtonEnabled = false
            template.isAlbumArtistButtonEnabled = false
            return
        }

        let isStarred = (player.currentSong?.starred != nil)
        let heartSymbol = isStarred ? "heart.fill" : "heart"
        let heartImage = UIImage(systemName: heartSymbol) ?? UIImage()

        let favoriteButton = CPNowPlayingImageButton(image: heartImage) { [weak self] _ in
            self?.coordinator?.player.toggleStarCurrent()
        }
        favoriteButton.isSelected = isStarred
        favoriteButton.isEnabled = (player.currentSong != nil)

        let shuffleButton = CPNowPlayingShuffleButton { [weak self] _ in
            self?.coordinator?.player.toggleShuffle()
        }

        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            self?.coordinator?.player.cycleRepeat()
        }

        template.updateNowPlayingButtons([shuffleButton, repeatButton, favoriteButton])
        template.isUpNextButtonEnabled = !player.upcoming.isEmpty
        template.upNextTitle = "Up Next"
        template.isAlbumArtistButtonEnabled = (player.currentSong?.albumId != nil)
    }

    /// Creates the Up Next queue list template.
    func makeUpNextTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Up Next", sections: [])
        guard let coordinator else { return template }
        let player = coordinator.player

        var items: [CPListTemplateItem] = []

        if let current = player.currentSong {
            let currentItem = CPListItem(text: current.title, detailText: current.artist, image: nil, accessoryImage: nil, accessoryType: .none)
            currentItem.userInfo = current.id
            currentItem.isPlaying = true
            currentItem.playingIndicatorLocation = .trailing
            coordinator.registerSongItem(currentItem, songId: current.id)

            currentItem.handler = { [weak self] _, completion in
                defer { completion() }
                self?.coordinator?.player.skip(to: self?.coordinator?.player.currentIndex ?? 0)
            }
            items.append(currentItem)
        }

        for (offset, entry) in player.upcoming.enumerated() {
            let indexInOrder = player.currentIndex + 1 + offset
            let item = CPListItem(text: entry.song.title, detailText: entry.song.artist, image: nil, accessoryImage: nil, accessoryType: .none)
            item.userInfo = entry.song.id
            item.isPlaying = false
            item.playingIndicatorLocation = .trailing
            coordinator.registerSongItem(item, songId: entry.song.id)

            item.handler = { [weak self] _, completion in
                defer { completion() }
                self?.coordinator?.player.skip(to: indexInOrder)
            }
            items.append(item)
        }

        let clamped = CarPlayItemFactory.clampSections([CPListSection(items: items)])
        template.updateSections(clamped)
        return template
    }

    private func observePlayer() {
        guard isObserving, let coordinator else { return }
        withObservationTracking {
            _ = coordinator.player.currentSong?.id
            _ = coordinator.player.currentSong?.starred
            _ = coordinator.player.currentRadio
            _ = coordinator.player.upcoming.count
            _ = coordinator.player.shuffleEnabled
            _ = coordinator.player.repeatMode
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.update()
                self.observePlayer()
            }
        }
    }
}
