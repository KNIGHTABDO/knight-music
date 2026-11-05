import SwiftUI
import UIKit

struct CopiedYouTubeLinkPresenter: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var app
    @Environment(UIState.self) private var ui
    @AppStorage("km.lastOfferedLinkChangeCount") private var checkedChangeCount = -1

    func body(content: Content) -> some View {
        content
            .task { detectLink() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { detectLink() }
            }
    }

    private func detectLink() {
        guard scenePhase == .active else { return }
        let pasteboard = UIPasteboard.general
        let count = pasteboard.changeCount
        guard count != checkedChangeCount else { return }
        checkedChangeCount = count
        // Detection inspects patterns without reading clipboard content or asking for paste access.
        pasteboard.detectPatterns(for: [.probableWebURL]) { result in
            Task { @MainActor in
                switch result {
                case .success(let patterns):
                    guard patterns.contains(.probableWebURL), pasteboard.changeCount == count else { return }
                    ui.showToast("Link copied", actionTitle: "Open") {
                        guard pasteboard.changeCount == count else {
                            ui.showToast("Copied link changed")
                            return
                        }
                        // This is the first read, directly following the user's explicit Open action.
                        guard let text = pasteboard.string,
                              let link = CopiedYouTubeLink(text: text) else {
                            ui.showToast("Copy a YouTube video or playlist link")
                            return
                        }
                        Task { await open(link) }
                    }
                case .failure(let error):
                    Log.app.error("Clipboard URL detection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func open(_ link: CopiedYouTubeLink) async {
        switch link {
        case .playlist(let id): ui.open(.playlist(Song.youTubePrefix + id))
        case .video(let id):
            do {
                let songs = try await YouTubeMusic.shared.radio(videoId: id)
                guard let source = songs.first(where: { $0.videoId == id }) else {
                    throw YouTubeError.invalidResponse
                }
                app.player.play([source.song])
                ui.playerPanel = .artwork
                ui.isPlayerPresented = true
            } catch {
                Log.api.error("Opening copied YouTube link failed: \(error.localizedDescription)")
                ui.showToast(error.localizedDescription)
            }
        }
    }
}

enum CopiedYouTubeLink: Equatable {
    case video(String)
    case playlist(String)

    init?(text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let youtube = host == "youtube.com" || host.hasSuffix(".youtube.com")
        let short = host == "youtu.be" || host == "www.youtu.be"
        guard youtube || short else { return nil }
        let query = components.queryItems ?? []
        let path = url.pathComponents.filter { $0 != "/" }
        let video = short ? path.first : query.first(where: { $0.name == "v" })?.value
            ?? ((path.first == "shorts" || path.first == "embed" || path.first == "live") ? path.dropFirst().first : nil)
        if let video, video.count == 11, Self.validID(video) {
            self = .video(video)
        } else if let list = query.first(where: { $0.name == "list" })?.value, Self.validID(list) {
            self = .playlist(list)
        } else {
            return nil
        }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
        }
    }
}
