import SwiftUI
import UIKit

/// Trailing "# A B C … Z" index in the accent color (see ref/IMG_1163.PNG). Tap or drag; fires a selection haptic
/// each time the letter changes. When the column is too short for every letter, alternate ones collapse to dots.
struct AlphabetIndexScrubber: View {
    static let defaultLetters: [String] = ["#"] + (65...90).compactMap { UnicodeScalar($0).map { String($0) } }

    var letters: [String] = AlphabetIndexScrubber.defaultLetters
    /// Letters that have content; others are dimmed. nil = all active.
    var activeLetters: Set<String>? = nil
    var onSelect: (String) -> Void

    @State private var current: String?
    private let haptic = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            let slot = geo.size.height / CGFloat(max(letters.count, 1))
            let compact = slot < 14
            VStack(spacing: 0) {
                ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                    let showLetter = !compact || index % 2 == 0
                    Group {
                        if showLetter {
                            Text(letter).font(.system(size: 11, weight: .bold))
                        } else {
                            Circle().frame(width: 4, height: 4)
                        }
                    }
                    .foregroundStyle(Theme.accent.opacity(isActive(letter) ? 1 : 0.35))
                    .scaleEffect(current == letter ? 1.35 : 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: slot)
                }
            }
            .frame(width: geo.size.width)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in select(at: value.location.y, slot: slot) }
                    .onEnded { _ in withAnimation(.snappy) { current = nil } }
            )
            .animation(.snappy(duration: 0.15), value: current)
        }
        .frame(width: 24)
        .onAppear { haptic.prepare() }
        .accessibilityElement()
        .accessibilityLabel("Index")
        .accessibilityAdjustableAction { direction in
            let i = current.flatMap { letters.firstIndex(of: $0) } ?? 0
            let next = direction == .increment ? min(letters.count - 1, i + 1) : max(0, i - 1)
            current = letters[next]
            onSelect(letters[next])
        }
    }

    private func isActive(_ letter: String) -> Bool { activeLetters?.contains(letter) ?? true }

    private func select(at y: CGFloat, slot: CGFloat) {
        guard slot > 0 else { return }
        let index = min(letters.count - 1, max(0, Int(y / slot)))
        let letter = letters[index]
        guard letter != current else { return }
        current = letter
        haptic.selectionChanged()
        haptic.prepare()
        onSelect(letter)
    }
}
