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
            logger.error("Failed to create profile directory: \(error.localizedDescription)")
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

    private func persist() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: fileURL, options: .atomic)
            // Synchronize with iCloud Key-Value Store for cross-device persistence.
            NSUbiquitousKeyValueStore.default.set(data, forKey: kvsKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        } catch {
            logger.error("Failed to persist profiles: \(error.localizedDescription)")
        }
    }

    private func load() {
        // Prefer local copy; fallback to iCloud KVS payload on fresh installs.
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
            logger.debug("Local profiles unreadable or not present, checking cloud: \(error.localizedDescription)")
        }

        if let cloudData = NSUbiquitousKeyValueStore.default.data(forKey: kvsKey) {
            do {
                let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: cloudData)
                let valid = validated(decoded)
                profiles = valid
                if valid.count == decoded.count {
                    try cloudData.write(to: fileURL, options: .atomic)
                } else {
                    // Cache clean subset only; poisoned bytes never reach disk.
                    let clean = try JSONEncoder().encode(valid)
                    try clean.write(to: fileURL, options: .atomic)
                }
            } catch {
                logger.warning("Failed to decode iCloud KVS profiles payload: \(error.localizedDescription)")
            }
        }
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
        guard let cloudData = NSUbiquitousKeyValueStore.default.data(forKey: kvsKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: cloudData)
            let valid = validated(decoded)
            profiles = valid
            if valid.count == decoded.count {
                try cloudData.write(to: fileURL, options: .atomic)
            } else {
                // Persist clean subset only; poisoned bytes never reach disk.
                let clean = try JSONEncoder().encode(valid)
                try clean.write(to: fileURL, options: .atomic)
            }
        } catch {
            logger.warning("Failed to decode external iCloud profiles update: \(error.localizedDescription)")
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
