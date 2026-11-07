// Settings — Global configuration, display defaults, and sync status view.
import SwiftUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = SettingsStore.shared
    public var deviceMode: DeviceMode

    @State private var isTabletopExpanded: Bool = true

    public init(deviceMode: DeviceMode = .mode1NormalPhone) {
        self.deviceMode = deviceMode
    }

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

                    Picker("Default Interaction Mode", selection: $settings.defaultPointerMode) {
                        ForEach(PointerMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                if deviceMode != .mode1NormalPhone {
                    Section("Foldable & Tabletop (iPhone Duo)") {
                        DisclosureGroup(isExpanded: $isTabletopExpanded) {
                            VStack(spacing: 8) {
                                tabletopOptionRow(
                                    mode: .auto,
                                    icon: "laptopcomputer",
                                    title: "Automatic (Tabletop Hinge)",
                                    description: "Dynamically switches between full canvas and split console based on the folding hinge posture angle."
                                )

                                tabletopOptionRow(
                                    mode: .alwaysFullCanvas,
                                    icon: "display",
                                    title: "Always Full Canvas (BT Keyboard)",
                                    description: "Remote Mac desktop occupies the entire folding display—ideal when using external Bluetooth keyboards and trackpads."
                                )

                                tabletopOptionRow(
                                    mode: .alwaysSplitConsole,
                                    icon: "rectangle.split.2x1",
                                    title: "Always Split Console",
                                    description: "Remote Mac desktop stays on the upper half, with a virtual trackpad and Mac shortcuts fixed on the lower half."
                                )
                            }
                            .padding(.vertical, 4)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Tabletop Console Mode")
                                    .font(.body.bold())
                                Text(settings.tabletopConsoleMode.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
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
                    if deviceMode == .mode3DuoOuterScreen {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.body.bold())
                                .foregroundStyle(.blue)
                        }
                    } else {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func tabletopOptionRow(
        mode: TabletopConsoleMode,
        icon: String,
        title: String,
        description: String
    ) -> some View {
        let isSelected = settings.tabletopConsoleMode == mode
        return Button {
            settings.tabletopConsoleMode = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.primary)
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
