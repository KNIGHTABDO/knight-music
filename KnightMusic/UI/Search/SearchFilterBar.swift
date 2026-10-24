import SwiftUI

/// Source switch (Library / YouTube Music) and, while a query is active, the result categories as chips.
struct SearchFilterBar: View {
    @Binding var source: SearchView.SearchSource
    @Binding var scope: SearchView.SearchScope
    let showsScopes: Bool

    @Namespace private var chipSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Source", selection: $source) {
                ForEach(SearchView.SearchSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .padding(.horizontal, Theme.margin)

            if showsScopes {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(SearchView.SearchScope.allCases) { item in
                            chip(item)
                        }
                    }
                    .padding(.horizontal, Theme.margin)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 8)
        .animation(.smooth(duration: 0.25), value: showsScopes)
    }

    private func chip(_ item: SearchView.SearchScope) -> some View {
        let selected = item == scope
        return Button {
            withAnimation(.snappy(duration: 0.25)) { scope = item }
        } label: {
            Text(item.shortTitle)
                .font(.system(size: 15, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : Theme.label)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background {
                    if selected {
                        Capsule().fill(Theme.accent)
                            .matchedGeometryEffect(id: "selected", in: chipSpace)
                    } else {
                        Capsule().fill(Color.white.opacity(0.1))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension SearchView.SearchScope {
    var shortTitle: String { self == .top ? "Top" : rawValue }
}
