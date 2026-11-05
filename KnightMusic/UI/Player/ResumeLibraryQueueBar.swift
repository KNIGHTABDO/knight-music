import SwiftUI

/// Offered while YouTube songs play over a library queue: one tap returns to where that queue was.
struct ResumeLibraryQueueBar: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        if let stash = player.stashedLibraryQueue, let song = stash.currentSong {
            Button {
                Haptics.impact(.light)
                withAnimation(.smooth) { player.resumeStashedLibraryQueue() }
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(coverArt: song.coverArt, pointSize: 40, cornerRadius: 6)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Back to Your Queue")
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(song.title) · \(KMFormat.songCount(stash.remainingCount))")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityHint("Stops the YouTube songs and resumes your library queue")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
