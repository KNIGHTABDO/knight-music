import CoreSpotlight
import SwiftUI

/// Advertises the album / artist / playlist on screen as an `NSUserActivity`, so Spotlight and Siri Suggestions
/// can offer it again. `RootView` continues these (and Spotlight results) by opening the same route.
struct LibraryActivity: ViewModifier {
    static let type = "com.knightabdo.knightmusic.browse"

    let kind: String
    let id: String
    let title: String?

    func body(content: Content) -> some View {
        content.userActivity(Self.type, isActive: title != nil) { activity in
            activity.title = title
            activity.userInfo = ["identifier": "\(kind):\(id)"]
            activity.targetContentIdentifier = "\(kind):\(id)"
            activity.isEligibleForSearch = true
            activity.isEligibleForPrediction = true
            activity.persistentIdentifier = "\(kind):\(id)"
        }
    }
}

extension View {
    func libraryActivity(_ kind: String, id: String, title: String?) -> some View {
        modifier(LibraryActivity(kind: kind, id: id, title: title))
    }

    /// Opens routes from `knightmusic://album/<id>` (and artist / playlist), Spotlight results and continued activities.
    func libraryDeepLinks(_ open: @escaping (Route) -> Void) -> some View {
        self
            .onOpenURL { url in
                guard url.scheme?.lowercased() == "knightmusic", let host = url.host?.lowercased() else { return }
                if host == "recognize" {
                    NotificationCenter.default.post(name: .startMusicRecognition, object: nil)
                    return
                }
                let id = url.pathComponents.dropFirst().first ?? ""
                if let route = SpotlightIndexer.route(for: "\(host):\(id)") { open(route) }
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                   let route = SpotlightIndexer.route(for: identifier) { open(route) }
            }
            .onContinueUserActivity(LibraryActivity.type) { activity in
                if let identifier = activity.userInfo?["identifier"] as? String,
                   let route = SpotlightIndexer.route(for: identifier) { open(route) }
            }
    }
}
