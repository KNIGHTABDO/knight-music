import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// Horizontal strip of built-in and saved looks. Tap applies; long-press for rename, duplicate, share, delete.
struct LooksGallery: View {
    @Environment(LookStore.self) private var looks
    @State private var renaming: Look?
    @State private var newName = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(looks.allLooks) { look in
                    LookChip(look: look, isActive: looks.isActive(look))
                        .onTapGesture { looks.apply(look) }
                        .contextMenu { menu(for: look) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .alert("Rename Look", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming { looks.rename(renaming, to: newName) }
                renaming = nil
            }
        }
    }

    @ViewBuilder
    private func menu(for look: Look) -> some View {
        Button { looks.apply(look) } label: { Label("Use", systemImage: "checkmark.circle") }
        Button { looks.duplicate(look) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        ShareLink(item: LookFile(look: look), preview: SharePreview(look.name, image: Image(systemName: look.symbol))) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        if !Look.builtIns.contains(where: { $0.id == look.id }) {
            Button {
                newName = look.name
                renaming = look
            } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { looks.delete(look) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

/// One look in the gallery: its accent, artwork shape and backdrop at a glance.
private struct LookChip: View {
    let look: Look
    let isActive: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(backdropFill)
                Image(systemName: look.artworkShape.systemImage)
                    .font(.system(size: 30))
                    .foregroundStyle(look.accentSource == .artwork ? AnyShapeStyle(rainbow) : AnyShapeStyle(look.accentColor))
                    .shadow(color: look.artworkGlow ? look.accentColor.opacity(0.8) : .clear, radius: 8)
                Image(systemName: look.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(width: 92, height: 92)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isActive ? look.accentColor : .white.opacity(0.1), lineWidth: isActive ? 3 : 1)
            }
            Text(look.name)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .fontDesign(look.typeface.design)
                .lineLimit(1)
                .frame(width: 92)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(look.name)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private var rainbow: AngularGradient {
        AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .purple, .red], center: .center)
    }

    private var backdropFill: AnyShapeStyle {
        let accent = look.accentColor
        switch look.backdrop {
        case .black:
            return AnyShapeStyle(Color.black)
        case .spotlight:
            return AnyShapeStyle(RadialGradient(colors: [accent.opacity(0.45), .black], center: .top, startRadius: 4, endRadius: 90))
        case .aurora:
            return AnyShapeStyle(LinearGradient(colors: [accent.opacity(0.6), .purple.opacity(0.5), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .blurredArtwork:
            return AnyShapeStyle(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
        case .palette:
            return AnyShapeStyle(LinearGradient(colors: [accent.opacity(0.35), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
        }
    }
}

/// Save / save-as / revert / surprise / from-album / import, shown under the gallery.
struct LookActionsRow: View {
    @Binding var showsImporter: Bool

    @Environment(LookStore.self) private var looks
    @Environment(PlayerEngine.self) private var player
    @Environment(UIState.self) private var ui: UIState?
    @State private var asksName = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if looks.hasUnsavedChanges {
                Text("“\(looks.current.name)” has changes")
                    .font(.footnote)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if looks.hasUnsavedChanges && looks.isSaved {
                            Button("Save", systemImage: "checkmark") { looks.saveChanges() }
                                .buttonStyle(.glassProminent)
                        }
                        if looks.hasUnsavedChanges {
                            if looks.isSaved {
                                saveAsNewButton.buttonStyle(.glass)
                            } else {
                                saveAsNewButton.buttonStyle(.glassProminent)
                            }
                            Button("Revert", systemImage: "arrow.uturn.backward") { looks.revert() }
                                .buttonStyle(.glass)
                        }
                        Button("Surprise Me", systemImage: "dice.fill") { looks.applySurprise() }
                            .buttonStyle(.glass)
                        if let song = player.currentSong {
                            Button("From This Cover", systemImage: "eyedropper.full") { lookFromCover(song) }
                                .buttonStyle(.glass)
                        }
                        Button("Import", systemImage: "square.and.arrow.down.on.square") { showsImporter = true }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.small)
                }
            }
            .scrollClipDisabled()
        }
        .textCase(nil)
        .padding(.top, 4)
        .alert("Save Look", isPresented: $asksName) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") { looks.saveAsNew(named: name) }
        } message: {
            Text("Saved looks can be shared and used in the day/night schedule.")
        }
    }

    private var saveAsNewButton: some View {
        Button("Save as New", systemImage: "square.and.arrow.down") {
            name = looks.isBuiltIn ? "My \(looks.current.name)" : looks.current.name
            asksName = true
        }
    }

    private func lookFromCover(_ song: Song) {
        Task {
            let palette = await ArtworkPalette.palette(for: song.coverArt)
            guard !palette.colors.isEmpty else {
                ui?.showToast("Couldn't read this cover's colors")
                return
            }
            looks.apply(looks.lookFromAlbum(named: song.album ?? song.title, palette: palette))
            ui?.showToast("Look made from “\(song.album ?? song.title)”")
        }
    }
}

/// A look exported as JSON with a `.knightlook` file name.
struct LookFile: Transferable, Sendable {
    let look: Look

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { file in
            try file.look.exportJSON()
        }
        .suggestedFileName { "\($0.look.name).knightlook" }
    }
}
