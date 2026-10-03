import SwiftUI
import Nuke
import NukeUI

/// Cover image with a dark placeholder, fade-in and size-bucketed downsampling.
/// Fixed `pointSize` square by default; `fillsContainer` makes it take the proposed width (grids) while
/// `pointSize` only drives which server size is requested.
struct ArtworkView: View {
    var coverArt: String?
    var pointSize: CGFloat
    var cornerRadius: CGFloat = Theme.Radius.tile
    var isCircle: Bool = false
    var placeholderSymbol: String? = nil
    var fillsContainer: Bool = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let request = ArtworkLoader.shared.request(coverArt: coverArt, pointSize: pointSize, scale: displayScale)
        Group {
            if fillsContainer {
                Color.clear.aspectRatio(1, contentMode: .fit).overlay(content(request))
            } else {
                content(request).frame(width: pointSize, height: pointSize)
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Theme.hairline, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var shape: AnyShape {
        isCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func content(_ request: ImageRequest?) -> some View {
        LazyImage(request: request, transaction: Transaction(animation: .easeOut(duration: 0.3))) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        GeometryReader { geo in
            ZStack {
                Color(uiColor: .systemGray6)
                Image(systemName: placeholderSymbol ?? (isCircle ? "person.fill" : "music.note"))
                    .font(.system(size: max(12, min(geo.size.width, geo.size.height) * 0.36)))
                    .foregroundStyle(Theme.tertiaryLabel)
            }
        }
    }
}
