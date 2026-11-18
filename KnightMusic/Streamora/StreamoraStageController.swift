import UIKit
import WebKit
import AuthenticationServices
import Network

/// Streamora's side of Duet: the live Streamora site in a full-screen web view, with the native player bridge.
/// It lives in its own window above Knight Music, so nothing in Knight Music is torn down while you watch.
@MainActor
final class StreamoraStageController: UIViewController, WKNavigationDelegate, WKUIDelegate, ASWebAuthenticationPresentationContextProviding {
    static let home = URL(string: "https://streamora-5w5.pages.dev")!
    private static let background = UIColor(red: 0x14 / 255, green: 0x12 / 255, blue: 0x10 / 255, alpha: 1)

    let bridge = StreamoraBridge()
    private(set) var webView: WKWebView!
    private var hasLoaded = false
    private var recoveryView: StreamoraRecoveryView?
    private var activeNavigation: WKNavigation?
    private var reconnectMonitor: NWPathMonitor?
    private var connectionReady = false
    private var usedAutomaticRetry = false
    private var authenticationSession: ASWebAuthenticationSession?
    private var authenticationID: UUID?

    var statusBarHidden = false {
        didSet { if oldValue != statusBarHidden { setNeedsStatusBarAppearanceUpdate() } }
    }

    override var prefersStatusBarHidden: Bool { statusBarHidden }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { statusBarHidden }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.websiteDataStore = .default()
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: StreamoraBridgeScript.source, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true, in: .page))
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: "duet")
        config.userContentController = content

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.isOpaque = true
        web.backgroundColor = Self.background
        web.scrollView.backgroundColor = Self.background
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        #if DEBUG
        web.isInspectable = true
        #endif
        web.translatesAutoresizingMaskIntoConstraints = false
        webView = web
        bridge.webView = web
        bridge.stage = self

        let root = UIView()
        root.backgroundColor = Self.background
        root.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.topAnchor.constraint(equalTo: root.topAnchor),
            web.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    /// Load on the first switch to Movies.
    func loadIfNeeded() {
        loadViewIfNeeded()
        guard !hasLoaded else { return }
        beginHomeLoad()
    }

    func reload() {
        loadViewIfNeeded()
        usedAutomaticRetry = false
        beginHomeLoad()
    }

    private func beginHomeLoad() {
        stopWatchingConnection()
        cancelAuthentication()
        bridge.tearDown()
        statusBarHidden = false
        hasLoaded = true
        recoveryView?.showConnecting()
        activeNavigation = webView.load(URLRequest(url: Self.home))
    }

    /// Signs out of Streamora on this device: cookies, localStorage, IndexedDB and caches for the site.
    func clearWebsiteData() async {
        loadViewIfNeeded()
        cancelAuthentication()
        bridge.tearDown()
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        hasLoaded = false
        reload()
    }

    // MARK: - navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "duet" {
            decisionHandler(.cancel)
            if url.host == "retry" { reload() }
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        let local = ["about", "data", "blob"].contains(url.scheme ?? "")
        if local || !isMainFrame && navigationAction.targetFrame != nil || url.host == Self.home.host {
            return decisionHandler(.allow)
        }
        // Links that leave the site (IMDb, Google sign-in pages, trailers) open outside, like the Streamora app did.
        decisionHandler(.cancel)
        UIApplication.shared.open(url)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activeNavigation = navigation
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard response.isForMainFrame, let http = response.response as? HTTPURLResponse,
              http.url?.host == Self.home.host, http.statusCode >= 400 else {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        Log.app.error("Streamora navigation returned HTTP \(http.statusCode)")
        showFailure(.http(http.statusCode))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(navigation, error: error)
    }

    private func handleNavigationFailure(_ navigation: WKNavigation?, error: Error) {
        let nsError = error as NSError
        // 102 "Frame load interrupted" follows our own policy cancel of an HTTP error: keep the specific .http screen
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        guard navigation === activeNavigation, let failure = StreamoraLoadFailure(error: error) else { return }
        Log.app.error("Streamora navigation failed (\(nsError.domain) \(nsError.code))")
        showFailure(failure)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation, webView.url?.host == Self.home.host else { return }
        stopWatchingConnection()
        recoveryView?.removeFromSuperview()
        recoveryView = nil
        webView.accessibilityElementsHidden = false
        usedAutomaticRetry = false
        publishDuetVisibility()
    }

    func publishDuetVisibility() {
        retryWhenVisible()
        guard let webView, let url = webView.url, url.scheme == "https", url.host == Self.home.host,
              url.port == nil || url.port == 443 else { return }
        let visible = viewIfLoaded?.window?.isHidden == false
        webView.evaluateJavaScript("window.__duet?.setVisible?.(\(visible))", completionHandler: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.app.error("Streamora web content process ended")
        cancelAuthentication()
        bridge.tearDown()
        statusBarHidden = false
        if viewIfLoaded?.window?.isHidden == false {
            activeNavigation = webView.reload()
            if activeNavigation == nil { beginHomeLoad() }
        } else {
            hasLoaded = false
        }
    }

    private func showFailure(_ failure: StreamoraLoadFailure) {
        stopWatchingConnection()
        let recovery: StreamoraRecoveryView
        if let existing = recoveryView {
            recovery = existing
        } else {
            recovery = StreamoraRecoveryView(background: Self.background, retry: { [weak self] in self?.reload() },
                                             showMusic: { DuetCoordinator.shared.open(.music) })
            view.addSubview(recovery)
            NSLayoutConstraint.activate([
                recovery.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                recovery.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
                recovery.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                recovery.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
            recoveryView = recovery
        }
        webView.accessibilityElementsHidden = true
        recovery.show(failure)
        guard failure.retryOnConnection, !usedAutomaticRetry else { return }
        let monitor = NWPathMonitor()
        reconnectMonitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            let ready = path.status == .satisfied
            Task { @MainActor in
                guard let self, let monitor, self.reconnectMonitor === monitor else { return }
                self.connectionReady = ready
                self.retryWhenVisible()
            }
        }
        monitor.start(queue: DispatchQueue(label: "Streamora reconnect"))
    }

    private func retryWhenVisible() {
        guard connectionReady, !usedAutomaticRetry, viewIfLoaded?.window?.isHidden == false else { return }
        usedAutomaticRetry = true
        beginHomeLoad()
    }

    private func stopWatchingConnection() {
        reconnectMonitor?.cancel()
        reconnectMonitor = nil
        connectionReady = false
    }

    /// Opens Google's server-side OAuth flow in Apple's system authentication browser.
    /// The return URL carries only a one-time state signal; the Streamora page redeems approval
    /// over its own first-party connection and receives its session cookie there.
    func startAuthentication(_ url: URL, state: String,
                             completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard authenticationSession == nil else { completion("A sign-in is already open."); return }
        guard viewIfLoaded?.window?.isHidden == false else { completion("Open Movies to sign in."); return }
        guard url.scheme == "https", url.host == Self.home.host, url.path == "/login",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              components?.queryItems?.first(where: { $0.name == "native" })?.value == state,
              components?.queryItems?.contains(where: { $0.name == "code" && $0.value?.range(of: #"^\d{8}$"#, options: .regularExpression) != nil }) == true,
              state.range(of: #"^[A-Za-z0-9_-]{20,80}$"#, options: .regularExpression) != nil else {
            completion("Invalid sign-in request."); return
        }
        let id = UUID()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "knightmusic") { [weak self] callback, error in
            Task { @MainActor in
                guard let self, self.authenticationID == id else { return }
                self.authenticationSession = nil
                self.authenticationID = nil
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    completion(cancelled ? "Sign-in was cancelled." : "Sign-in did not complete.")
                    return
                }
                guard let callback, callback.scheme == "knightmusic", callback.host == "streamora-auth",
                      URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value == state else {
                    completion("Sign-in returned an invalid response."); return
                }
                completion(nil)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authenticationSession = session
        authenticationID = id
        guard session.start() else {
            authenticationSession = nil
            authenticationID = nil
            completion("Could not open secure sign-in.")
            return
        }
    }

    private func cancelAuthentication() {
        authenticationID = nil
        authenticationSession?.cancel()
        authenticationSession = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = viewIfLoaded?.window { return window }
        return UIWindow(frame: .zero)
    }

    // MARK: - JavaScript dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presentDialog(alert) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presentDialog(alert) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        presentDialog(alert) { completionHandler(nil) }
    }

    /// WebKit requires every dialog handler to be called, so a dialog that cannot be shown answers right away.
    private func presentDialog(_ alert: UIAlertController, fallback: () -> Void) {
        var top: UIViewController = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard view.window != nil, !(top is UIAlertController) else { return fallback() }
        top.present(alert, animated: true)
    }
}
