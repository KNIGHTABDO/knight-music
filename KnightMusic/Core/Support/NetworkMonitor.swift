import Foundation
import Network

/// Observable view of the current network path. `onChange` fires (on the main actor) whenever the path's
/// reachability or interface set actually changes, never for the initial report.
@MainActor @Observable
final class NetworkMonitor {
    private(set) var isConnected = true
    private(set) var isExpensive = false
    private(set) var isWiFi = false
    private(set) var isCellular = false
    private(set) var changeCount = 0

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var lastSignature: String?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.apply(path) }
        }
        monitor.start(queue: DispatchQueue(label: "com.knightabdo.knightmusic.network", qos: .utility))
    }

    private func apply(_ path: NWPath) {
        let connected = path.status == .satisfied
        let wifi = path.usesInterfaceType(.wifi)
        let cellular = path.usesInterfaceType(.cellular)
        let wired = path.usesInterfaceType(.wiredEthernet)
        isConnected = connected
        isExpensive = path.isExpensive
        isWiFi = wifi
        isCellular = cellular
        // Interface names and gateways too: Wi-Fi to Wi-Fi, or a VPN/Tailscale toggle, keeps the type flags identical.
        let interfaces = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        let signature = "\(connected)|\(wifi)|\(cellular)|\(wired)|\(path.isExpensive)|\(path.isConstrained)|\(interfaces)|\(gateways)"
        defer { lastSignature = signature }
        guard let previous = lastSignature, previous != signature else { return }
        changeCount += 1
        Log.network.info("path changed: connected=\(connected) wifi=\(wifi) cellular=\(cellular) expensive=\(path.isExpensive)")
        onChange?()
    }
}
