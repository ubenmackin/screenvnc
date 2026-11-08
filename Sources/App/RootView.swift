// App — Main multi-mode root navigation adapting to iPhone, iPad, and iPhone Duo.
import os
import SwiftUI

extension [DiscoveredHost] {
    /// Hides already-saved hosts so discovery lists only unsaved Macs.
    func excludingSavedProfiles(_ profiles: [ConnectionProfile]) -> [DiscoveredHost] {
        filter { host in
            !profiles.contains { profile in
                profile.host.caseInsensitiveCompare(host.host) == .orderedSame ||
                    profile.name.caseInsensitiveCompare(host.name) == .orderedSame
            }
        }
    }
}

public struct RootView: View {
    private var profileStore = ProfileStore.shared
    private var discoveryService = BonjourDiscoveryService.shared
    private var settings = SettingsStore.shared
    @Bindable private var cloudSync = CloudSyncCoordinator.shared
    private let logger = Logger(subsystem: "com.volcrypt.ScreenVNC", category: "RootView")

    @State private var selectedProfile: ConnectionProfile?
    @State private var activeSessionProfile: ConnectionProfile?
    @State private var isPresentingNewProfile = false
    @State private var isPresentingSettings = false
    @State private var profileToEdit: ConnectionProfile?
    @State private var currentDeviceMode: DeviceMode = .mode1NormalPhone

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            let mode = DeviceModeDetector.detectMode(
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                screenSize: geometry.size
            )

            Group {
                switch mode {
                case .mode1NormalPhone, .mode3DuoOuterScreen:
                    mode1PhoneView
                case .mode2InnerDisplayOrPad:
                    mode2TabletView
                }
            }
            .onAppear {
                currentDeviceMode = mode
            }
            .onChange(of: geometry.size) { _, _ in
                currentDeviceMode = mode
            }
        }
        .fullScreenCover(item: $activeSessionProfile) { profile in
            InSessionView(profile: profile) {
                activeSessionProfile = nil
            }
        }
        .sheet(isPresented: $isPresentingNewProfile) {
            EditProfileView(deviceMode: currentDeviceMode) { profile, password in
                profileStore.save(profile)
                if let password {
                    do {
                        try KeychainManager.shared.savePassword(password, for: profile.id)
                    } catch {
                        logger.error("Failed to save credentials for profile \(profile.id): \(error.localizedDescription)")
                    }
                }
            }
        }
        .sheet(item: $profileToEdit) { profile in
            EditProfileView(profileToEdit: profile, deviceMode: currentDeviceMode) { updated, password in
                profileStore.save(updated)
                if let password {
                    do {
                        try KeychainManager.shared.savePassword(password, for: updated.id)
                    } catch {
                        logger.error("Failed to save credentials for updated profile \(updated.id): \(error.localizedDescription)")
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingSettings) {
            SettingsView(deviceMode: currentDeviceMode)
        }
        .sheet(item: $cloudSync.restoreOffer) { offer in
            RestoreCloudProfilesView(profiles: offer.profiles)
        }
        .task {
            await cloudSync.scanForExistingCloudProfilesOnLaunch()
        }
        .onAppear {
            if settings.autoDiscoverBonjour {
                discoveryService.startDiscovery()
            }
        }
        .onChange(of: settings.autoDiscoverBonjour) { _, isEnabled in
            if isEnabled {
                discoveryService.startDiscovery()
            } else {
                discoveryService.stopDiscovery()
            }
        }
    }

    /// Mode 1: Single-column standard phone navigation.
    private var mode1PhoneView: some View {
        NavigationStack {
            List {
                connectionListContent
            }
            .navigationTitle("ScreenVNC")
            .toolbar {
                connectionListToolbar
            }
        }
    }

    /// Mode 2: iPad and Duo Inner Display multi-column split view.
    private var mode2TabletView: some View {
        NavigationSplitView {
            List(selection: $selectedProfile) {
                connectionListContent
            }
            .navigationTitle("ScreenVNC")
            .toolbar {
                connectionListToolbar
            }
        } detail: {
            if let selected = selectedProfile {
                ProfileInspectorView(profile: selected) {
                    startConnection(selected)
                }
            } else {
                ContentUnavailableView(
                    "No Host Selected",
                    systemImage: "macbook.and.iphone",
                    description: Text("Choose a Mac from the sidebar or discover one on your local network.")
                )
            }
        }
    }

    /// Shared rows for phone and tablet lists so both stay in sync.
    @ViewBuilder
    private var connectionListContent: some View {
        discoveredMacsSection
        favoritesSection
        savedSessionsSection
    }

    /// Shared toolbar so phone and tablet expose the same actions.
    @ToolbarContentBuilder
    private var connectionListToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isPresentingSettings = true
            } label: {
                Image(systemName: "gear")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                isPresentingNewProfile = true
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    private var filteredDiscoveredHosts: [DiscoveredHost] {
        discoveryService.discoveredHosts.excludingSavedProfiles(profileStore.profiles)
    }

    private var nonFavoriteProfiles: [ConnectionProfile] {
        profileStore.profiles.filter { !$0.isFavorite }
    }

    @ViewBuilder
    private var discoveredMacsSection: some View {
        if !filteredDiscoveredHosts.isEmpty {
            Section("Discovered Macs (Local Network)") {
                ForEach(filteredDiscoveredHosts) { host in
                    Button {
                        connectDiscovered(host)
                    } label: {
                        HStack {
                            Image(systemName: "macmini.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading) {
                                Text(host.name)
                                    .font(.headline)
                                Text("\(host.host):\(String(host.port))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Connect")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        let favorites = profileStore.profiles.filter(\.isFavorite)
        if !favorites.isEmpty {
            Section("Favorites") {
                ForEach(favorites) { profile in
                    profileRow(profile)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        profileStore.remove(id: favorites[index].id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var savedSessionsSection: some View {
        if profileStore.profiles.isEmpty {
            Section("Saved Connections") {
                Text("No saved profiles. Tap + to add a Mac connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if !nonFavoriteProfiles.isEmpty {
            Section("Saved Connections") {
                ForEach(nonFavoriteProfiles) { profile in
                    profileRow(profile)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        profileStore.remove(id: nonFavoriteProfiles[index].id)
                    }
                }
            }
        }
    }

    private func profileRow(_ profile: ConnectionProfile) -> some View {
        ProfileRowView(
            profile: profile,
            onConnect: { startConnection(profile) },
            onEdit: { profileToEdit = profile },
            onToggleFavorite: { profileStore.toggleFavorite(for: profile.id) },
            onDelete: { profileStore.remove(id: profile.id) }
        )
    }

    private func startConnection(_ profile: ConnectionProfile) {
        if profile.requiresBiometrics || settings.requireBiometricsGlobally {
            Task {
                let success = await BiometricAuthManager.shared.authenticate(reason: "Unlock \(profile.name)")
                if success {
                    activeSessionProfile = profile
                }
            }
        } else {
            activeSessionProfile = profile
        }
    }

    private func connectDiscovered(_ host: DiscoveredHost) {
        let profile = ConnectionProfile(
            name: host.name,
            host: host.host,
            port: host.port,
            authMethod: .vncDES,
            displayPreference: settings.defaultDisplayPreference,
            qualityPreference: settings.defaultQualityPreference,
            pointerMode: settings.defaultPointerMode
        )
        profileToEdit = profile
    }
}
