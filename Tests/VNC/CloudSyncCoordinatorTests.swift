// Tests — iCloud sync coordinator, account status resolution, and clean install restore flows.
import CloudKit
@testable import ScreenVNC
import XCTest

@MainActor
final class CloudSyncCoordinatorTests: XCTestCase {
    private var coordinator: CloudSyncCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        coordinator = CloudSyncCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        try await super.tearDown()
    }

    func testCloudAccountStatusDisplayNames() {
        XCTAssertEqual(CloudAccountStatus.available.displayName, "Available")
        XCTAssertEqual(CloudAccountStatus.noAccount.displayName, "Not Signed In")
        XCTAssertEqual(CloudAccountStatus.restricted.displayName, "Restricted")
        XCTAssertEqual(CloudAccountStatus.temporarilyUnavailable.displayName, "Temporarily Unavailable")
        XCTAssertEqual(CloudAccountStatus.couldNotDetermine.displayName, "Unknown")
        XCTAssertEqual(CloudAccountStatus.checking.displayName, "Checking Status…")
    }

    func testSyncHealthStateDisplayText() {
        XCTAssertEqual(SyncHealthState.synced.displayText, "iCloud Sync Active")
        XCTAssertEqual(SyncHealthState.syncing.displayText, "Syncing with iCloud…")
        XCTAssertEqual(SyncHealthState.pending.displayText, "Sync Pending")
        XCTAssertEqual(SyncHealthState.accountUnavailable.displayText, "iCloud Unavailable")
        XCTAssertEqual(SyncHealthState.failed("Network timeout").displayText, "Sync Failed: Network timeout")
    }

    func testCheckAccountStatusAvailable() async {
        coordinator.accountStatusProvider = { .available }
        await coordinator.checkAccountStatus()

        XCTAssertEqual(coordinator.accountStatus, .available)
        XCTAssertEqual(coordinator.syncHealth, .synced)
        XCTAssertEqual(coordinator.statusColor, .green)
    }

    func testCheckAccountStatusNoAccount() async {
        coordinator.accountStatusProvider = { .noAccount }
        await coordinator.checkAccountStatus()

        XCTAssertEqual(coordinator.accountStatus, .noAccount)
        XCTAssertEqual(coordinator.syncHealth, .accountUnavailable)
        XCTAssertEqual(coordinator.statusColor, .orange)
    }

    func testCheckAccountStatusRestricted() async {
        coordinator.accountStatusProvider = { .restricted }
        await coordinator.checkAccountStatus()

        XCTAssertEqual(coordinator.accountStatus, .restricted)
        XCTAssertEqual(coordinator.syncHealth, .accountUnavailable)
    }

    func testCheckAccountStatusTemporarilyUnavailable() async {
        coordinator.accountStatusProvider = { .temporarilyUnavailable }
        await coordinator.checkAccountStatus()

        XCTAssertEqual(coordinator.accountStatus, .temporarilyUnavailable)
        XCTAssertEqual(coordinator.syncHealth, .pending)
    }

    func testRestoreDiscoveredProfilesUpdatesState() throws {
        let sampleProfile = ConnectionProfile(
            name: "Cloud Mac",
            host: "10.0.0.5",
            port: 5900,
            authMethod: .appleDH,
            username: "clouduser"
        )
        let cloudProfiles = [sampleProfile]

        // Locally constructed stores keep ProfileStore.shared and SettingsStore.shared untouched across randomized ordering.
        let profileStore = ProfileStore()
        let settingsStore = SettingsStore()
        settingsStore.hasCompletedInitialSetup = false
        coordinator = CloudSyncCoordinator(profileStore: profileStore, settingsStore: settingsStore)
        coordinator.cloudProfilesProvider = { cloudProfiles }

        coordinator.presentRestoreSheetManually()

        let offer = try XCTUnwrap(coordinator.restoreOffer)
        XCTAssertEqual(offer.profiles, cloudProfiles)
        XCTAssertTrue(coordinator.isRestorePromptPresented)
        let snapshot = try XCTUnwrap(coordinator.cloudProfilesSnapshot)
        XCTAssertEqual(snapshot, cloudProfiles)

        coordinator.restoreDiscoveredProfiles()

        XCTAssertEqual(profileStore.profiles, cloudProfiles)
        XCTAssertNil(coordinator.restoreOffer)
        XCTAssertFalse(coordinator.isRestorePromptPresented)
        XCTAssertTrue(settingsStore.hasCompletedInitialSetup)
    }

    func testStartFreshMarksSetupCompleted() {
        let settingsStore = SettingsStore()
        settingsStore.hasCompletedInitialSetup = false
        coordinator = CloudSyncCoordinator(settingsStore: settingsStore)

        coordinator.startFresh(wipeCloudData: false)

        XCTAssertTrue(settingsStore.hasCompletedInitialSetup)
        XCTAssertFalse(coordinator.isRestorePromptPresented)
    }

    func testRecordSuccessfulSyncUpdatesTimestamp() throws {
        let before = Date().addingTimeInterval(-1)
        coordinator.recordSuccessfulSync()
        XCTAssertNotNil(coordinator.lastSyncedAt)
        XCTAssertGreaterThan(try XCTUnwrap(coordinator.lastSyncedAt), before)
    }
}
