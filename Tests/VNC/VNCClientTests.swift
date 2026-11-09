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
    }
}
