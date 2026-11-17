import UIKit
import WebKit

/// Native side of `Capacitor.Plugins.StreamoraPlayer` (see StreamoraBridgeScript): the same methods, arguments and
/// events as Streamora's own Capacitor plugin, so the live site works unchanged inside Duet.
/// Methods: play, close, extras, capabilities, engineOpen, enginePlay, enginePause, engineSeek, engineRate,
/// engineVolume, engineAudio, engineSub, engineMeta, engineAudioDelay, engineClose.
/// Events: progress, next, closed, engine, tracks, remote, metadata.
@MainActor
final class StreamoraBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var webView: WKWebView?
    weak var stage: StreamoraStageController?

    private weak var classic: StreamoraPlayerViewController?
    private var engine: VlcEngine?

    var isMoviePlaying: Bool { (engine?.isPlaying ?? false) || classic != nil }

    override init() {
        super.init()
        DuetMedia.shared.pauseMovie = { [weak self] in self?.pauseEverything() }
        DuetMedia.shared.reclaimMovie = { [weak self] in self?.engine?.reclaimLockScreen() }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else {
            replyHandler(nil, "Bad message")
            return
        }
        switch body["kind"] as? String {
        case "call":
            let method = body["method"] as? String ?? ""
            let options = body["options"] as? [String: Any] ?? [:]
            call(method, Options(options), reply: replyHandler)
        case "auth":
            let origin = message.frameInfo.securityOrigin
            guard origin.`protocol` == "https", origin.host == StreamoraStageController.home.host,
                  origin.port == 0 || origin.port == 443,
                  let urlString = body["url"] as? String, let url = URL(string: urlString),
                  let state = body["state"] as? String, let stage else {
                replyHandler(nil, "Invalid sign-in request")
                return
            }
            stage.startAuthentication(url, state: state) { error in
                if let error { replyHandler(nil, error) } else { replyHandler(["completed": true], nil) }
            }
        case "media":
            if body["active"] as? Bool == true { DuetMedia.shared.movieStarted(.web) } else { DuetMedia.shared.movieStopped(.web) }
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "Unknown message")
        }
    }

    /// Fires a plugin event to the page's listeners.
    func emit(_ event: String, _ data: [String: Any]) {
        guard let webView else { return }
        webView.callAsyncJavaScript("window.__duet && window.__duet.emit(e, d)", arguments: ["e": event, "d": data],
                                    in: nil, in: .page, completionHandler: nil)
    }

    /// Switching to Knight Music pauses whatever movie is on screen.
    func pauseEverything() {
        engine?.pauseFromApp()
        classic?.pauseFromApp()
        webView?.pauseAllMediaPlayback(completionHandler: nil)
    }

    /// Reloading the site or clearing its data closes the native players first.
    func tearDown() {
        classic?.finish()
        closeEngine()
        DuetMedia.shared.movieStopped(.web)
    }

    private func sender() -> (String, [String: Any]) -> Void {
        { [weak self] event, data in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.emit(event, data) }
            } else {
                DispatchQueue.main.async { self?.emit(event, data) }
            }
        }
    }

    private func call(_ method: String, _ o: Options, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        switch method {
        case "capabilities":
            // An empty version turns off Streamora's own update prompt: Knight Music's updater covers Duet.
            reply(["engine": true, "authSession": true, "version": "", "build": "", "host": "duet"], nil)
        case "engineOpen":
            guard let s = o.string("url"), let url = URL(string: s) else { return reply(nil, "No playable link") }
            engine?.close()
            engine = nil
            guard let webView else { return reply(nil, "No view to play in") }
            DuetMedia.shared.movieStarted(.engine)
            guard let e = VlcEngine(webView: webView, url: url, start: o.double("start") ?? 0,
                                    audioLang: o.string("audioLang") ?? "", title: o.string("title") ?? "",
                                    subtitle: o.string("subtitle") ?? "", poster: o.string("poster") ?? "",
                                    send: sender())
            else {
                DuetMedia.shared.movieStopped(.engine)
                stage?.statusBarHidden = false
                return reply(nil, "No view to play in")
            }
            engine = e
            let delay = o.double("audioDelay") ?? 0
            if delay != 0 { e.setAudioDelay(delay) }
            stage?.statusBarHidden = true
            reply(nil, nil)
        case "enginePlay":
            if let engine {
                DuetMedia.shared.movieStarted(.engine)
                engine.play()
            }
            reply(nil, nil)
        case "enginePause": engine?.pause(); reply(nil, nil)
        case "engineSeek": engine?.seek(o.double("time") ?? 0); reply(nil, nil)
        case "engineRate": engine?.setRate(o.double("rate") ?? 1); reply(nil, nil)
        case "engineVolume": engine?.setVolume(o.double("volume") ?? 1, muted: o.bool("muted") ?? false); reply(nil, nil)
        case "engineAudio": engine?.setAudio(o.int32("id") ?? -1); reply(nil, nil)
        case "engineSub": engine?.setSub(o.int32("id") ?? -1); reply(nil, nil)
        case "engineMeta":
            engine?.setMeta(title: o.string("title") ?? "", subtitle: o.string("subtitle") ?? "", poster: o.string("poster") ?? "")
            reply(nil, nil)
        case "engineAudioDelay": engine?.setAudioDelay(o.double("seconds") ?? 0); reply(nil, nil)
        case "engineClose":
            closeEngine()
            reply(nil, nil)
        case "play":
            play(o, reply: reply)
        case "extras":
            classic?.setExtras(subs: o.subs(), intro: o.range("intro"), outro: o.range("outro"))
            reply(nil, nil)
        case "close":
            classic?.finish(notify: false)
            reply(nil, nil)
        default:
            reply(nil, "\(method) is not implemented on iOS")
        }
    }

    private func closeEngine() {
        guard let engine else { return }
        engine.close()
        self.engine = nil
        stage?.statusBarHidden = false
        DuetMedia.shared.movieStopped(.engine)
    }

    private func play(_ o: Options, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let s = o.string("url"), let url = URL(string: s) else { return reply(nil, "No playable link") }
        guard let host = stage else { return reply(nil, "No view to present from") }
        let options = StreamoraPlayerOptions(
            url: url, title: o.string("title") ?? "", subtitle: o.string("subtitle") ?? "",
            start: o.double("start") ?? 0, hasNext: o.bool("hasNext") ?? false,
            audioLang: o.string("audioLang") ?? "", subsLang: o.string("subsLang") ?? ""
        )
        classic?.finish(notify: false)
        DuetMedia.shared.movieStarted(.classic)
        let vc = StreamoraPlayerViewController(options: options, send: sender())
        vc.onFinish = { DuetMedia.shared.movieStopped(.classic) }
        vc.onPlay = { DuetMedia.shared.movieStarted(.classic) }
        vc.modalPresentationStyle = .fullScreen
        classic = vc
        var top: UIViewController = host
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(vc, animated: true) { reply(nil, nil) }
    }
}

/// Typed reads of a plugin call's options (numbers arrive as NSNumber from the page).
private struct Options {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func string(_ key: String) -> String? { raw[key] as? String }
    func double(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }
    func bool(_ key: String) -> Bool? { (raw[key] as? NSNumber)?.boolValue }
    func int32(_ key: String) -> Int32? { (raw[key] as? NSNumber)?.int32Value }

    func subs() -> [StreamoraOnlineSub] {
        (raw["subs"] as? [Any] ?? []).compactMap { item in
            guard let d = item as? [String: Any], let u = d["url"] as? String, let url = URL(string: u) else { return nil }
            return StreamoraOnlineSub(label: d["label"] as? String ?? "Subtitles", lang: d["lang"] as? String ?? "", url: url)
        }
    }

    func range(_ key: String) -> (Double, Double)? {
        guard let a = raw[key] as? [Any], a.count == 2,
              let x = (a[0] as? NSNumber)?.doubleValue, let y = (a[1] as? NSNumber)?.doubleValue, y > x else { return nil }
        return (x, y)
    }
}
