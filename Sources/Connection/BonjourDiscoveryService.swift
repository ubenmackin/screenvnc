// Connection — Bonjour mDNS service discovery for local Mac hosts.
import Combine
import Foundation
import Network

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

@MainActor
public final class BonjourDiscoveryService: ObservableObject {
    public static let shared = BonjourDiscoveryService()

    @Published public private(set) var discoveredHosts: [DiscoveredHost] = []
    @Published public private(set) var isScanning: Bool = false

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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resultsByService[serviceType] = results
                let merged = self.resultsByService.values.reduce(into: Set<NWBrowser.Result>()) { $0.formUnion($1) }
                self.handleResults(merged)
            }
        }
        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready: self?.isScanning = true
                case .failed, .cancelled: self?.isScanning = false
                default: break
                }
            }
        }

        newBrowser.start(queue: .main)
        browsers.append(newBrowser)
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
