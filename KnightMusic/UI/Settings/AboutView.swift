import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 4) {
                    Text("Knight Music")
                        .font(.title2)
                        .bold()
                    Text("Version \(version) (\(build))")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Section("Project") {
                Link("GitHub", destination: URL(string: "https://github.com/KNIGHTABDO/knight-music")!)
                    .tint(.accentColor)
            }

            Section("Acknowledgements") {
                Text("Navidrome")
                Text("GRDB.swift")
                Text("Nuke")
                Text("Animated artwork by artwork.m8tec.top")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.groupedBackground.ignoresSafeArea())
        .navigationTitle("About")
    }
}
