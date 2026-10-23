import SwiftUI

/// Soft glow of the cover behind the top of a detail page (content layer, not glass): a heavily blurred,
/// downsampled copy of the artwork that fades into the black background.
struct AlbumBackdrop: View {
    let coverArt: String?
    var height: CGFloat = 520

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            ArtworkView(coverArt: coverArt, pointSize: 120, cornerRadius: 0)
                .scaleEffect(side / 120)
                .frame(width: geo.size.width, height: geo.size.height)
        }
            .frame(height: height)
            .clipped()
            .blur(radius: 70, opaque: true)
            .opacity(0.55)
            .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
