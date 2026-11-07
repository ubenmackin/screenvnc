// Connection — Bonjour mDNS service discovery for local Mac hosts.
import Foundation
import Network
import Observation

public struct DiscoveredHost: Identifiable, Sendable, Hashable {
    public var id: String {
        "\(name):\(host):\(port)"
    }

    public let name: String
    public let host: String
    public let port: Int

    public init(name: String, host: String, port: Int) {
        self.name = name
        self.host = host
        self.port = port
    }
}

@Observable
@MainActor
public final class BonjourDiscoveryService {
    public static let shared = BonjourDiscoveryService()

    public private(set) var discoveredHosts: [DiscoveredHost] = []
    public private(set) var isScanning: Bool = false

    private var browsers: [NWBrowser] = []
    private var resultsByService: [String: Set<NWBrowser.Result>] = [:]

    public init() {}

    public func startDiscovery() {
        guard browsers.isEmpty else { return }
        for serviceType in ["_rfb._tcp", "_screensharing._tcp"] {
            startBrowser(serviceType: serviceType)
        }
    }

    private func startBrowser(serviceType: String) {
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let newBrowser = NWBrowser(for: descriptor, using: parameters)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { [weak self] in
                await self?.updateDiscoveredResults(results, for: serviceType)
            }
        }
        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.updateScanState(state)
            }
        }

        newBrowser.start(queue: .main)
        browsers.append(newBrowser)
    }

    private func updateDiscoveredResults(_ results: Set<NWBrowser.Result>, for serviceType: String) {
        resultsByService[serviceType] = results
        let merged = resultsByService.values.reduce(into: Set<NWBrowser.Result>()) { $0.formUnion($1) }
        handleResults(merged)
    }

    private func updateScanState(_ state: NWBrowser.State) {
        switch state {
        case .ready: isScanning = true
        case .failed, .cancelled: isScanning = false
        default: break
        }
    }

    public func stopDiscovery() {
        for browser in browsers {
            browser.cancel()
        }
        browsers.removeAll()
        resultsByService.removeAll()
        isScanning = false
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        var hosts: [DiscoveredHost] = []
        for result in results {
            switch result.endpoint {
            case let .hostPort(host, port):
                let hostString = "\(host)".trimmingCharacters(in: .whitespacesAndNewlines)
                guard !hostString.isEmpty else { continue }
                let resolvedPort = Int(port.rawValue)
                guard (1 ... 65535).contains(resolvedPort) else { continue }
                let hostEntry = DiscoveredHost(name: hostString, host: hostString, port: resolvedPort)
                guard seen.insert(hostEntry.id).inserted else { continue }
                hosts.append(hostEntry)
            case let .service(name, _, _, _):
                // Unresolved service carries no port; default 5900 keeps dialing viable.
                let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanName.isEmpty else { continue }
                let hostName = "\(cleanName).local"
                let hostEntry = DiscoveredHost(name: cleanName, host: hostName, port: 5900)
                guard seen.insert(hostEntry.id).inserted else { continue }
                hosts.append(hostEntry)
            default:
                continue
            }
        }
        discoveredHosts = hosts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
