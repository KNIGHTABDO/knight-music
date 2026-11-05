import SwiftUI
import UIKit

struct LyricCardView: View {
    let song: Song
    let line: String
    let artwork: UIImage?
    let palette: ArtworkPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(line)
                .font(.system(size: 38, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(song.title) · \(song.artist ?? "")")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .foregroundStyle(.white)
        .padding(40)
        .frame(width: 600, alignment: .leading)
        .background(palette.backgroundGradient)
        .environment(\.colorScheme, .dark)
    }
}

struct LyricCardShare: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct LyricCardShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
