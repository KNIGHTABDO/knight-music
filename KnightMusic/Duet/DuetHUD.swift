import SwiftUI
import UIKit

/// Top-most window for Duet's prompt and switch animation. Touches outside the prompt fall through to the
/// app below, and it never takes keyboard focus or shake events.
final class DuetHUDWindow: UIWindow {
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // The switch animation's container is a plain subview: it takes every touch while the curl runs.
        guard hit === rootViewController?.view || hit === self else { return hit }
        // SwiftUI draws the prompt inside the hosting view itself, so only its measured frame tells it apart
        // from the empty, see-through rest of the window.
        let duet = DuetCoordinator.shared
        guard duet.prompt != nil, duet.promptFrame.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        return rootViewController?.view ?? hit
    }
}

/// Keeps the status bar the way the side underneath wants it while the HUD is the top window.
final class DuetHUDHostingController: UIHostingController<DuetHUDView> {
    override var prefersStatusBarHidden: Bool { DuetCoordinator.shared.statusBarHidden }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

struct DuetHUDView: View {
    @State private var duet = DuetCoordinator.shared

    var body: some View {
        VStack {
            if let prompt = duet.prompt {
                DuetPromptPill(prompt: prompt)
                    .id(prompt.id)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        DuetCoordinator.shared.promptFrame = frame
                    }
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .top)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy, value: duet.prompt?.id)
        .tint(LookStore.shared.accent)
        .preferredColorScheme(.dark)
    }
}

/// "Switch to Streamora?" — a glass pill with a countdown ring: shake again or tap Switch, X or wait to cancel.
private struct DuetPromptPill: View {
    let prompt: DuetCoordinator.Prompt
    @State private var remaining: CGFloat = 1

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.15), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: remaining)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: prompt.target.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: prompt.id)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(prompt.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    DuetCoordinator.shared.switchTo(prompt.target)
                } label: {
                    Text("Switch")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .accessibilityHint("Opens \(prompt.target.appName)")

                Button {
                    Haptics.impact(.light)
                    DuetCoordinator.shared.dismissPrompt()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Stay")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
        }
        .frame(maxWidth: 520)
        .onAppear {
            guard !DebugLaunch.isDemo else { return }
            withAnimation(.linear(duration: DuetCoordinator.promptDuration)) { remaining = 0 }
        }
    }
}
