import SwiftUI
import UIKit

struct CustomizeView: View {
    @Environment(AppSettings.self) private var settings

    private struct Swatch: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    private let swatches: [Swatch] = [
        Swatch(name: "Red", hex: "#FA2D48"),
        Swatch(name: "Pink", hex: "#FF2D55"),
        Swatch(name: "Purple", hex: "#AF52DE"),
        Swatch(name: "Blue", hex: "#007AFF"),
        Swatch(name: "Teal", hex: "#30B0C7"),
        Swatch(name: "Green", hex: "#34C759"),
        Swatch(name: "Orange", hex: "#FF9500"),
        Swatch(name: "Yellow", hex: "#FFCC00"),
        Swatch(name: "Gold", hex: "#D4AF37")
    ]

    private let columns = [
        GridItem(.adaptive(minimum: 56), spacing: 16)
    ]

    var body: some View {
        List {
            Section("Accent Color") {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(swatches) { swatch in
                        let isSelected = isCurrentAccent(swatch.hex)
                        let color = Color(hex: swatch.hex) ?? Theme.accent

                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(color)
                                    .frame(width: 48, height: 48)

                                if isSelected {
                                    Circle()
                                        .strokeBorder(Color.white, lineWidth: 3)
                                        .frame(width: 48, height: 48)

                                    Image(systemName: "checkmark")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(Color.white)
                                }
                            }
                            .shadow(color: isSelected ? color.opacity(0.4) : Color.clear, radius: 6)

                            Text(swatch.name)
                                .font(.caption2)
                                .foregroundStyle(isSelected ? Theme.label : Theme.secondaryLabel)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectSwatch(swatch)
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Preview") {
                VStack(spacing: 16) {
                    HStack {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(settings.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Now Playing Preview")
                                .font(.kmRowTitle)
                                .foregroundStyle(Theme.label)
                            Text("Knight Music Theme")
                                .font(.kmRowSubtitle)
                                .foregroundStyle(Theme.secondaryLabel)
                        }

                        Spacer()

                        Image(systemName: "heart.fill")
                            .font(.title3)
                            .foregroundStyle(settings.accentColor)
                    }

                    HStack(spacing: 12) {
                        Button("Glass Prominent") {}
                            .buttonStyle(.glassProminent)
                            .tint(settings.accentColor)

                        Button("Glass") {}
                            .buttonStyle(.glass)
                    }

                    HStack {
                        Text("Active Accent")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryLabel)
                        Spacer()
                        Text(settings.accentColorHex.uppercased())
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(settings.accentColor)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Customize")
    }

    private func isCurrentAccent(_ hex: String) -> Bool {
        let cleanStored = settings.accentColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        let cleanCandidate = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        return cleanStored == cleanCandidate
    }

    private func selectSwatch(_ swatch: Swatch) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        settings.accentColorHex = swatch.hex
        UserDefaults.standard.set(swatch.hex, forKey: "accentHex")
    }
}
