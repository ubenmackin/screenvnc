// App — Detailed inspector and row presentation for connection profiles.
import SwiftUI

public struct ProfileRowView: View {
    public let profile: ConnectionProfile
    public var onConnect: @MainActor () -> Void
    public var onEdit: @MainActor () -> Void
    public var onToggleFavorite: @MainActor () -> Void
    public var onDelete: @MainActor () -> Void

    public init(
        profile: ConnectionProfile,
        onConnect: @escaping @MainActor () -> Void,
        onEdit: @escaping @MainActor () -> Void,
        onToggleFavorite: @escaping @MainActor () -> Void,
        onDelete: @escaping @MainActor () -> Void
    ) {
        self.profile = profile
        self.onConnect = onConnect
        self.onEdit = onEdit
        self.onToggleFavorite = onToggleFavorite
        self.onDelete = onDelete
    }

    public var body: some View {
        Button {
            onConnect()
        } label: {
            HStack {
                Image(systemName: "display")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    Text("\(profile.host):\(String(profile.port)) • \(profile.authMethod.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { onEdit() }
            Button(profile.isFavorite ? "Unfavorite" : "Favorite") { onToggleFavorite() }
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

public struct ProfileInspectorView: View {
    public let profile: ConnectionProfile
    public var onConnect: @MainActor () -> Void

    public init(profile: ConnectionProfile, onConnect: @escaping @MainActor () -> Void) {
        self.profile = profile
        self.onConnect = onConnect
    }

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text(profile.name)
                .font(.title.bold())

            VStack(alignment: .leading, spacing: 8) {
                detailRow("Host Address", value: "\(profile.host):\(String(profile.port))")
                detailRow("Authentication", value: profile.authMethod.displayName)
                if !profile.username.isEmpty {
                    detailRow("Username", value: profile.username)
                }
                detailRow("Display Mode", value: profile.displayPreference.displayName)
                detailRow("Compression", value: profile.qualityPreference.displayName)
                if let pointerMode = profile.pointerMode {
                    detailRow("Pointer Mode", value: pointerMode.displayName)
                }
                if let mac = profile.macAddress, !mac.isEmpty {
                    detailRow("MAC Address", value: mac)
                }
                if let lastConnected = profile.lastConnectedDate {
                    detailRow("Last Connected", value: lastConnected.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .padding()
            .frame(maxWidth: 400)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                onConnect()
            } label: {
                Label("Start VNC Session", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: 300, minHeight: 48)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Spacer()
        }
        .padding(.top, 40)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.bold())
        }
    }
}
