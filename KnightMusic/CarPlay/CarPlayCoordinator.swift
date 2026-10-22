import CarPlay
import Foundation
import UIKit

/// Root coordinator managing CarPlay navigation, tab bar, observers, playback and template depth.
@MainActor
final class CarPlayCoordinator: NSObject, CPInterfaceControllerDelegate, CPNowPlayingTemplateObserver {
    weak var interfaceController: CPInterfaceController?
    let appModel: AppModel

    var player: PlayerEngine { appModel.player }
    var library: LibraryRepository { appModel.library }
    let artwork = CarPlayArtwork.shared
    let playableFilter: CarPlayPlayableFilter

    private(set) var listenNowTab: CarPlayListenNowTab?
    private(set) var libraryTab: CarPlayLibraryTab?
    private(set) var playlistsTab: CarPlayPlaylistsTab?
    private(set) var downloadsTab: CarPlayDownloadsTab?
    private(set) var tabBarTemplate: CPTabBarTemplate?
    private(set) var nowPlaying: CarPlayNowPlaying?

    private var songItemMap: [String: [CarPlayWeakBox<CPListItem>]] = [:]
    private var disappearanceHandlers: [ObjectIdentifier: () -> Void] = [:]

    private var isStarted = false
    private var isShowingTabBar = false
    private var lastHandledRevision = -1

    var scale: CGFloat {
        let carScale = interfaceController?.carTraitCollection.displayScale ?? 0
        if carScale > 0 { return carScale }
        let mainScale = UIScreen.main.scale
        return mainScale > 0 ? mainScale : 2.0
    }

    /// Root counts as 1, Apple caps at 5, and Now Playing can be pushed on top -> never push beyond depth 4 of our own.
    var canPush: Bool {
        (interfaceController?.templates.count ?? 0) < 4
    }

    init(appModel: AppModel, interfaceController: CPInterfaceController) {
        self.appModel = appModel
        self.interfaceController = interfaceController
        self.playableFilter = CarPlayPlayableFilter(appModel: appModel)
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        interfaceController?.delegate = self
        CPNowPlayingTemplate.shared.add(self)

        nowPlaying = CarPlayNowPlaying(coordinator: self)
        nowPlaying?.start()

        setupRoot()
        observeSession()
        observePlayer()
        observeOffline()
        CarPlayDebugRouting.applyIfNeeded(self)
    }

    func disconnect() {
        isStarted = false
        CPNowPlayingTemplate.shared.remove(self)

        listenNowTab?.stop()
        libraryTab?.stop()
        playlistsTab?.stop()
        downloadsTab?.stop()
        nowPlaying?.stop()

        listenNowTab = nil
        libraryTab = nil
        playlistsTab = nil
        downloadsTab = nil
        tabBarTemplate = nil
        nowPlaying = nil

        songItemMap.removeAll()
        disappearanceHandlers.removeAll()
        artwork.cancelAll()

        interfaceController?.delegate = nil
        interfaceController = nil
    }

    // MARK: - Root Setup

    private func setupRoot() {
        if appModel.session != .ready && appModel.activeAccount == nil {
            showSignInPrompt()
        } else {
            showTabBar()
        }
    }

    private func showSignInPrompt() {
        isShowingTabBar = false
        listenNowTab?.stop()
        libraryTab?.stop()
        playlistsTab?.stop()
        downloadsTab?.stop()

        let prompt = CPListTemplate(title: "Knight Music", sections: [])
        prompt.emptyViewTitleVariants = ["Sign in on your iPhone"]
        prompt.emptyViewSubtitleVariants = ["Open Knight Music on your iPhone to connect to your server."]
        interfaceController?.setRootTemplate(prompt, animated: false, completion: nil)
    }

