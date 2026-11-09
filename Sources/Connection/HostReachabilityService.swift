// Connection — Non-blocking TCP reachability pre-check for saved Mac profiles.
import Foundation
import Network
import Observation

public enum HostReachabilityStatus: Sendable, Equatable {
    case unknown
    case checking
    case online
    case offline

    public var label: String {
        switch self {
        case .unknown: "Not Checked"
        case .checking: "Checking…"
        case .online: "Online"
        case .offline: "Offline"
        }
    }
}

@Observable
@MainActor
public final class HostReachabilityService {
    public static let shared = HostReachabilityService()

    public private(set) var statusByProfileID: [UUID: HostReachabilityStatus] = [:]

    private var activeProbes: [UUID: NWConnection] = [:]
    private var probeTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String = ""
    private var isSeededForTesting = false

    public init() {}

    /// Starts observing network interface transitions (Wi-Fi, cellular, VPN) and probes all profiles.
    public func startMonitoring(profiles: [ConnectionProfile]) {
        guard !isSeededForTesting else { return }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
                let signature = "\(path.status)-\(interfaces)"
                Task { [weak self] in
                    await self?.handlePathChange(signature: signature)
                }
            }
            monitor.start(queue: .main)
            pathMonitor = monitor
        }
        refreshAll(profiles: profiles)
    }

    public func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        cancelAllProbes()
    }

    public func status(for profileID: UUID) -> HostReachabilityStatus {
        statusByProfileID[profileID] ?? .unknown
    }

    /// Probes all provided profiles concurrently with a short TCP handshake timeout.
    public func refreshAll(profiles: [ConnectionProfile]) {
        guard !isSeededForTesting else { return }
        let validIDs = Set(profiles.map(\.id))
        for existingID in Array(statusByProfileID.keys) where !validIDs.contains(existingID) {
            cancelProbe(for: existingID)
            statusByProfileID.removeValue(forKey: existingID)
        }
        for profile in profiles {
            probe(profile)
        }
    }

    /// Probes a single connection profile's TCP endpoint.
    public func probe(_ profile: ConnectionProfile) {
        guard !isSeededForTesting else { return }
        let profileID = profile.id
        cancelProbe(for: profileID)

        let trimmedHost = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              (1 ... 65535).contains(profile.port),
              let port = NWEndpoint.Port(rawValue: UInt16(profile.port))
        else {
            statusByProfileID[profileID] = .offline
            return
        }

        if statusByProfileID[profileID] == nil || statusByProfileID[profileID] == .unknown {
            statusByProfileID[profileID] = .checking
        }

        let endpointHost = NWEndpoint.Host(trimmedHost)
        let connection = NWConnection(host: endpointHost, port: port, using: .tcp)
        activeProbes[profileID] = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.handleProbeState(state, for: profileID, connection: connection)
            }
        }
        connection.start(queue: .main)

        probeTimeoutTasks[profileID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(2500))
            } catch {
                return
            }
            self?.handleProbeTimeout(for: profileID, connection: connection)
        }
    }

    /// Preloads deterministic reachability states for UI tests and App Store screenshots.
    public func seedSampleStatuses(_ statuses: [UUID: HostReachabilityStatus]) {
        isSeededForTesting = true
        cancelAllProbes()
        statusByProfileID = statuses
    }

    /// Directly records a known reachability state (e.g. after a live session connects or fails).
    public func recordStatus(_ status: HostReachabilityStatus, for profileID: UUID) {
        cancelProbe(for: profileID)
        statusByProfileID[profileID] = status
    }

    private func handlePathChange(signature: String) {
        guard !isSeededForTesting, signature != lastPathSignature else { return }
        lastPathSignature = signature
        refreshAll(profiles: ProfileStore.shared.profiles)
    }

    private func handleProbeState(
        _ state: NWConnection.State,
        for profileID: UUID,
        connection: NWConnection
    ) {
        guard activeProbes[profileID] === connection else { return }
        switch state {
        case .ready:
            cancelProbe(for: profileID)
            statusByProfileID[profileID] = .online
        case .failed, .waiting:
            cancelProbe(for: profileID)
            statusByProfileID[profileID] = .offline
        case .cancelled:
            cancelProbe(for: profileID)
        default:
            break
        }
    }

    private func handleProbeTimeout(for profileID: UUID, connection: NWConnection) {
        guard activeProbes[profileID] === connection else { return }
        cancelProbe(for: profileID)
        statusByProfileID[profileID] = .offline
    }

    private func cancelProbe(for profileID: UUID) {
        probeTimeoutTasks[profileID]?.cancel()
        probeTimeoutTasks.removeValue(forKey: profileID)
        if let conn = activeProbes.removeValue(forKey: profileID) {
            conn.stateUpdateHandler = nil
            conn.cancel()
        }
    }

    private func cancelAllProbes() {
        for id in Array(activeProbes.keys) {
            cancelProbe(for: id)
        }
        for (_, task) in probeTimeoutTasks {
            task.cancel()
        }
        probeTimeoutTasks.removeAll()
    }
}
