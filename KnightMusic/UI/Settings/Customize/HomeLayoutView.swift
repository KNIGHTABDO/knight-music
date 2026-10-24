import SwiftUI

/// Reorder and hide the Home shelves.
struct HomeLayoutView: View {
    @Environment(LookStore.self) private var looks

    var body: some View {
        List {
            Section {
                ForEach(looks.homeOrder) { section in
                    Toggle(isOn: Binding(
                        get: { !looks.hiddenHomeSections.contains(section) },
                        set: { looks.setHomeSection(section, visible: $0) }
                    )) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
                .onMove { looks.moveHomeSections(from: $0, to: $1) }
            } footer: {
                Text("Drag to reorder. Shelves with nothing to show stay hidden on their own.")
            }

            Section {
                Button("Reset to Default", role: .destructive) {
                    withAnimation { looks.resetHome() }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Home Layout")
        .navigationBarTitleDisplayMode(.inline)
    }
}
