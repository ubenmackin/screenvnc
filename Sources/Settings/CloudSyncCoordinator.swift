// Settings — iCloud account detection, synchronization health, and clean-install restore coordination.
import CloudKit
import Foundation
import Observation
import os
import SwiftUI

public enum CloudAccountStatus: String, Sendable, CaseIterable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
    case checking

    public var displayName: String {
        switch self {
        case .available: "Available"
        case .noAccount: "Not Signed In"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily Unavailable"
        case .couldNotDetermine: "Unknown"
        case .checking: "Checking Status…"
        }
    }
}

public enum SyncHealthState: Equatable, Sendable {
    case synced
    case syncing
    case pending
    case accountUnavailable
    case failed(String)

    public var displayText: String {
        switch self {
        case .synced: "iCloud Sync Active"
        case .syncing: "Syncing with iCloud…"
        case .pending: "Sync Pending"
        case .accountUnavailable: "iCloud Unavailable"
        case let .failed(reason): "Sync Failed: \(reason)"
        }
    }
}

/// Identifiable payload for item-based restore presentation so the sheet can never show without profile content.
public struct CloudRestoreOffer: Identifiable {
    public let id = UUID()
    public let profiles: [ConnectionProfile]

    public init(profiles: [ConnectionProfile]) {
        self.profiles = profiles
    }
}

@Observable
@MainActor
public final class CloudSyncCoordinator {
    public static let shared = CloudSyncCoordinator()

    public private(set) var accountStatus: CloudAccountStatus = .checking
    public private(set) var syncHealth: SyncHealthState = .pending
    public private(set) var lastSyncedAt: Date?
    public private(set) var isSyncing: Bool = false
    public private(set) var cloudProfilesSnapshot: [ConnectionProfile]?
    public var restoreOffer: CloudRestoreOffer?

    /// Sheet presentation state is the restore offer itself; clearing the flag dismisses the item sheet.
    public var isRestorePromptPresented: Bool {
        get { restoreOffer != nil }
        set {
            if !newValue {
                restoreOffer = nil
            }
        }
    }

    public var statusColor: Color {
        switch accountStatus {
        case .available:
            switch syncHealth {
            case .synced:
                .green
            case .syncing:
                .blue
            case .pending:
                .orange
            case .accountUnavailable, .failed:
                .red
            }
        case .noAccount:
            .orange
        case .restricted, .couldNotDetermine:
            .secondary
        case .temporarilyUnavailable, .checking:
            .yellow
        }
    }

    private let logger = Logger(subsystem: "com.volcrypt.ScreenVNC", category: "CloudSyncCoordinator")
    private let lastSyncedKey = "com.volcrypt.ScreenVNC.lastSyncedAt"
    private var notificationTasks: [Task<Void, Never>] = []
    private let profileStore: ProfileStore
    private let settingsStore: SettingsStore

    /// Injectable provider for CKAccountStatus to allow deterministic unit testing without live network.
    public var accountStatusProvider: @Sendable () async throws -> CKAccountStatus = {
        try await CKContainer.default().accountStatus()
    }

    /// Injectable provider for iCloud KVS profile discovery to allow deterministic unit testing without live iCloud access.
    public var cloudProfilesProvider: (@Sendable () -> [ConnectionProfile]?)?

    public init(profileStore: ProfileStore = .shared, settingsStore: SettingsStore = .shared) {
        self.profileStore = profileStore
        self.settingsStore = settingsStore
        if let storedTime = UserDefaults.standard.object(forKey: lastSyncedKey) as? Date {
            lastSyncedAt = storedTime
        }
        setupNotificationObservers()
    }

    isolated deinit {
        notificationTasks.forEach { $0.cancel() }
    }

