// Connection — Persistence and iCloud synchronization for connection profiles.
import Combine
import Foundation

@MainActor
public final class ProfileStore: ObservableObject {
    public static let shared = ProfileStore()

    @Published public private(set) var profiles: [ConnectionProfile] = []

    private let fileURL: URL
    private let kvsKey = "com.volcrypt.ScreenVNC.profiles"
    private var cancellables = Set<AnyCancellable>()

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = appSupport.appendingPathComponent("ScreenVNC", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            // Non-fatal fallback for directory creation
        }
        fileURL = folder.appendingPathComponent("profiles.json")

        load()
        setupCloudSync()
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
            // Non-fatal persistence error.
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
            // Local file not present or unreadable; check cloud
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
                // Corrupt payload keeps last-good list.
            }
        }
    }

    private func setupCloudSync() {
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let cloudData = NSUbiquitousKeyValueStore.default.data(forKey: self.kvsKey) else { return }
                    do {
                        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: cloudData)
                        let valid = self.validated(decoded)
                        self.profiles = valid
                        if valid.count == decoded.count {
                            try cloudData.write(to: self.fileURL, options: .atomic)
                        } else {
                            // Persist clean subset only; poisoned bytes never reach disk.
                            let clean = try JSONEncoder().encode(valid)
                            try clean.write(to: self.fileURL, options: .atomic)
                        }
                    } catch {
                        // Corrupt payload keeps last-good list.
                    }
                }
            }
            .store(in: &cancellables)
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
