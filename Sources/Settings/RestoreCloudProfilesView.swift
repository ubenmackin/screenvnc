// Settings — First-launch discovery sheet allowing users to restore or discard iCloud profiles.
import SwiftUI

public struct RestoreCloudProfilesView: View {
    let profiles: [ConnectionProfile]

    private var coordinator = CloudSyncCoordinator.shared

    @State private var showCleanConfirmAlert = false

    public init(profiles: [ConnectionProfile]) {
        self.profiles = profiles
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                headerSection

                profileListSection

                securityFootnote

                Spacer()

                actionButtons
            }
            .padding(24)
            .navigationTitle("Restore Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        coordinator.isRestorePromptPresented = false
                    }
                }
            }
            .alert("Start Clean Setup?", isPresented: $showCleanConfirmAlert) {
                Button("Keep iCloud Backup & Start Clean") {
                    coordinator.startFresh(wipeCloudData: false)
                }
                Button("Wipe iCloud Backup & Start Clean", role: .destructive) {
                    coordinator.startFresh(wipeCloudData: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can keep your existing iCloud profiles safe to restore later, or start fresh and replace the cloud backup.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("iCloud Profiles Discovered")
                .font(.title2.bold())

            Text("We found \(profiles.count) connection profile\(profiles.count == 1 ? "" : "s") saved to your Apple Account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var profileListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discovered Hosts")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(profiles) { profile in
                        HStack(spacing: 12) {
                            Image(systemName: "macbook.and.iphone")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .font(.body.weight(.medium))
                                Text("\(profile.host):\(profile.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(profile.authMethod.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private var securityFootnote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.blue)
                .font(.subheadline)
            Text("Connection passwords stay device-only in your Keychain for security. Restored hosts will ask for credentials on first connect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                coordinator.restoreDiscoveredProfiles()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Restore Profiles (\(profiles.count))")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button {
                showCleanConfirmAlert = true
            } label: {
                Text("Start Fresh (Clean Install)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
