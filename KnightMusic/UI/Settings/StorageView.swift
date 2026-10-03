import SwiftUI
import Nuke

struct StorageView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlayerEngine.self) private var player

    @State private var storageManager: StorageManager?
    @State private var albumBreakdown: [AlbumStorage] = []
    @State private var animatedArtworkSize: Int = 0
    @State private var imageCacheSize: Int = 0

    @State private var showingClearStreamConfirmation = false
    @State private var showingClearArtworkConfirmation = false
    @State private var showingDeleteDownloadsConfirmation = false

    private let cacheLimitOptions = [
        (512, "512 MB"),
        (1024, "1 GB"),
        (2048, "2 GB"),
        (5120, "5 GB"),
        (10240, "10 GB")
    ]

    var body: some View {
        @Bindable var settings = settings

        List {
            Section("Storage Usage") {
                HStack {
                    Text("Downloads")
                    Spacer()
                    let count = storageManager?.downloadedSongCount ?? downloads.completedCount
                    let bytes = storageManager?.downloadBytes ?? downloads.completedBytes
                    Text("\(StorageManager.format(bytes)) (\(count) \(count == 1 ? "song" : "songs"))")
                        .foregroundStyle(Theme.secondaryLabel)
                }

                HStack {
                    Text("Stream Cache")
                    Spacer()
                    let bytes = storageManager?.cacheBytes ?? player.streamCache.totalBytes
                    Text(StorageManager.format(bytes))
                        .foregroundStyle(Theme.secondaryLabel)
                }

                HStack {
                    Text("Animated Artwork")
                    Spacer()
                    Text(StorageManager.format(animatedArtworkSize))
                        .foregroundStyle(Theme.secondaryLabel)
                }

                if imageCacheSize > 0 {
                    HStack {
                        Text("Image Cache")
                        Spacer()
                        Text(StorageManager.format(imageCacheSize))
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
            }

            Section {
                Picker("Limit", selection: $settings.streamCacheLimitMB) {
                    ForEach(cacheLimitOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
            } header: {
                Text("Stream Cache Limit")
            } footer: {
                Text("When the stream cache exceeds this limit, older songs are evicted automatically.")
            }

            Section {
                Button(role: .destructive) {
                    showingClearStreamConfirmation = true
                } label: {
                    Text("Clear Stream Cache")
                        .foregroundStyle(Theme.accent)
                }

                Button(role: .destructive) {
                    showingClearArtworkConfirmation = true
                } label: {
                    Text("Clear Artwork Cache")
                        .foregroundStyle(Theme.accent)
                }

                Button(role: .destructive) {
                    showingDeleteDownloadsConfirmation = true
                } label: {
                    Text("Delete All Downloads")
                        .foregroundStyle(Theme.accent)
                }
            }

            Section("Downloads by Album") {
                if albumBreakdown.isEmpty {
                    Text("No downloaded albums")
                        .foregroundStyle(Theme.secondaryLabel)
                } else {
                    ForEach(albumBreakdown) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.albumName ?? "Unknown Album")
                                    .font(.kmRowTitle)
                                    .foregroundStyle(Theme.label)
                                Text("\(item.artist ?? "Unknown Artist") • \(KMFormat.songCount(item.songCount))")
                                    .font(.kmRowSubtitle)
                                    .foregroundStyle(Theme.secondaryLabel)
                            }

                            Spacer()

                            Text(StorageManager.format(item.bytes))
                                .font(.kmRowSubtitle)
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                    }
                    .onDelete { indexSet in
                        deleteAlbums(at: indexSet)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Storage")
        .task {
            initStorageManager()
            await refreshAll()
        }
        .confirmationDialog(
            "Clear Stream Cache",
            isPresented: $showingClearStreamConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Stream Cache", role: .destructive) {
                storageManager?.clearCache()
                refreshSizes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Streamed audio cached on disk will be deleted.")
        }
        .confirmationDialog(
            "Clear Artwork Cache",
            isPresented: $showingClearArtworkConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Artwork Cache", role: .destructive) {
                clearArtworkCaches()
                refreshSizes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached album covers and animated artwork videos will be deleted and re-downloaded as needed.")
        }
        .confirmationDialog(
            "Delete All Downloads",
            isPresented: $showingDeleteDownloadsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Downloads", role: .destructive) {
                downloads.deleteAll()
                storageManager?.refresh()
                refreshSizes()
                Task {
                    if let manager = storageManager {
                        albumBreakdown = await manager.albumBreakdown()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All downloaded songs will be removed from this device.")
        }
    }

    private func initStorageManager() {
        if storageManager == nil {
            storageManager = StorageManager(downloads: downloads, cache: player.streamCache)
        }
    }

    private func refreshAll() async {
        refreshSizes()
        if let manager = storageManager {
            albumBreakdown = await manager.albumBreakdown()
        }
    }

    private func refreshSizes() {
        storageManager?.refresh()
        animatedArtworkSize = calculateFolderSize(animatedArtworkURL)
        if let disk = try? DataCache(name: "com.knightabdo.knightmusic.artwork") {
            imageCacheSize = disk.totalSize
        } else {
            imageCacheSize = 0
        }
    }

    private var animatedArtworkURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("AnimatedArtwork", isDirectory: true)
    }

    private func calculateFolderSize(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total = 0
        for case let fileURL as URL in enumerator {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += size
            }
        }
        return total
    }

    private func clearArtworkCaches() {
        let url = animatedArtworkURL
        if let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for file in files {
                try? FileManager.default.removeItem(at: url.appendingPathComponent(file))
            }
        }
        if let disk = try? DataCache(name: "com.knightabdo.knightmusic.artwork") {
            disk.removeAll()
        }
        ImagePipeline.shared.cache.removeAll()
    }

    private func deleteAlbums(at offsets: IndexSet) {
        let albumsToDelete = offsets.map { albumBreakdown[$0] }
        Task {
            guard let db = downloads.database else { return }
            for album in albumsToDelete {
                let songIds: [String] = (try? await db.read { db in
                    try String.fetchAll(
                        db,
                        sql: "SELECT songId FROM download JOIN song ON song.id = download.songId WHERE song.albumId = ?",
                        arguments: [album.albumId]
                    )
                }) ?? []
                downloads.delete(songIds: songIds)
            }
            storageManager?.refresh()
            refreshSizes()
            if let manager = storageManager {
                albumBreakdown = await manager.albumBreakdown()
            }
        }
    }
}