    private func showTabBar() {
        isShowingTabBar = true
        lastHandledRevision = appModel.sessionRevision

        let tab1 = CarPlayListenNowTab(coordinator: self)
        let tab2 = CarPlayLibraryTab(coordinator: self)
        let tab3 = CarPlayPlaylistsTab(coordinator: self)
        let tab4 = CarPlayDownloadsTab(coordinator: self)

        listenNowTab = tab1
        libraryTab = tab2
        playlistsTab = tab3
        downloadsTab = tab4

        tab1.start()
        tab2.start()
        tab3.start()
        tab4.start()

        let tabBar = CPTabBarTemplate(templates: [tab1.template, tab2.template, tab3.template, tab4.template])
        tabBarTemplate = tabBar
        interfaceController?.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    // MARK: - Navigation

    func push(_ template: CPTemplate, animated: Bool = true) {
        guard canPush else {
            Log.app.warning("CarPlay cannot push beyond depth 4")
            return
        }
        interfaceController?.pushTemplate(template, animated: animated, completion: nil)
    }

    func pop(animated: Bool = true) {
        interfaceController?.popTemplate(animated: animated, completion: nil)
    }

    func popToRoot(animated: Bool = true) {
        interfaceController?.popToRootTemplate(animated: animated, completion: nil)
    }

    func pushNowPlayingIfNeeded(animated: Bool = true) {
        guard let interfaceController else { return }
        if interfaceController.topTemplate !== CPNowPlayingTemplate.shared {
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: animated, completion: nil)
        }
    }

    func showAlert(message: String) {
        guard let interfaceController else { return }
        let okAction = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [okAction])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Playback Actions

    func playSongs(_ songs: [Song], startAt: Int = 0, shuffle: Bool = false) {
        let playable = appModel.isOffline ? playableFilter.filterSongs(songs) : songs
        guard !playable.isEmpty else {
            showAlert(message: appModel.isOffline ? "No songs available offline." : "No songs to play.")
            return
        }
        let start = min(max(startAt, 0), playable.count - 1)
        player.play(playable, startAt: start, shuffle: shuffle)
        pushNowPlayingIfNeeded()
    }

    func playAlbum(_ album: Album, shuffle: Bool = false) {
        Task { @MainActor in
            let content = await library.albumContent(id: album.id)
            let songs = playableFilter.filterSongs(content.songs)
            guard !songs.isEmpty else {
                showAlert(message: appModel.isOffline ? "No downloaded songs in this album." : "This album has no songs.")
                return
            }
            player.play(songs, shuffle: shuffle)
            pushNowPlayingIfNeeded()
        }
    }

    func playArtist(_ artist: Artist, shuffle: Bool = false) {
        Task { @MainActor in
            let allSongs = await library.songs(artistId: artist.id).load()
            let songs = playableFilter.filterSongs(allSongs)
            guard !songs.isEmpty else {
                showAlert(message: appModel.isOffline ? "No downloaded songs for this artist." : "This artist has no songs.")
                return
            }
            player.play(songs, shuffle: shuffle)
            pushNowPlayingIfNeeded()
        }
    }

    func playPlaylist(_ playlist: Playlist, shuffle: Bool = false) {
        Task { @MainActor in
            let allSongs = await library.playlistSongs(id: playlist.id).load()
            let songs = playableFilter.filterSongs(allSongs)
            guard !songs.isEmpty else {
                showAlert(message: appModel.isOffline ? "No downloaded songs in this playlist." : "This playlist has no songs.")
                return
            }
            player.play(songs, shuffle: shuffle)
            pushNowPlayingIfNeeded()
        }
    }

    func shuffleLibrary() {
        Task { @MainActor in
            let songs: [Song]
            if let db = appModel.database {
                songs = (try? await db.pool.read { db in
                    try LibraryQueries.songs(db, sort: .title, search: "", limit: nil)
                }) ?? []
            } else {
                songs = await library.songs(sort: .title).load()
            }
            let playable = appModel.isOffline ? playableFilter.filterSongs(songs) : songs
            guard !playable.isEmpty else {
                showAlert(message: appModel.isOffline ? "No songs available offline." : "No songs found in library.")
                return
            }
            player.play(playable, shuffle: true)
            pushNowPlayingIfNeeded()
        }
    }

