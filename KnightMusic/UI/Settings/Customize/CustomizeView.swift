import SwiftUI
import UniformTypeIdentifiers

/// Settings → Customize. Every change applies live and shows in the pinned preview above the list.
/// The current look can be saved, shared as a `.knightlook` file, and scheduled for day and night.
struct CustomizeView: View {
    @Environment(LookStore.self) private var looks
    @Environment(UIState.self) private var ui: UIState?

    @State private var showsImporter = false

    private static let swatches = [
        "#FA2D48", "#FF375F", "#FF2D55", "#AF52DE", "#5E5CE6", "#007AFF", "#00E5FF", "#30B0C7",
        "#1FA187", "#34C759", "#A4D65E", "#FFCC00", "#D4AF37", "#E8A33D", "#FF9500", "#E5E5EA"
    ]

    var body: some View {
        @Bindable var looks = looks

        List {
            Section {
                LooksGallery()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                Text("Looks")
            } footer: {
                LookActionsRow(showsImporter: $showsImporter)
            }

            colorsSection($looks.current)
            typeSection($looks.current)
            playerSection($looks.current)
            lyricsSection($looks.current)
            librarySection($looks.current)

            Section("App") {
                NavigationLink {
                    AppIconView()
                } label: {
                    Label("App Icon", systemImage: "app.gift.fill")
                }
                NavigationLink {
                    HomeLayoutView()
                } label: {
                    LabeledContent {
                        Text("\(looks.visibleHomeSections.count) shelves")
                    } label: {
                        Label("Home Layout", systemImage: "square.grid.3x1.below.line.grid.1x2")
                    }
                }
                Picker(selection: $looks.startTab) {
                    ForEach(StartTab.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Open On", systemImage: "arrow.up.forward.app")
                }
            }

            feelSection($looks)
            ScheduleSection()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Customize")
        .safeAreaInset(edge: .top, spacing: 0) {
            LookPreviewCard()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json, .data]) { result in
            importLook(result)
        }
    }

    // MARK: - Sections

    private func colorsSection(_ look: Binding<Look>) -> some View {
        Section("Colors") {
            Picker("Accent", selection: look.accentSource) {
                ForEach(Look.AccentSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            if look.wrappedValue.accentSource == .fixed {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Self.swatches, id: \.self) { hex in
                            swatch(hex, look: look)
                        }
                        ColorPicker("Custom", selection: Binding(
                            get: { look.wrappedValue.accentColor },
                            set: { look.wrappedValue.accentHex = UIColor($0).hexString }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Text("The accent follows the cover of the song that's playing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Picker("Appearance", selection: look.appearance) {
                ForEach(Look.Appearance.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
        }
    }

    private func swatch(_ hex: String, look: Binding<Look>) -> some View {
        let color = Color(hex: hex) ?? .red
        let selected = look.wrappedValue.accentHex.caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            withAnimation(.snappy) { look.wrappedValue.accentHex = hex }
            Haptics.selection()
        } label: {
            Circle()
                .fill(color)
                .frame(width: 34, height: 34)
                .overlay {
                    if selected {
                        Circle().strokeBorder(.white, lineWidth: 3)
                        Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white)
                    }
                }
                .shadow(color: selected ? color.opacity(0.6) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func typeSection(_ look: Binding<Look>) -> some View {
        Section("Type") {
            Picker("Font", selection: look.typeface) {
                ForEach(Look.Typeface.allCases) { face in
                    Text(face.title).fontDesign(face.design).tag(face)
                }
            }
            Picker("Width", selection: look.typeWidth) {
                ForEach(Look.TypeWidth.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func playerSection(_ look: Binding<Look>) -> some View {
        Section {
            Picker(selection: look.backdrop) {
                ForEach(Look.Backdrop.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            } label: {
                Label("Background", systemImage: "rectangle.fill.on.rectangle.fill")
            }
            Picker("Artwork", selection: look.artworkShape) {
                ForEach(Look.ArtworkShape.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            if look.wrappedValue.artworkShape == .card {
                LabeledSlider(title: "Corner Radius", value: look.artworkRadius, range: 0...40, format: { "\(Int($0)) pt" })
                Toggle("Shrink When Paused", isOn: look.shrinkWhenPaused)
            }
            Toggle("Colored Glow", isOn: look.artworkGlow)
            Picker("Artwork Moves", selection: look.pulse) {
                ForEach(Look.Pulse.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Ratings", isOn: look.showRatings)
            Toggle("Volume Slider", isOn: look.showVolume)
        } header: {
            Text("Now Playing")
        } footer: {
            if look.wrappedValue.pulse == .beat {
                Text("Downloaded and cached songs bounce to their real loudness. Streams follow the song's BPM when the server knows it.")
            }
        }
    }

    private func lyricsSection(_ look: Binding<Look>) -> some View {
        Section("Lyrics") {
            LabeledSlider(title: "Size", value: look.lyricsScale, range: 0.7...1.5, format: { "\(Int(($0 * 100).rounded()))%" })
            Picker("Alignment", selection: look.lyricsAlignment) {
                ForEach(Look.LyricsAlignment.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Current Line", selection: look.lyricsHighlight) {
                ForEach(Look.LyricsHighlight.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Blur Distant Lines", isOn: look.lyricsBlur)
            Toggle("Glow", isOn: look.lyricsGlow)
        }
    }

    private func librarySection(_ look: Binding<Look>) -> some View {
        Section("Library") {
            Picker("Grid", selection: look.gridDensity) {
                ForEach(Look.GridDensity.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledSlider(title: "Cover Corners", value: look.tileRadius, range: 0...30, format: { "\(Int($0)) pt" })
            Picker("Artist Photos", selection: look.artistShape) {
                ForEach(Look.ArtistShape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func feelSection(_ looks: Bindable<LookStore>) -> some View {
        Section {
            Picker(selection: looks.haptics) {
                ForEach(HapticsLevel.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
            }
            .onChange(of: self.looks.haptics) { _, _ in Haptics.impact(.medium) }
            Picker(selection: looks.shakeAction) {
                ForEach(ShakeAction.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Shake to", systemImage: "iphone.gen3.motion")
            }
            Toggle(isOn: looks.homeGreeting) {
                Label("Greeting on Home", systemImage: "hand.wave")
            }
        } header: {
            Text("Feel")
        } footer: {
            if self.looks.shakeAction == .surpriseLook {
                Text("Shake your phone anywhere in the app for a brand-new random look.")
            }
        }
    }

    // MARK: - Import

    private func importLook(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let look = try looks.importLook(from: Data(contentsOf: url))
            ui?.showToast("Imported \(look.name)")
        } catch {
            Log.app.error("Look import failed: \(error)")
            ui?.showToast("That file isn't a Knight Music look")
        }
    }
}

/// Slider with its title and current value on one line above it.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: format(value))
            Slider(value: $value, in: range)
        }
    }
}
