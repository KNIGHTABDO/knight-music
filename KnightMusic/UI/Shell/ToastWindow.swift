import SwiftUI
import UIKit

/// Hosts toasts in their own window above everything (sheets, the full player, Streamora's window), so a message
/// is never hidden by a presentation layer. Touches outside the capsule fall through.
@MainActor
final class ToastWindow {
    static let shared = ToastWindow()

    fileprivate(set) var capsuleFrame: CGRect = .zero
    private var window: PassthroughWindow?
    private(set) var ui: UIState?
    private var hideTask: Task<Void, Never>?

    func statusBarAppearanceChanged() {
        window?.overrideUserInterfaceStyle = interfaceStyle
        window?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
    }

    /// Streamora and the full player are always dark; otherwise Knight Music's chosen appearance.
    private var interfaceStyle: UIUserInterfaceStyle {
        if DuetCoordinator.shared.world == .movies || ui?.isPlayerPresented == true { return .dark }
        switch LookStore.shared.current.appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return .unspecified
        }
    }

    /// What the side underneath shows, for the overlay windows that own the status bar while visible.
    var statusBarStyle: UIStatusBarStyle {
        switch interfaceStyle {
        case .light: return .darkContent
        case .dark: return .lightContent
        default: return .default
        }
    }

    /// Visible only while a toast is up, so an idle topmost window never owns the status bar.
    func setHasToast(_ hasToast: Bool) {
        hideTask?.cancel()
        if hasToast {
            statusBarAppearanceChanged()
            window?.isHidden = false
            return
        }
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return } // let the exit transition finish
            guard let self, self.ui?.toast == nil else { return }
            self.window?.isHidden = true
        }
    }

    func install(ui: UIState) {
        self.ui = ui
        guard window == nil || window?.windowScene == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .normal + 3
        window.backgroundColor = .clear
        window.overrideUserInterfaceStyle = interfaceStyle
        let host = ToastHostingController(rootView: ToastHostView(ui: ui))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = ui.toast == nil
        self.window = window
    }
}

private final class PassthroughWindow: UIWindow {
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard hit === rootViewController?.view || hit === self else { return hit }
        let frame = MainActor.assumeIsolated { ToastWindow.shared.capsuleFrame }
        guard frame.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        return hit
    }
}

/// Topmost window: forward status-bar appearance so Streamora's hidden status bar is not overridden.
private final class ToastHostingController: UIHostingController<ToastHostView> {
    override var prefersStatusBarHidden: Bool { DuetCoordinator.shared.statusBarHidden }
    override var preferredStatusBarStyle: UIStatusBarStyle { ToastWindow.shared.statusBarStyle }
}

private struct ToastHostView: View {
    let ui: UIState
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPad: below the top tab bar. iPhone: above the tab bar and mini player, clear of navigation bars;
    /// over the full player (no navigation bar, controls at the bottom) it stays at the top.
    private var docksAtBottom: Bool { sizeClass == .compact && !ui.isPlayerPresented }

    var body: some View {
        VStack(spacing: 0) {
            if docksAtBottom { Spacer(minLength: 0) }
            if let toast = ui.toast {
                ToastCapsule(text: toast, actionTitle: ui.toastActionTitle) {
                    let action = ui.toastAction
                    ui.dismissToast()
                    action?()
                }
                .id(ui.toastID)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ToastWindow.shared.capsuleFrame = $0 }
                .transition(.move(edge: docksAtBottom ? .bottom : .top).combined(with: .opacity))
                .onAppear { AccessibilityNotification.Announcement(toast).post() }
            }
            if !docksAtBottom { Spacer(minLength: 0) }
        }
        .padding(.top, sizeClass == .regular ? 64 : 12)
        .padding(.bottom, docksAtBottom ? 120 : 0)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth, value: ui.toastID)
        .onChange(of: ui.toast) { _, new in
            if new == nil { ToastWindow.shared.capsuleFrame = .zero }
        }
        .tint(LookStore.shared.accent)
    }
}

struct ToastCapsule: View {
    let text: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.label)
                .lineLimit(2)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.bold))
                    .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}
