// Connection — Secure credential storage using iOS Keychain services.
import Foundation
import Security

public final class KeychainManager: Sendable {
    public static let shared = KeychainManager()
    private let service = "com.volcrypt.ScreenVNC.credentials"

    public init() {}

    /// Device-only credentials stay off iCloud; sync needs explicit opt-in consent.
    public func savePassword(_ password: String, for profileId: UUID) throws {
        guard let data = password.data(using: .utf8) else { return }
        let account = profileId.uuidString

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    public func getPassword(for profileId: UUID) -> String? {
        let account = profileId.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let pass = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pass
    }

    public func deletePassword(for profileId: UUID) {
        let account = profileId.uuidString
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }
}

public enum KeychainError: LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .status(code):
            "Keychain operation failed with OSStatus \(code)."
        }
    }
}
