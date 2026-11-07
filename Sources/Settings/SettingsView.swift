// Settings — Global configuration, display defaults, and sync status view.
import SwiftUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Viewer Defaults") {
                    Picker("Default Display Mode", selection: $settings.defaultDisplayPreference) {
                        ForEach(DisplayPreference.allCases, id: \.self) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }

                    Picker("Default Quality", selection: $settings.defaultQualityPreference) {
                        ForEach(QualityPreference.allCases, id: \.self) { qual in
                            Text(qual.displayName).tag(qual)
                        }
                    }
                }

                Section("Foldable & Tabletop (iPhone Duo)") {
                    Picker("Tabletop Console Mode", selection: $settings.tabletopConsoleMode) {
                        ForEach(TabletopConsoleMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Text(
                        "In 'Always Full Canvas', the remote Mac desktop occupies the entire folding " +
                            "display—ideal when using external Bluetooth keyboards and trackpads."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("Security & Network") {
                    Toggle("Require Face ID / Touch ID Globally", isOn: $settings.requireBiometricsGlobally)
                    Toggle("Auto-discover Local Macs (Bonjour)", isOn: $settings.autoDiscoverBonjour)
                    Toggle("View Only Mode (Disable Input)", isOn: $settings.viewOnly)
                }

                Section("iCloud Synchronization") {
                    HStack {
                        Image(systemName: "icloud.fill")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("iCloud Sync Active")
                                .font(.subheadline.bold())
                            Text("Connection profiles automatically sync across iPhone, iPad, and iPhone Duo.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
