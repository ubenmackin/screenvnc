// Connection — Non-blocking RFB greeting pre-check for saved Mac profiles.
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

    static let probeDeadline: Duration = .milliseconds(2500)
    static let serverBannerLength = 12
    static let statusTTL: TimeInterval = 30

    public private(set) var statusByProfileID: [UUID: HostReachabilityStatus] = [:]
    private(set) var lastCheckedAtByProfileID: [UUID: Date] = [:]

    private var activeProbes: [UUID: NWConnection] = [:]
    private var bannerBuffers: [UUID: Data] = [:]
    private var bannerReadsInFlight: Set<UUID> = []
    private var probeTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String = ""
    private var isSeededForTesting = false
    private var monitoredProfiles: [ConnectionProfile] = []
    private var periodicRefreshTask: Task<Void, Never>?
    private var isRefreshActive = true

    public init() {}

    /// Accepts only a complete RFB 3.x greeting; anything else fails the probe closed.
    static func isValidServerBanner(_ data: Data) -> Bool {
        guard data.count == serverBannerLength,
              data.prefix(8) == Data("RFB 003.".utf8)
        else { return false }
        let minorVersion = data.dropFirst(8).prefix(3)
        guard minorVersion.allSatisfy({ (0x30 ... 0x39).contains($0) }) else { return false }
        return data.last == 0x0A
    }

    /// Missing timestamps count as stale so a never-probed profile still refreshes.
    static func isStale(lastChecked: Date?, now: Date, ttl: TimeInterval = statusTTL) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= ttl
    }

    /// In-flight probes are excluded so a slow host is not restarted on every tick.
    static func profilesNeedingRefresh(
        _ profiles: [ConnectionProfile],
        lastChecked: [UUID: Date],
        activeProbeIDs: Set<UUID>,
        now: Date,
        ttl: TimeInterval = statusTTL
    ) -> [ConnectionProfile] {
        profiles.filter { profile in
            !activeProbeIDs.contains(profile.id) &&
                isStale(lastChecked: lastChecked[profile.id], now: now, ttl: ttl)
        }
    }

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
        monitoredProfiles = profiles
        refreshAll(profiles: profiles)
        startPeriodicRefresh()
    }

    public func stopMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
        cancelAllProbes()
        monitoredProfiles = []
    }

    public func status(for profileID: UUID) -> HostReachabilityStatus {
        statusByProfileID[profileID] ?? .unknown
    }

    /// Probes all provided profiles concurrently with a short RFB greeting timeout.
    public func refreshAll(profiles: [ConnectionProfile]) {
        guard !isSeededForTesting else { return }
        monitoredProfiles = profiles
        pruneRemovedProfiles(profiles)
        for profile in profiles {
            probe(profile)
        }
    }

    /// Re-probes only statuses older than the TTL, leaving fresh and in-flight probes alone.
    public func refreshStale(profiles: [ConnectionProfile]) {
        guard !isSeededForTesting else { return }
        monitoredProfiles = profiles
        pruneRemovedProfiles(profiles)
        let staleProfiles = Self.profilesNeedingRefresh(
            profiles,
            lastChecked: lastCheckedAtByProfileID,
            activeProbeIDs: Set(activeProbes.keys),
            now: Date()
        )
        for profile in staleProfiles {
            probe(profile)
        }
    }

    /// Foreground ticks resume freshness checks; background ticks are skipped, not cancelled.
    public func setSceneActive(_ active: Bool) {
        isRefreshActive = active
        guard active else { return }
        refreshStale(profiles: monitoredProfiles)
    }

    /// Probes a single profile's endpoint; Online requires a valid RFB greeting.
    public func probe(_ profile: ConnectionProfile) {
        guard !isSeededForTesting else { return }
        let profileID = profile.id
        cancelProbe(for: profileID)

        let trimmedHost = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              (1 ... 65535).contains(profile.port),
              let port = NWEndpoint.Port(rawValue: UInt16(profile.port))
        else {
            finishProbe(profileID, status: .offline)
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
                try await Task.sleep(for: Self.probeDeadline)
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
        let now = Date()
        var stamps: [UUID: Date] = [:]
        for profileID in statuses.keys {
            stamps[profileID] = now
        }
        lastCheckedAtByProfileID = stamps
    }

    /// Directly records a known reachability state (e.g. after a live session connects or fails).
    public func recordStatus(_ status: HostReachabilityStatus, for profileID: UUID) {
        cancelProbe(for: profileID)
        statusByProfileID[profileID] = status
        lastCheckedAtByProfileID[profileID] = Date()
    }

    private func handlePathChange(signature: String) {
        guard !isSeededForTesting, signature != lastPathSignature else { return }
        lastPathSignature = signature
        refreshAll(profiles: monitoredProfiles)
    }

    private func handleProbeState(
        _ state: NWConnection.State,
        for profileID: UUID,
        connection: NWConnection
    ) {
        guard activeProbes[profileID] === connection else { return }
        switch state {
        case .ready:
            readBannerChunk(for: profileID, connection: connection)
        case .failed:
            finishProbe(profileID, status: .offline)
        case .cancelled:
            cancelProbe(for: profileID)
        default:
            // Waiting and transitional states keep the deadline running.
            break
        }
    }

    private func readBannerChunk(for profileID: UUID, connection: NWConnection) {
        // One outstanding receive per probe; repeated ready transitions must not over-read.
        guard activeProbes[profileID] === connection,
              !bannerReadsInFlight.contains(profileID)
        else { return }
        let buffered = bannerBuffers[profileID] ?? Data()
        let remaining = Self.serverBannerLength - buffered.count
        guard remaining > 0 else {
            finishProbe(profileID, status: Self.isValidServerBanner(buffered) ? .online : .offline)
            return
        }

        bannerReadsInFlight.insert(profileID)
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            let hasError = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.activeProbes[profileID] === connection else { return }
                self.bannerReadsInFlight.remove(profileID)
                self.handleBannerChunk(
                    data,
                    isComplete: isComplete,
                    hasError: hasError,
                    for: profileID,
                    connection: connection
                )
            }
        }
    }

    private func handleBannerChunk(
        _ data: Data?,
        isComplete: Bool,
        hasError: Bool,
        for profileID: UUID,
        connection: NWConnection
    ) {
        guard activeProbes[profileID] === connection else { return }

        if let data, !data.isEmpty {
            var buffer = bannerBuffers[profileID] ?? Data()
            buffer.append(data.prefix(Self.serverBannerLength - buffer.count))
            bannerBuffers[profileID] = buffer
            if buffer.count == Self.serverBannerLength {
                finishProbe(profileID, status: Self.isValidServerBanner(buffer) ? .online : .offline)
                return
            }
        }

        // A close or error before the full greeting arrives fails closed.
        if hasError || isComplete {
            finishProbe(profileID, status: .offline)
            return
        }
        readBannerChunk(for: profileID, connection: connection)
    }

    private func handleProbeTimeout(for profileID: UUID, connection: NWConnection) {
        guard activeProbes[profileID] === connection else { return }
        finishProbe(profileID, status: .offline)
    }

    private func finishProbe(_ profileID: UUID, status: HostReachabilityStatus) {
        cancelProbe(for: profileID)
        statusByProfileID[profileID] = status
        lastCheckedAtByProfileID[profileID] = Date()
    }

    private func startPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.statusTTL))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                guard self.isRefreshActive, !self.isSeededForTesting else { continue }
                self.refreshStale(profiles: self.monitoredProfiles)
            }
        }
    }

    /// Deleted profiles must not leave status or freshness entries behind.
    private func pruneRemovedProfiles(_ profiles: [ConnectionProfile]) {
        let validIDs = Set(profiles.map(\.id))
        let knownIDs = Set(statusByProfileID.keys).union(lastCheckedAtByProfileID.keys)
        for profileID in knownIDs where !validIDs.contains(profileID) {
            cancelProbe(for: profileID)
            statusByProfileID.removeValue(forKey: profileID)
            lastCheckedAtByProfileID.removeValue(forKey: profileID)
        }
    }

    private func cancelProbe(for profileID: UUID) {
        probeTimeoutTasks[profileID]?.cancel()
        probeTimeoutTasks.removeValue(forKey: profileID)
        bannerBuffers.removeValue(forKey: profileID)
        bannerReadsInFlight.remove(profileID)
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
