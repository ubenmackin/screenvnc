// Connection — Form view for creating and modifying host connection profiles.
import SwiftUI

public struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    public var profileToEdit: ConnectionProfile?
    public var onSave: (ConnectionProfile, String?) -> Void

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var portString: String = "5900"
    @State private var authMethod: AuthMethod = .appleDH
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var displayPreference: DisplayPreference = .fit
    @State private var qualityPreference: QualityPreference = .adaptive
    @State private var isFavorite: Bool = false
    @State private var requiresBiometrics: Bool = false
    @State private var validationError: String?

    public init(profileToEdit: ConnectionProfile? = nil, onSave: @escaping (ConnectionProfile, String?) -> Void) {
        self.profileToEdit = profileToEdit
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Host Details") {
                    TextField("Name (e.g. Mac Studio)", text: $name)
                    TextField("Host or IP (e.g. macbook.local)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $portString)
                        .keyboardType(.numberPad)
                }

                Section("Authentication (macOS Screen Sharing)") {
                    Picker("Auth Method", selection: $authMethod) {
                        ForEach(AuthMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }

                    if authMethod == .appleDH {
                        TextField("macOS Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if authMethod != .none {
                        SecureField("Password", text: $password)
                    }
                }

                Section("Display & Performance") {
                    Picker("Display Mode", selection: $displayPreference) {
                        ForEach(DisplayPreference.allCases, id: \.self) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }

                    Picker("Quality / Compression", selection: $qualityPreference) {
                        ForEach(QualityPreference.allCases, id: \.self) { qual in
                            Text(qual.displayName).tag(qual)
                        }
                    }
                }

                Section("Preferences") {
                    Toggle("Add to Favorites", isOn: $isFavorite)
                    Toggle("Require Face ID to Connect", isOn: $requiresBiometrics)
                }
            }
            .navigationTitle(profileToEdit == nil ? "New Mac Connection" : "Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveProfile() }
                }
            }
            .alert("Validation Error", isPresented: Binding(
                get: { validationError != nil },
                set: {
                    if !$0 {
                        validationError = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationError ?? "")
            }
            .onAppear {
                loadInitialData()
            }
        }
    }

    private func loadInitialData() {
        if let existingProfile = profileToEdit {
            name = existingProfile.name
            host = existingProfile.host
            portString = String(existingProfile.port)
            authMethod = existingProfile.authMethod
            username = existingProfile.username
            displayPreference = existingProfile.displayPreference
            qualityPreference = existingProfile.qualityPreference
            isFavorite = existingProfile.isFavorite
            requiresBiometrics = existingProfile.requiresBiometrics
            password = KeychainManager.shared.getPassword(for: existingProfile.id) ?? ""
        }
    }

    private func saveProfile() {
        let port = Int(portString) ?? 5900
        let profile = ConnectionProfile(
            id: profileToEdit?.id ?? UUID(),
            name: name.isEmpty ? host : name,
            host: host,
            port: port,
            authMethod: authMethod,
            username: username,
            displayPreference: displayPreference,
            qualityPreference: qualityPreference,
            isFavorite: isFavorite,
            requiresBiometrics: requiresBiometrics
        )

        do {
            try profile.validate()
            onSave(profile, password.isEmpty ? nil : password)
            dismiss()
        } catch {
            validationError = error.localizedDescription
        }
    }
}
