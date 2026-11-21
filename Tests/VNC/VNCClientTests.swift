// Tests — ScreenVNC client security negotiation, error diagnostics, and reachability coverage.
@testable import ScreenVNC
import XCTest

final class VNCClientTests: XCTestCase {
    func testClientInit() {
        _ = VNCClient()
        XCTAssertTrue(true)
    }

    func testChooseSecurityTypeUpgradesVNCDESToAppleDHWhenUsernamePresent() async throws {
        let client = VNCClient()
        let serverTypes = Data([RFBConstants.SecurityType.appleDH.rawValue])
        let chosen = try await client.chooseSecurityType(
            from: serverTypes,
            preferred: .vncDES,
            username: "admin",
            host: "192.168.1.10"
        )
        XCTAssertEqual(chosen, .appleDH)
    }

    func testChooseSecurityTypeVNCDESWithoutUsernameExplainsAppleDHRequirement() async {
        let client = VNCClient()
        let serverTypes = Data([RFBConstants.SecurityType.appleDH.rawValue])
        do {
            _ = try await client.chooseSecurityType(
                from: serverTypes,
                preferred: .vncDES,
                username: "",
                host: "macbookair.local"
            )
            XCTFail("Expected authenticationRejected when username is missing for Apple DH server")
        } catch let VNCAuthError.authenticationRejected(reason) {
            XCTAssertTrue(reason.contains("Apple DH"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConnectionFailureErrorMentionsVPNForLocalHost() {
        let err = VNCClient.connectionFailureError(
            for: CancellationError(),
            host: "macbookair.local",
            port: 5900
        )
        XCTAssertTrue(err.localizedDescription.contains(".local"))
        XCTAssertTrue(err.localizedDescription.contains("VPN"))
    }

    @MainActor
    func testServerBannerValidationAcceptsSupportedRFBGreetings() {
        XCTAssertTrue(HostReachabilityService.isValidServerBanner(Data("RFB 003.008\n".utf8)))
        XCTAssertTrue(HostReachabilityService.isValidServerBanner(Data("RFB 003.889\n".utf8)))
    }

    @MainActor
    func testServerBannerValidationRejectsNonRFBPayloads() {
        XCTAssertFalse(HostReachabilityService.isValidServerBanner(Data("HTTP/1.1 200".utf8)))
        XCTAssertFalse(HostReachabilityService.isValidServerBanner(Data("RFB 003.008".utf8)))
        XCTAssertFalse(HostReachabilityService.isValidServerBanner(Data("RFB 003.008\r".utf8)))
        XCTAssertFalse(HostReachabilityService.isValidServerBanner(Data("RFB 003.0A8\n".utf8)))
    }

    @MainActor
    func testHostReachabilityServiceRecordAndSeed() {
        let service = HostReachabilityService()
        let id1 = UUID()
        let id2 = UUID()
        XCTAssertEqual(service.status(for: id1), .unknown)

        service.recordStatus(.online, for: id1)
        XCTAssertEqual(service.status(for: id1), .online)

        service.seedSampleStatuses([id1: .online, id2: .offline])
        XCTAssertEqual(service.status(for: id1), .online)
        XCTAssertEqual(service.status(for: id2), .offline)
        XCTAssertNotNil(service.lastCheckedAtByProfileID[id1])
        XCTAssertNotNil(service.lastCheckedAtByProfileID[id2])
    }

    @MainActor
    func testNeverCheckedStatusIsStale() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertTrue(HostReachabilityService.isStale(lastChecked: nil, now: now))
    }

    @MainActor
    func testStatusFreshnessBoundaryAtThirtySeconds() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertFalse(HostReachabilityService.isStale(lastChecked: now.addingTimeInterval(-29.9), now: now))
        XCTAssertTrue(HostReachabilityService.isStale(lastChecked: now.addingTimeInterval(-30), now: now))
    }

    @MainActor
    func testProfilesNeedingRefreshSkipsFreshAndInFlightProfiles() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let neverChecked = ConnectionProfile(host: "never.local")
        let expired = ConnectionProfile(host: "expired.local")
        let fresh = ConnectionProfile(host: "fresh.local")
        let inFlight = ConnectionProfile(host: "inflight.local")

        let needingRefresh = HostReachabilityService.profilesNeedingRefresh(
            [neverChecked, expired, fresh, inFlight],
            lastChecked: [
                expired.id: now.addingTimeInterval(-30),
                fresh.id: now.addingTimeInterval(-29.9),
                inFlight.id: now.addingTimeInterval(-90)
            ],
            activeProbeIDs: [inFlight.id],
            now: now
        )

        XCTAssertEqual(needingRefresh.map(\.id), [neverChecked.id, expired.id])
    }

    @MainActor
    func testRecordStatusStampsLastCheckedTimestamp() {
        let service = HostReachabilityService()
        let profileID = UUID()
        let before = Date()

        service.recordStatus(.online, for: profileID)

        XCTAssertNotNil(service.lastCheckedAtByProfileID[profileID])
        let stamped = service.lastCheckedAtByProfileID[profileID] ?? .distantPast
        XCTAssertGreaterThanOrEqual(stamped, before)
        XCTAssertLessThanOrEqual(stamped, Date())
    }

    @MainActor
    func testRefreshStaleProbesOnlyExpiredStatuses() {
        let service = HostReachabilityService()
        let staleProfile = ConnectionProfile(host: "")
        let freshProfile = ConnectionProfile(host: "")
        service.recordStatus(.online, for: freshProfile.id)

        service.refreshStale(profiles: [staleProfile, freshProfile])

        XCTAssertEqual(service.status(for: staleProfile.id), .offline)
        XCTAssertEqual(service.status(for: freshProfile.id), .online)
    }

    @MainActor
    func testForegroundActivationSkipsFreshStatuses() {
        let service = HostReachabilityService()
        let profile = ConnectionProfile(host: "")
        service.recordStatus(.online, for: profile.id)
        let stamped = service.lastCheckedAtByProfileID[profile.id]
        service.refreshStale(profiles: [profile])

        service.setSceneActive(false)
        service.setSceneActive(true)

        XCTAssertEqual(service.status(for: profile.id), .online)
        XCTAssertEqual(service.lastCheckedAtByProfileID[profile.id], stamped)
    }

    @MainActor
    func testRefreshAllForcesProbeOfFreshStatus() {
        let service = HostReachabilityService()
        let profile = ConnectionProfile(host: "")
        service.recordStatus(.online, for: profile.id)

        service.refreshAll(profiles: [profile])

        XCTAssertEqual(service.status(for: profile.id), .offline)
    }

    @MainActor
    func testRefreshAllPrunesDeletedProfileStatusAndTimestamp() {
        let service = HostReachabilityService()
        let profileID = UUID()
        service.recordStatus(.online, for: profileID)

        service.refreshAll(profiles: [])

        XCTAssertEqual(service.status(for: profileID), .unknown)
        XCTAssertNil(service.lastCheckedAtByProfileID[profileID])
    }

    @MainActor
    func testSeededStatusesNeverProbe() {
        let service = HostReachabilityService()
        let profile = ConnectionProfile(host: "")
        service.seedSampleStatuses([profile.id: .online])

        service.startMonitoring(profiles: [profile])
        service.refreshAll(profiles: [profile])
        service.refreshStale(profiles: [profile])
        service.setSceneActive(true)

        XCTAssertEqual(service.status(for: profile.id), .online)
        XCTAssertNotNil(service.lastCheckedAtByProfileID[profile.id])
    }
}
