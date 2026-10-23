import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (`UTExportedTypeDeclarations`); only this app reads it.
    static let knightMusicItem = UTType(exportedAs: "com.knightabdo.knightmusic.item")
}

/// A song or album dragged inside the app: onto the queue, a playlist or the mini player.
struct LibraryDragItem: Codable, Hashable, Transferable {
    enum Kind: String, Codable { case song, album }

    var kind: Kind
    var id: String
    var title: String
    /// Carried along for songs so a drop needs no database lookup.
    var song: Song?

    static func song(_ song: Song) -> LibraryDragItem {
        LibraryDragItem(kind: .song, id: song.id, title: song.title, song: song)
    }

    static func album(id: String, title: String) -> LibraryDragItem {
        LibraryDragItem(kind: .album, id: id, title: title, song: nil)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .knightMusicItem)
    }
}

extension LibraryRepository {
    /// Songs for dropped items, in drop order (albums expand to their tracks).
    func songs(for items: [LibraryDragItem]) async -> [Song] {
        var songs: [Song] = []
        for item in items {
            switch item.kind {
            case .song:
                if let song = item.song { songs.append(song) }
            case .album:
                songs += await albumContent(id: item.id).songs
            }
        }
        return songs
    }
}

extension View {
    func songDraggable(_ song: Song) -> some View {
        draggable(LibraryDragItem.song(song)) {
            DragPreview(coverArt: song.coverArt, title: song.title)
        }
    }

    func albumDraggable(id: String, title: String, coverArt: String?) -> some View {
        draggable(LibraryDragItem.album(id: id, title: title)) {
            DragPreview(coverArt: coverArt, title: title)
        }
    }

    /// Accepts dragged songs/albums; `perform` gets the resolved songs.
    func libraryDropDestination(isTargeted: Binding<Bool>? = nil, perform: @escaping @MainActor ([Song]) async -> Void) -> some View {
        modifier(LibraryDropModifier(isTargeted: isTargeted, perform: perform))
    }
}

private struct LibraryDropModifier: ViewModifier {
    var isTargeted: Binding<Bool>?
    var perform: @MainActor ([Song]) async -> Void
    @Environment(LibraryRepository.self) private var library

    func body(content: Content) -> some View {
        content.dropDestination(for: LibraryDragItem.self) { items, _ in
            guard !items.isEmpty else { return false }
            Task { @MainActor in
                let songs = await library.songs(for: items)
                guard !songs.isEmpty else { return }
                Haptics.impact(.medium)
                await perform(songs)
            }
            return true
        } isTargeted: { targeted in
            isTargeted?.wrappedValue = targeted
        }
    }
}

private struct DragPreview: View {
    var coverArt: String?
    var title: String

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(coverArt: coverArt, pointSize: 44, cornerRadius: 6)
                .frame(width: 44, height: 44)
            Text(title)
                .font(.kmRowTitle)
                .foregroundStyle(Theme.label)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
