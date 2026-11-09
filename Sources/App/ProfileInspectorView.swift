// App — Detailed inspector and row presentation for connection profiles.
import SwiftUI

extension HostReachabilityStatus {
    var dotColor: Color {
        switch self {
        case .online: .green
        case .offline: .secondary
        case .checking: .orange
        case .unknown: .clear
        }
    }
}

public struct ReachabilityStatusBadge: View {
    public let status: HostReachabilityStatus

    public init(status: HostReachabilityStatus) {
        self.status = status
    }

    public var body: some View {
        if status != .unknown {
            HStack(spacing: 5) {
                Circle()
                    .fill(status.dotColor)
                    .frame(width: 7, height: 7)
                Text(status.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.dotColor.opacity(0.14))
            .clipShape(Capsule())
        }
    }

    private var textColor: Color {
        switch status {
        case .online: .green
        case .offline: .secondary
        case .checking: .orange
        case .unknown: .secondary
        }
    }
}

public struct ProfileRowView: View {
    public let profile: ConnectionProfile
    public var reachabilityStatus: HostReachabilityStatus
    public var onConnect: @MainActor () -> Void
    public var onEdit: @MainActor () -> Void
    public var onToggleFavorite: @MainActor () -> Void
    public var onDelete: @MainActor () -> Void

    public init(
        profile: ConnectionProfile,
        reachabilityStatus: HostReachabilityStatus = .unknown,
        onConnect: @escaping @MainActor () -> Void,
        onEdit: @escaping @MainActor () -> Void,
        onToggleFavorite: @escaping @MainActor () -> Void,
        onDelete: @escaping @MainActor () -> Void
    ) {
        self.profile = profile
        self.reachabilityStatus = reachabilityStatus
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
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "display")
                        .font(.title3)
                        .foregroundStyle(reachabilityStatus == .offline ? Color.secondary : Color.accentColor)
                        .frame(width: 32, height: 28)

                    if reachabilityStatus != .unknown {
                        Circle()
                            .fill(reachabilityStatus.dotColor)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        ReachabilityStatusBadge(status: reachabilityStatus)
                    }
                    Text("\(profile.host):\(String(profile.port)) • \(profile.authMethod.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(reachabilityStatus == .offline ? Color.secondary.opacity(0.6) : Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("ProfileRow_\(profile.name)")
        .accessibilityLabel(profile.name)
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
    public var reachabilityStatus: HostReachabilityStatus
    public var onConnect: @MainActor () -> Void

    public init(
        profile: ConnectionProfile,
        reachabilityStatus: HostReachabilityStatus = .unknown,
        onConnect: @escaping @MainActor () -> Void
    ) {
        self.profile = profile
        self.reachabilityStatus = reachabilityStatus
        self.onConnect = onConnect
    }

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 64))
                .foregroundStyle(reachabilityStatus == .offline ? Color.secondary : Color.accentColor)

            VStack(spacing: 6) {
                Text(profile.name)
                    .font(.title.bold())
                ReachabilityStatusBadge(status: reachabilityStatus)
            }

            VStack(alignment: .leading, spacing: 8) {
                if reachabilityStatus != .unknown {
                    detailRow("Status", value: reachabilityStatus.label)
                }
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
