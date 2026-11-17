import Foundation

@main
struct StreamoraLoadFailureSmoke {
    static func main() {
        precondition(StreamoraLoadFailure(error: URLError(.cancelled)) == nil)
        precondition(StreamoraLoadFailure(error: URLError(.notConnectedToInternet)) == .offline)
        precondition(StreamoraLoadFailure(error: URLError(.timedOut)) == .network)
        precondition(StreamoraLoadFailure(error: URLError(.serverCertificateUntrusted)) == .secureConnection)
        precondition(StreamoraLoadFailure(error: NSError(domain: "WebKitErrorDomain", code: -999)) == .loadFailed)
        precondition(StreamoraLoadFailure.offline.retryOnConnection)
        precondition(!StreamoraLoadFailure.http(503).retryOnConnection)
        precondition(StreamoraLoadFailure.http(403).detail.contains("HTTP 403"))
        precondition(StreamoraLoadFailure.http(429).title == "Too many attempts")
        print("Streamora navigation failure checks passed")
    }
}