    private func setupNotificationObservers() {
        let accountChangedTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard let self else { break }
                self.logger.info("iCloud account changed notification received")
                await self.checkAccountStatus()
            }
        }
        notificationTasks.append(accountChangedTask)

        let ubiquityChangedTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSNotification.Name.NSUbiquityIdentityDidChange) {
                guard let self else { break }
                self.logger.info("NSUbiquityIdentityDidChange notification received")
                await self.checkAccountStatus()
            }
        }
        notificationTasks.append(ubiquityChangedTask)
    }

    /// Verifies live iCloud account authentication state via CloudKit container with ubiquity fallback.
    public func checkAccountStatus() async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let status = try await accountStatusProvider()
            switch status {
            case .available:
                accountStatus = .available
                syncHealth = .synced
            case .noAccount:
                accountStatus = .noAccount
                syncHealth = .accountUnavailable
            case .restricted:
                accountStatus = .restricted
                syncHealth = .accountUnavailable
            case .temporarilyUnavailable:
                accountStatus = .temporarilyUnavailable
                syncHealth = .pending
            case .couldNotDetermine:
                accountStatus = .couldNotDetermine
                syncHealth = .pending
            @unknown default:
                accountStatus = .couldNotDetermine
                syncHealth = .pending
            }
            logger.info("iCloud account status resolved: \(self.accountStatus.rawValue)")
        } catch {
            logger.warning("CloudKit accountStatus check failed: \(error.localizedDescription) — inspecting ubiquity token")
            if FileManager.default.ubiquityIdentityToken != nil {
                accountStatus = .available
                syncHealth = .synced
            } else {
                accountStatus = .couldNotDetermine
                syncHealth = .failed(error.localizedDescription)
            }
        }
    }

    /// Inspects the iCloud Key-Value Store and publishes the result as observed snapshot state for views.
    public func checkForCloudProfiles() -> [ConnectionProfile]? {
        let profiles = cloudProfilesProvider?() ?? profileStore.fetchCloudProfiles()
        cloudProfilesSnapshot = profiles
        return profiles
    }

    /// Scans iCloud on fresh install and presents restore prompt if prior data is detected.
    public func scanForExistingCloudProfilesOnLaunch() async {
        await checkAccountStatus()

        guard !settingsStore.hasCompletedInitialSetup else {
            // Already initialized; normal launch path.
            return
        }

        if let cloudProfiles = checkForCloudProfiles(), !cloudProfiles.isEmpty {
            logger.info("Clean install detected \(cloudProfiles.count) profiles in iCloud. Prompting user.")
            restoreOffer = CloudRestoreOffer(profiles: cloudProfiles)
        } else {
            logger.info("Clean install detected no existing iCloud profiles. Completing initial setup.")
            settingsStore.hasCompletedInitialSetup = true
        }
    }

    /// Manually surfaces the restore sheet (e.g. from Settings).
    public func presentRestoreSheetManually() {
        if let profiles = checkForCloudProfiles(), !profiles.isEmpty {
            restoreOffer = CloudRestoreOffer(profiles: profiles)
        }
    }

    /// Restores the discovered profiles into local storage and synchronizes.
    public func restoreDiscoveredProfiles() {
        guard let profiles = restoreOffer?.profiles, !profiles.isEmpty else {
            isRestorePromptPresented = false
            return
        }
        logger.info("Restoring \(profiles.count) profiles from iCloud")
        profileStore.restoreFromCloud(profiles)
        recordSuccessfulSync()
        settingsStore.hasCompletedInitialSetup = true
        restoreOffer = nil
    }

    /// Skips restore and initializes a clean slate.
    public func startFresh(wipeCloudData: Bool) {
        logger.info("User selected clean install (wipeCloudData: \(wipeCloudData))")
        if wipeCloudData {
            profileStore.overwriteCloud(with: [])
        }
        settingsStore.hasCompletedInitialSetup = true
        restoreOffer = nil
    }

    /// Forces immediate KVS synchronization and updates timestamp.
    public func triggerManualSync() async {
        isSyncing = true
        await checkAccountStatus()
        let didSync = NSUbiquitousKeyValueStore.default.synchronize()
        if didSync {
            recordSuccessfulSync()
        }
        isSyncing = false
    }

    public func recordSuccessfulSync() {
        let now = Date()
        lastSyncedAt = now
        UserDefaults.standard.set(now, forKey: lastSyncedKey)
        if accountStatus == .available {
            syncHealth = .synced
        }
    }
}
