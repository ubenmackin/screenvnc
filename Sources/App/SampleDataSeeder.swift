// App — Sample data seeding for UI tests and App Store screenshots.
import Foundation

@MainActor
public enum SampleDataSeeder {
    public static func seedIfRequested() {
        let args = CommandLine.arguments
        let isUITesting = args.contains("-uitesting") ||
            args.contains("-ScreenVNCScreenshots") ||
            args.contains("--create-sample-data")

        guard isUITesting else { return }

        if args.contains("--reset-sample-data") {
            ProfileStore.shared.overwriteCloud(with: [])
        }

        if ProfileStore.shared.profiles.isEmpty {
            let sampleProfiles: [ConnectionProfile] = [
                ConnectionProfile(
                    name: "Studio Mac Pro",
                    host: "192.168.1.10",
                    port: 5900,
                    authMethod: .appleDH,
                    username: "admin",
                    displayPreference: .fit,
                    qualityPreference: .high,
                    isFavorite: true,
                    lastConnectedDate: Date()
                ),
                ConnectionProfile(
                    name: "MacBook Pro 16\"",
                    host: "192.168.1.25",
                    port: 5900,
                    authMethod: .appleDH,
                    username: "ben",
                    displayPreference: .actualSize,
                    qualityPreference: .adaptive,
                    isFavorite: true,
                    lastConnectedDate: Date().addingTimeInterval(-7200)
                ),
                ConnectionProfile(
                    name: "Mac mini Server",
                    host: "192.168.1.50",
                    port: 5900,
                    authMethod: .vncDES,
                    displayPreference: .fit,
                    qualityPreference: .adaptive,
                    isFavorite: false,
                    lastConnectedDate: Date().addingTimeInterval(-86400)
                ),
                ConnectionProfile(
                    name: "Office iMac",
                    host: "10.0.0.12",
                    port: 5900,
                    authMethod: .appleDH,
                    username: "workstation",
                    displayPreference: .fit,
                    qualityPreference: .low,
                    isFavorite: false,
                    lastConnectedDate: Date().addingTimeInterval(-86400 * 4)
                ),
                ConnectionProfile(
                    name: "Media Center",
                    host: "192.168.1.99",
                    port: 5900,
                    authMethod: .vncDES,
                    displayPreference: .fill,
                    qualityPreference: .high,
                    isFavorite: false
                )
            ]

            for profile in sampleProfiles {
                ProfileStore.shared.save(profile)
            }
        }

        // Seed mock discovered Bonjour hosts
        let mockDiscovered: [DiscoveredHost] = [
            DiscoveredHost(name: "Living Room Mac mini", host: "living-room.local", port: 5900),
            DiscoveredHost(name: "Mac Studio M2 Ultra", host: "mac-studio.local", port: 5900)
        ]
        BonjourDiscoveryService.shared.seedSampleDiscoveredHosts(mockDiscovered)

        SettingsStore.shared.hasCompletedInitialSetup = true
    }
}
