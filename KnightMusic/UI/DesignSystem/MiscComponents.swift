import SwiftUI
import UIKit

/// 0–5 stars. Tapping a star sets that rating; tapping the current rating clears it.
struct StarRatingView: View {
    @Binding var rating: Int
    var starSize: CGFloat = 20
    var spacing: CGFloat = 6

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(.system(size: starSize))
                    .foregroundStyle(star <= rating ? Theme.accent : Theme.tertiaryLabel)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 28, minHeight: 36)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let new = star == rating ? 0 : star
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.snappy(duration: 0.2)) { rating = new }
                    }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) of 5 stars")
        .accessibilityAdjustableAction { direction in
            rating = direction == .increment ? min(5, rating + 1) : max(0, rating - 1)
        }
    }
}

/// Thin wrapper over ContentUnavailableView with an optional prominent action.
struct EmptyStateView: View {
    var title: String
    var systemImage: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.glassProminent)
            }
        }
    }
}

/// Moving highlight for skeleton placeholders.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.6)
                }
                .clipped()
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

/// Skeleton block; compose it into rows/grids while data loads.
struct LoadingShimmer: View {
    var cornerRadius: CGFloat = 8
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(uiColor: .systemGray6))
            .shimmering()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SkeletonRowList: View {
    var count: Int = 8
    var circularLeading: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 14) {
                    if circularLeading {
                        LoadingShimmer(cornerRadius: 28).frame(width: 56, height: 56).clipShape(Circle())
                    } else {
                        LoadingShimmer(cornerRadius: 6).frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        LoadingShimmer(cornerRadius: 4).frame(width: 170, height: 14)
                        LoadingShimmer(cornerRadius: 4).frame(width: 110, height: 12)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .padding(.horizontal, Theme.margin)
            }
        }
    }
}

struct SkeletonTileGrid: View {
    var count: Int = 6
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 190 : 160), spacing: 16)], spacing: 20) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    LoadingShimmer().aspectRatio(1, contentMode: .fit)
                    LoadingShimmer(cornerRadius: 4).frame(height: 13)
                    LoadingShimmer(cornerRadius: 4).frame(width: 80, height: 11)
                }
            }
        }
        .padding(.horizontal, Theme.margin)
    }
}

// MARK: Liquid Glass helpers (real APIs only)

/// Circular glass control for the navigation/control layer.
struct GlassIconButton: View {
    var systemName: String
    var size: CGFloat = 44
    var tint: Color? = nil
    var action: () -> Void

    init(systemName: String, size: CGFloat = 44, tint: Color? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.size = size
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint ?? Theme.label)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// A floating capsule of glass controls (e.g. the player's bottom row). Children share one glass capsule.
struct GlassCapsuleBar<Content: View>: View {
    var spacing: CGFloat
    var content: Content

    init(spacing: CGFloat = 4, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: spacing) { content }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
