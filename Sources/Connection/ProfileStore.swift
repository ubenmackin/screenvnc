// Connection — Persistence and iCloud synchronization for connection profiles.
import Foundation
import Observation
import os

@Observable
@MainActor
public final class ProfileStore {
    public static let shared = ProfileStore()

    public private(set) var profiles: [ConnectionProfile] = []

    private let fileURL: URL
    private let kvsKey = "com.volcrypt.ScreenVNC.profiles"
    private let logger = Logger(subsystem: "com.volcrypt.ScreenVNC", category: "ProfileStore")
    private var syncTask: Task<Void, Never>?

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = appSupport.appendingPathComponent("ScreenVNC", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create profile directory: \(error.localizedDescription, privacy: .private)")
        }
        fileURL = folder.appendingPathComponent("profiles.json")

        load()
        setupCloudSync()
    }

    /// Isolated deinit runs on MainActor so the MainActor-isolated sync task is safe to cancel.
    isolated deinit {
        syncTask?.cancel()
    }

    public func save(_ profile: ConnectionProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    public func remove(id: UUID) {
        profiles.removeAll { $0.id == id }
        KeychainManager.shared.deletePassword(for: id)
        persist()
    }

    public func toggleFavorite(for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isFavorite.toggle()
        persist()
    }

    public func updateLastConnected(for id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lastConnectedDate = Date()
        persist()
    }

    /// Inspects the current iCloud KVS payload without modifying local profiles.
    public func fetchCloudProfiles() -> [ConnectionProfile]? {
        guard let cloudData = NSUbiquitousKeyValueStore.default.data(forKey: kvsKey) else { return nil }
        do {
            let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: cloudData)
            let valid = validated(decoded)
            return valid.isEmpty ? nil : valid
        } catch {
            logger.warning("Failed to decode iCloud KVS profiles payload: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Restores consent-confirmed cloud profiles; Keychain entries for restored IDs
    /// are dropped so a restored host can never inherit a locally stored password.
    public func restoreFromCloud(_ cloudProfiles: [ConnectionProfile]) {
        let valid = validated(cloudProfiles)
        for profile in valid where KeychainManager.shared.hasPassword(for: profile.id) {
            KeychainManager.shared.deletePassword(for: profile.id)
        }
        profiles = valid
        persist()
    }

    /// Overwrites the iCloud KVS backup with the provided profiles.
    public func overwriteCloud(with cleanProfiles: [ConnectionProfile] = []) {
        profiles = cleanProfiles
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: fileURL, options: .atomic)
            // Synchronize with iCloud Key-Value Store for cross-device persistence.
            NSUbiquitousKeyValueStore.default.set(data, forKey: kvsKey)
            NSUbiquitousKeyValueStore.default.synchronize()
            CloudSyncCoordinator.shared.recordSuccessfulSync()
        } catch {
            logger.error("Failed to persist profiles: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func load() {
        // Prefer local copy.
        do {
            let localData = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: localData)
            let valid = validated(decoded)
            profiles = valid
            if valid.count != decoded.count {
                // Heal poisoned file back to valid-only subset.
                persist()
            }
            return
        } catch {
            logger.debug("Local profiles unreadable or not present: \(error.localizedDescription, privacy: .private)")
        }

        // Fresh installs do not silently adopt cloud profiles.
        // CloudSyncCoordinator will inspect KVS and prompt the user if prior profiles exist.
        profiles = []
    }

    private func setupCloudSync() {
        syncTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSUbiquitousKeyValueStore.didChangeExternallyNotification) {
                guard let self else { break }
                self.handleCloudUpdate()
            }
        }
    }

    private func handleCloudUpdate() {
        guard SettingsStore.shared.hasCompletedInitialSetup else {
            logger.debug("Ignoring external iCloud update before initial setup completion")
            return
        }
        guard let cloudData = NSUbiquitousKeyValueStore.default.data(forKey: kvsKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: cloudData)
            let valid = validated(decoded)
            // External changes never replace local profiles unattended; divergence requires user consent.
            if valid == profiles {
                // Disk already mirrors in-memory profiles; confirming sync health is sufficient.
                CloudSyncCoordinator.shared.recordSuccessfulSync()
            } else if CloudSyncCoordinator.shared.restoreOffer == nil {
                logger.info("External iCloud profiles differ from local state; requesting user confirmation.")
                CloudSyncCoordinator.shared.presentRestoreSheetManually()
            }
        } catch {
            // Error bodies can echo wire payload fragments; keep them private.
            logger.warning("Failed to decode external iCloud profiles update: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Single-validator recheck drops poisoned entries before they enter memory.
    private func validated(_ decoded: [ConnectionProfile]) -> [ConnectionProfile] {
        decoded.filter {
            do {
                try $0.validate()
                return true
            } catch {
                return false
            }
        }
    }
}
