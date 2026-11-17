import Foundation

enum StreamoraLoadFailure: Equatable {
    case offline, network, secureConnection, loadFailed, http(Int)

    init?(error: Error) {
        let failure = error as NSError
        guard failure.domain == NSURLErrorDomain else { self = .loadFailed; return }
        switch failure.code {
        case NSURLErrorCancelled: return nil
        case NSURLErrorNotConnectedToInternet:
            self = .offline
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
            self = .network
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid:
            self = .secureConnection
        default:
            self = .loadFailed
        }
    }

    var retryOnConnection: Bool { self == .offline || self == .network }

    var title: String {
        switch self {
        case .offline: "You’re offline"
        case .network: "Couldn’t reach Streamora"
        case .secureConnection: "Couldn’t connect securely"
        case .http(429): "Too many attempts"
        case .http: "Streamora couldn’t open this page"
        case .loadFailed: "Streamora couldn’t finish loading"
        }
    }

    var detail: String {
        switch self {
        case .offline: "Connect to Wi-Fi or cellular data. Duet will retry when it can connect."
        case .network: "Streamora may be temporarily unavailable. Try again in a moment."
        case .secureConnection: "Check the network and your device’s date and time, then try again."
        case .http(429): "Wait a moment before trying again."
        case .http(let status): "Streamora returned HTTP \(status). Try again in a moment."
        case .loadFailed: "Try again to reload Movies."
        }
    }
}
