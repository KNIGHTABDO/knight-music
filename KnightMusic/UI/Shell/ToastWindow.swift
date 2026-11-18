import SwiftUI
import UIKit

/// Hosts toasts in their own window above everything (sheets, the full player, Streamora's window), so a message
/// is never hidden by a presentation layer. Touches outside the capsule fall through.
@MainActor
final class ToastWindow {
    static let shared = ToastWindow()

    fileprivate(set) var capsuleFrame: CGRect = .zero
    private var window: PassthroughWindow?
    private var ui: UIState?
    private var hideTask: Task<Void, Never>?

    func statusBarAppearanceChanged() {
        window?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
    }

    /// Visible only while a toast is up, so an idle topmost window never owns the status bar.
    func setHasToast(_ hasToast: Bool) {
        hideTask?.cancel()
        if hasToast {
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
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

private struct ToastHostView: View {
    let ui: UIState

    var body: some View {
        VStack(spacing: 0) {
            if let toast = ui.toast {
                ToastCapsule(text: toast, actionTitle: ui.toastActionTitle) {
                    let action = ui.toastAction
                    ui.dismissToast()
                    action?()
                }
                .id(ui.toastID)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ToastWindow.shared.capsuleFrame = $0 }
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear { AccessibilityNotification.Announcement(toast).post() }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
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
