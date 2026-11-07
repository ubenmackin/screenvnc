// App — High-density quick launcher for Duo outer cover display.
import SwiftUI

public struct CoverScreenView: View {
    @ObservedObject private var profileStore = ProfileStore.shared
    @ObservedObject private var discoveryService = BonjourDiscoveryService.shared

    public var onPresentSettings: () -> Void
    public var onPresentNewProfile: () -> Void
    public var onStartConnection: (ConnectionProfile) -> Void
    public var onConnectDiscovered: (DiscoveredHost) -> Void

    public init(
        onPresentSettings: @escaping () -> Void,
        onPresentNewProfile: @escaping () -> Void,
        onStartConnection: @escaping (ConnectionProfile) -> Void,
        onConnectDiscovered: @escaping (DiscoveredHost) -> Void
    ) {
        self.onPresentSettings = onPresentSettings
        self.onPresentNewProfile = onPresentNewProfile
        self.onStartConnection = onStartConnection
        self.onConnectDiscovered = onConnectDiscovered
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerView
                    quickConnectGrid
                    discoveredMacsView
                }
                .padding(.bottom, 20)
            }
        }
    }

    private var headerView: some View {
        HStack {
            Text("ScreenVNC")
                .font(.title2.bold())
            Spacer()
            Button {
                onPresentSettings()
            } label: {
                Image(systemName: "gear")
                    .font(.body)
            }
            Button {
                onPresentNewProfile()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var quickConnectGrid: some View {
        if !profileStore.profiles.isEmpty {
            Text("Quick Connect")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(profileStore.profiles) { profile in
                    Button {
                        onStartConnection(profile)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "display")
                                    .font(.headline)
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                                if profile.isFavorite {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                }
                            }
                            Text(profile.name)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Text(profile.host)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var discoveredMacsView: some View {
        if !discoveryService.discoveredHosts.isEmpty {
            Text("Discovered Macs")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 8) {
                ForEach(discoveryService.discoveredHosts) { host in
                    Button {
                        onConnectDiscovered(host)
                    } label: {
                        HStack {
                            Image(systemName: "network")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading) {
                                Text(host.name)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                Text(host.host)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}
