import SwiftUI

/// A spinning record with the cover as its label (the label view should be `labelSide` wide). Keeps its angle when paused and picks up from there.
struct VinylRecord<Label: View>: View {
    let side: CGFloat
    @ViewBuilder var label: () -> Label

    @Environment(PlayerEngine.self) private var player
    @State private var restingAngle: Double = 0
    @State private var spinStart: Date?

    static func labelSide(for side: CGFloat) -> CGFloat { side * 0.38 }

    /// 33⅓ rpm.
    private static var degreesPerSecond: Double { 360 * 33.333 / 60 }

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying)) { context in
            disc
                .rotationEffect(.degrees(angle(at: context.date)))
        }
        .overlay { sheen }
        .frame(width: side, height: side)
        .onChange(of: player.isPlaying, initial: true) { _, playing in
            if playing {
                spinStart = .now
            } else if spinStart != nil {
                restingAngle = angle(at: .now)
                spinStart = nil
            }
        }
    }

    private func angle(at date: Date) -> Double {
        guard let spinStart else { return restingAngle }
        return (restingAngle + date.timeIntervalSince(spinStart) * Self.degreesPerSecond).truncatingRemainder(dividingBy: 360)
    }

    private var disc: some View {
        ZStack {
            Circle().fill(Color(white: 0.06))
            // Grooves.
            ForEach(0..<14, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(i.isMultiple(of: 3) ? 0.07 : 0.035), lineWidth: 0.6)
                    .padding(side * (0.04 + CGFloat(i) * 0.022))
            }
            label()
                .clipShape(Circle())
            Circle()
                .fill(Color.black)
                .frame(width: side * 0.03, height: side * 0.03)
        }
    }

    /// Light reflection that stays still while the record turns underneath it.
    private var sheen: some View {
        Circle()
            .fill(AngularGradient(
                colors: [.clear, .white.opacity(0.10), .clear, .clear, .white.opacity(0.07), .clear],
                center: .center
            ))
            .allowsHitTesting(false)
    }
}
