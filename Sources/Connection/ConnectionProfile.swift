// Connection — ScreenVNC host connection profile definition and validation.
import Foundation

public enum AuthMethod: String, Codable, Sendable, CaseIterable {
    case appleDH
    case vncDES
    case none

    public var displayName: String {
        switch self {
        case .appleDH: "macOS User (Apple DH)"
        case .vncDES: "VNC Password"
        case .none: "None"
        }
    }
}

public enum DisplayPreference: String, Codable, Sendable, CaseIterable {
    case fit
    case actualSize
    case fill

    public var displayName: String {
        switch self {
        case .fit: "Fit Screen"
        case .actualSize: "1:1 Actual Size"
        case .fill: "Fill"
        }
    }
}

public enum QualityPreference: String, Codable, Sendable, CaseIterable {
    case adaptive
    case high
    case low

    public var displayName: String {
        switch self {
        case .adaptive: "Adaptive"
        case .high: "High Fidelity (ZRLE)"
        case .low: "Fast (Low Bandwidth)"
        }
    }
}

public enum ProfileValidationError: LocalizedError, Equatable {
    case emptyHost
    case invalidPort(Int)
    case missingUsername
    case noneAuthRequiresLoopback

    public var errorDescription: String? {
        switch self {
        case .emptyHost:
            "Host address must not be empty."
        case let .invalidPort(port):
            "Port \(port) is out of valid range (1–65535)."
        case .missingUsername:
            "macOS authentication requires a username."
        case .noneAuthRequiresLoopback:
            "Unauthenticated connections are only allowed for loopback hosts."
        }
    }
}

public struct ConnectionProfile: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var authMethod: AuthMethod
    public var username: String
    public var displayPreference: DisplayPreference
    public var qualityPreference: QualityPreference
    public var pointerMode: PointerMode?
    public var macAddress: String?
    public var isFavorite: Bool
    public var requiresBiometrics: Bool
    public var allowUnencryptedSession: Bool
    public var lastConnectedDate: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case authMethod
        case username
        case displayPreference
        case qualityPreference
        case pointerMode
        case macAddress
        case isFavorite
        case requiresBiometrics
        case allowUnencryptedSession
        case lastConnectedDate
    }

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String,
        port: Int = 5900,
        authMethod: AuthMethod = .vncDES,
        username: String = "",
        displayPreference: DisplayPreference = .fit,
        qualityPreference: QualityPreference = .adaptive,
        pointerMode: PointerMode? = nil,
        macAddress: String? = nil,
        isFavorite: Bool = false,
        requiresBiometrics: Bool = false,
        allowUnencryptedSession: Bool = false,
        lastConnectedDate: Date? = nil
    ) {
        self.id = id
        self.name = name.isEmpty ? host : name
        self.host = host
        self.port = port
        self.authMethod = authMethod
        self.username = username
        self.displayPreference = displayPreference
        self.qualityPreference = qualityPreference
        self.pointerMode = pointerMode
        self.macAddress = macAddress
        self.isFavorite = isFavorite
        self.requiresBiometrics = requiresBiometrics
        self.allowUnencryptedSession = allowUnencryptedSession
        self.lastConnectedDate = lastConnectedDate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        username = try container.decode(String.self, forKey: .username)
        displayPreference = try container.decode(DisplayPreference.self, forKey: .displayPreference)
        qualityPreference = try container.decode(QualityPreference.self, forKey: .qualityPreference)
        pointerMode = try container.decodeIfPresent(PointerMode.self, forKey: .pointerMode)
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        requiresBiometrics = try container.decode(Bool.self, forKey: .requiresBiometrics)
        allowUnencryptedSession = try container.decodeIfPresent(Bool.self, forKey: .allowUnencryptedSession) ?? false
        lastConnectedDate = try container.decodeIfPresent(Date.self, forKey: .lastConnectedDate)
    }

    /// Profiles enforce minimum network viability before dialing remote hosts.
    public func validate() throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.isEmpty {
            throw ProfileValidationError.emptyHost
        }
        guard (1 ... 65535).contains(port) else {
            throw ProfileValidationError.invalidPort(port)
        }
        if authMethod == .appleDH, username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProfileValidationError.missingUsername
        }
        // Unauthenticated RFB is loopback-only; remote None invites MITM downgrade.
        if authMethod == .none, !Self.isLoopbackHost(trimmedHost) {
            throw ProfileValidationError.noneAuthRequiresLoopback
        }
    }

    /// Canonical loopback check; VNC dial guard delegates here.
    public static func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "localhost." {
            return true
        }
        let bare = lower.hasPrefix("[") && lower.hasSuffix("]") ? String(lower.dropFirst().dropLast()) : lower
        if bare == "::1" || bare == "0:0:0:0:0:0:0:1" {
            return true
        }
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let firstOctet = parts.first, firstOctet == "127" else { return false }
        return parts.dropFirst().allSatisfy { UInt8($0) != nil }
    }

    /// Non-loopback VNC-DES exposes a crackable challenge response on the wire;
    /// such sessions require explicit consent before dialing unless the user opted to always allow.
    public var requiresPlaintextConsent: Bool {
        guard authMethod == .vncDES, !allowUnencryptedSession else { return false }
        return !Self.isLoopbackHost(host.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
