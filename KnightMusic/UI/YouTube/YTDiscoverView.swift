import SwiftUI

/// Flagship YouTube Music discovery screen, inspired by BitChord's HomeScreen and ExploreScreen,
/// tailored to Knight Music's iOS 26 Liquid Glass design system.
struct YTDiscoverView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case forYou = "For You"
        case explore = "Explore"
        case moods = "Moods & Genres"
        case newReleases = "New Releases"
        case charts = "Charts"
        var id: String { rawValue }
    }

    @Environment(PlayerEngine.self) private var player
    @Environment(UIState.self) private var ui: UIState?
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var scope: Scope = .forYou
    @State private var feed: YTDiscoverFeed?
    @State private var moodSections: [YTMoodGenreSection]?
    @State private var selectedChip: YTFeedChip?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    @Namespace private var scopeChipSpace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                scopeBar

                if scope == .forYou, let chips = feed?.chips, !chips.isEmpty {
                    dynamicMoodChips(chips)
                }

                if isLoading && feed == nil && moodSections == nil {
                    loadingSkeletons
                } else if let errorMessage, feed == nil && moodSections == nil {
                    EmptyStateView(
                        title: "Couldn't Load",
                        systemImage: "exclamationmark.triangle",
                        message: errorMessage,
                        actionTitle: "Try Again"
                    ) {
                        Task { await load(force: true) }
                    }
                    .padding(.top, 60)
                } else if scope == .moods {
                    if let moodSections {
                        moodsContent(moodSections)
                    }
                } else if let feed {
                    shelvesContent(feed)
                }
            }
            .padding(.vertical, 14)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UserDefaults.standard.set(SearchView.SearchSource.youTube.rawValue, forKey: "search_source")
                    ui?.selectedTab = .search
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.label)
                }
            }
        }
        .refreshable {
            await load(force: true)
        }
        .task(id: "\(scope.rawValue):\(selectedChip?.id ?? "")") {
            await load(force: false)
        }
    }

    // MARK: - Scope Bar

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Scope.allCases) { item in
                    let selected = item == scope
                    Button {
                        Haptics.selection()
                        withAnimation(.snappy(duration: 0.25)) {
                            scope = item
                            selectedChip = nil
                        }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 15, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.white : Theme.label)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(Theme.accent)
                                        .matchedGeometryEffect(id: "scope_selected", in: scopeChipSpace)
                                } else {
                                    Capsule()
                                        .fill(Color.white.opacity(0.1))
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.margin)
        }
    }

    // MARK: - Dynamic Mood Filter Chips (FEmusic_home)

    private func dynamicMoodChips(_ chips: [YTFeedChip]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    let selected = selectedChip?.id == chip.id
                    Button {
                        Haptics.selection()
                        withAnimation(.snappy(duration: 0.25)) {
                            if selected {
                                selectedChip = nil
                            } else {
                                selectedChip = chip
                            }
                        }
                    } label: {
                        Text(chip.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.accent : Theme.secondaryLabel)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background {
                                Capsule()
                                    .fill(selected ? Theme.accent.opacity(0.18) : Color.white.opacity(0.06))
                            }
                            .overlay {
                                if selected {
                                    Capsule()
                                        .stroke(Theme.accent.opacity(0.4), lineWidth: 1)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.margin)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Shelves Content

    @ViewBuilder
    private func shelvesContent(_ feed: YTDiscoverFeed) -> some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(Array(feed.shelves.enumerated()), id: \.element.id) { index, shelf in
                YTShelfItemDispatcher(shelf: shelf)
                    .onAppear {
                        if index >= feed.shelves.count - 2 {
                            Task { await loadMore() }
                        }
                    }
            }

            if isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(Theme.accent)
                    Spacer()
                }
                .padding(.vertical, 16)
            }
        }
    }

    // MARK: - Moods & Genres Content

    @ViewBuilder
    private func moodsContent(_ sections: [YTMoodGenreSection]) -> some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: section.title)
                        .padding(.horizontal, Theme.margin)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 180 : 150, maximum: 260), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(section.items) { item in
                            YTMoodGenreCard(item: item)
                        }
                    }
                    .padding(.horizontal, Theme.margin)
                }
            }
        }
    }

    // MARK: - Skeletons

    private var loadingSkeletons: some View {
        VStack(alignment: .leading, spacing: 24) {
            SkeletonTileGrid(count: 6)
                .padding(.horizontal, Theme.margin)
            SkeletonRowList(count: 4)
                .padding(.horizontal, Theme.margin)
        }
        .padding(.top, 16)
    }

    // MARK: - Data Loading

    private func load(force: Bool) async {
        isLoading = true
        errorMessage = nil
        do {
            switch scope {
            case .forYou:
                let result = try await YouTubeMusic.shared.home(params: selectedChip?.target.params, forceRefresh: force)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    feed = result
                    moodSections = nil
                }
            case .explore:
                let result = try await YouTubeMusic.shared.explore(forceRefresh: force)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    feed = result
                    moodSections = nil
                }
            case .moods:
                let result = try await YouTubeMusic.shared.moodsAndGenres(forceRefresh: force)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    moodSections = result
                    feed = nil
                }
            case .newReleases:
                let result = try await YouTubeMusic.shared.newReleases(forceRefresh: force)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    feed = result
                    moodSections = nil
                }
            case .charts:
                let result = try await YouTubeMusic.shared.charts(forceRefresh: force)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    feed = result
                    moodSections = nil
                }
            }
            isLoading = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            Log.api.warning("YouTube Discover (\(scope.rawValue)) failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func loadMore() async {
        guard scope == .forYou, let token = feed?.continuation, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let next = try await YouTubeMusic.shared.continueHome(token: token)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.2)) {
                if var current = feed {
                    current.shelves.append(contentsOf: next.shelves)
                    current.continuation = next.continuation
                    feed = current
                }
            }
        } catch {
            Log.api.warning("YouTube Discover continuation failed: \(error.localizedDescription)")
        }
        isLoadingMore = false
    }
}