    func playFavoriteSongs() {
        Task { @MainActor in
            let songs = playableFilter.filterSongs(await library.favoriteSongs().load())
            guard !songs.isEmpty else {
                showAlert(message: appModel.isOffline ? "No favorite songs available offline." : "No favorite songs found.")
                return
            }
            player.play(songs, shuffle: true)
            pushNowPlayingIfNeeded()
        }
    }

    func playDownloadedSongs() {
        Task { @MainActor in
            let songs = await library.downloadedSongs().load()
            guard !songs.isEmpty else {
                showAlert(message: "No downloaded songs found.")
                return
            }
            player.play(songs, shuffle: true)
            pushNowPlayingIfNeeded()
        }
    }

    // MARK: - Playing Indicators

    func registerSongItem(_ item: CPListItem, songId: String) {
        if songItemMap[songId] == nil {
            songItemMap[songId] = []
        }
        songItemMap[songId]?.append(CarPlayWeakBox(item))
    }

    func updatePlayingIndicators() {
        let currentId = player.currentSong?.id
        for (songId, boxes) in songItemMap {
            let isCurrent = (songId == currentId)
            for box in boxes {
                if let item = box.value {
                    if item.isPlaying != isCurrent {
                        item.isPlaying = isCurrent
                    }
                }
            }
        }
    }

    // MARK: - Template Disappearance Tracking

    func trackDisappearance(of template: CPTemplate, handler: @escaping () -> Void) {
        disappearanceHandlers[ObjectIdentifier(template)] = handler
    }

    // MARK: - CPInterfaceControllerDelegate

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        guard let list = interfaceController?.templates else { return }
        if !list.contains(where: { $0 === aTemplate }) {
            artwork.cancelLoads(for: aTemplate)
            if let handler = disappearanceHandlers.removeValue(forKey: ObjectIdentifier(aTemplate)) {
                handler()
            }
        }
    }

    // MARK: - CPNowPlayingTemplateObserver

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard let nowPlaying else { return }
        let upNextTemplate = nowPlaying.makeUpNextTemplate()
        push(upNextTemplate)
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        guard canPush else { return }
        if let albumId = player.currentSong?.albumId {
            let detail = CarPlayDetailTemplates.makeAlbumDetail(albumId: albumId, title: player.currentSong?.album, coordinator: self)
            push(detail)
        } else if let artistId = player.currentSong?.artistId {
            let detail = CarPlayDetailTemplates.makeArtistDetail(artistId: artistId, title: player.currentSong?.artist, coordinator: self)
            push(detail)
        }
    }

    // MARK: - Observation

    private func observeSession() {
        guard isStarted else { return }
        withObservationTracking {
            _ = appModel.session
            _ = appModel.sessionRevision
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.handleSessionOrRevisionChanged()
                self.observeSession()
            }
        }
    }

    private func handleSessionOrRevisionChanged() {
        if appModel.session == .ready && !isShowingTabBar {
            showTabBar()
        } else if appModel.session == .ready && isShowingTabBar && appModel.sessionRevision != lastHandledRevision {
            showTabBar()
        } else if appModel.session != .ready && appModel.activeAccount == nil && isShowingTabBar {
            showSignInPrompt()
        }
    }

    private func observePlayer() {
        guard isStarted else { return }
        withObservationTracking {
            _ = player.currentSong?.id
            _ = player.isPlaying
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.updatePlayingIndicators()
                self.observePlayer()
            }
        }
    }

    private func observeOffline() {
        guard isStarted else { return }
        withObservationTracking {
            _ = appModel.isOffline
            _ = appModel.serverReachable
            _ = appModel.network.isConnected
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.listenNowTab?.rebuildSections()
                self.libraryTab?.rebuildSections()
                self.playlistsTab?.rebuildSections()
                self.downloadsTab?.rebuildSections()
                self.observeOffline()
            }
        }
    }
}
