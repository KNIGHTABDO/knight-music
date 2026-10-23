import SwiftUI

/// Single-line text that, when it doesn't fit, scrolls in a seamless loop after a pause
/// (Apple Music's long-title behaviour). Static when it fits or when Reduce Motion is on.
struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color = .white
    var gap: CGFloat = 48
    /// Points per second.
    var speed: CGFloat = 32

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflows: Bool { containerWidth > 0 && textWidth > containerWidth + 1 }

    var body: some View {
        // The hidden copy gives the view its one-line height while taking all offered width.
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                HStack(spacing: gap) {
                    label
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    if overflows && !reduceMotion {
                        label
                    }
                }
                .offset(x: offset)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            .clipped()
            .mask {
                if overflows && !reduceMotion {
                    LinearGradient(
                        stops: [
                            .init(color: offset < 0 ? .clear : .black, location: 0),
                            .init(color: .black, location: 0.05),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Color.black
                }
            }
            .task(id: "\(text)|\(Int(textWidth))|\(Int(containerWidth))|\(reduceMotion)") {
                await scrollLoop()
            }
            .accessibilityElement()
            .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }

    private func scrollLoop() async {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { offset = 0 }
        guard overflows, !reduceMotion else { return }
        let distance = textWidth + gap
        let duration = Double(distance / speed)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(3))
                withAnimation(.linear(duration: duration)) { offset = -distance }
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            // The second copy now sits exactly where the first started: jump back invisibly.
            withTransaction(reset) { offset = 0 }
        }
    }
}
