// VNC — Protocol version, security negotiation, and initialization handshakes.
import Foundation
import Network

extension VNCClient {
    /// Handshakes version, negotiates security, and exchanges client/server initialization.
    func executeHandshake(profile: ConnectionProfile, password: String?) async throws {
        try await performVersionHandshake()
        let selectedType = try await performSecurityNegotiation(preferred: profile.authMethod, host: profile.host)
        try await authenticate(securityType: selectedType, profile: profile, password: password, host: profile.host)
        try await performServerInit()
        try await sendPixelFormat()
        try await sendSupportedEncodings()
    }

    private func performVersionHandshake() async throws {
        let serverData = try await readExact(12)
        // Negotiate highest mutual version; fail closed on garbage or mismatch.
        guard let serverVersion = String(data: serverData, encoding: .utf8) else {
            throw VNCAuthError.authenticationRejected("Unsupported RFB version.")
        }
        let negotiated = try negotiatedVersion(for: serverVersion)
        // Fail closed if version string cannot encode; never send partial handshake.
        guard let clientVersion = negotiated.data(using: .utf8) else {
            throw VNCAuthError.authenticationRejected("Unable to encode client version.")
        }
        try await sendExact(clientVersion)
    }

    /// Picks highest mutual version; Apple 889 maps to 3.8 interop.
    private func negotiatedVersion(for serverVersion: String) throws -> String {
        if serverVersion == RFBConstants.version38 || serverVersion == RFBConstants.version3889 {
            return RFBConstants.version38
        }
        if serverVersion == RFBConstants.version37 {
            return RFBConstants.version37
        }
        if serverVersion == RFBConstants.version33 {
            return RFBConstants.version33
        }
        // Newer servers drop to our highest; anything else fails closed.
        if serverVersion.hasPrefix("RFB 003."), serverVersion.hasSuffix("\n") {
            let minorText = String(serverVersion.dropFirst(8).dropLast(1))
            if let minor = Int(minorText), minor > 8 {
                return RFBConstants.version38
            }
        }
        throw VNCAuthError.authenticationRejected("Unsupported RFB version.")
    }

    private func performSecurityNegotiation(preferred: AuthMethod, host: String) async throws -> RFBConstants.SecurityType {
        await updateState(.authenticating)
        let numTypesData = try await readExact(1)
        guard let firstByte = numTypesData.first else {
            throw VNCAuthError.authenticationRejected("Empty security negotiation packet.")
        }
        let numTypes = Int(firstByte)

        if numTypes == 0 {
            let reasonLenData = try await readExact(4)
            let len = Int(reasonLenData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            // Bound failure reason before allocating; fail closed on excess.
            guard len <= 1_048_576 else {
                throw VNCAuthError.authenticationRejected("Security failure reason too large.")
            }
            let reasonData = try await readExact(len)
            let reason = String(data: reasonData, encoding: .utf8) ?? "Unknown security error"
            throw VNCAuthError.authenticationRejected(reason)
        }

        let securityTypes = try await readExact(numTypes)
        let selectedType = try chooseSecurityType(from: securityTypes, preferred: preferred, host: host)
        try await sendExact(Data([selectedType.rawValue]))
        return selectedType
    }

    private func authenticate(
        securityType: RFBConstants.SecurityType,
        profile: ConnectionProfile,
        password: String?,
        host: String
    ) async throws {
        switch securityType {
        case .none:
            // None auth is loopback-only; reject remote unauthenticated sessions.
            guard isLoopbackHost(host) else {
                throw VNCAuthError.authenticationRejected("None security type is loopback-only.")
            }
        case .vncAuth:
            let challenge = try await readExact(16)
            let pass = password ?? ""
            let response = try SecurityHandler.encryptVNCChallenge(challenge, password: pass)
            try await sendExact(response)

            let resultData = try await readExact(4)
            let result = resultData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            if result != 0 {
                throw VNCAuthError.authenticationRejected("Invalid VNC password.")
            }
        case .appleDH:
            let paramHeader = try await readExact(4)
            guard let firstByte = paramHeader.first else {
                throw VNCAuthError.authenticationRejected("Incomplete Apple DH parameters.")
            }
            let generator = (UInt16(firstByte) << 8) | UInt16(paramHeader[1])
            let keyLength = Int((UInt16(paramHeader[2]) << 8) | UInt16(paramHeader[3]))
            guard keyLength > 0, keyLength <= 1024 else {
                throw VNCAuthError.authenticationRejected("Invalid Apple DH key length: \(keyLength)")
            }

            let primeData = try await readExact(keyLength)
            let serverPubKeyData = try await readExact(keyLength)

            let (privateKey, clientPubKey) = try SecurityHandler.generateAppleDHEphemeralKeyPair(
                generator: generator,
                primeData: primeData,
                keyLength: keyLength
            )

            try await sendExact(clientPubKey)

            let sharedSecret = try SecurityHandler.computeAppleDHSharedSecret(
                serverPublicKeyData: serverPubKeyData,
                privateKey: privateKey,
                primeData: primeData,
                keyLength: keyLength
            )

            let aesKey = SecurityHandler.deriveAppleDHAESKey(sharedSecret: sharedSecret)
            let encryptedCreds = try SecurityHandler.prepareAppleDHCredentials(
                username: profile.username,
                password: password ?? "",
                aesKey: aesKey
            )

            try await sendExact(encryptedCreds)

            let resultData = try await readExact(4)
            let result = resultData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            if result != 0 {
                throw VNCAuthError.authenticationRejected("Invalid macOS username or password.")
            }
        default:
            throw VNCAuthError.unsupportedSecurityType(securityType.rawValue)
        }
    }

    private func performServerInit() async throws {
        try await sendExact(Data([1])) // ClientInit shared-flag

        let serverInitData = try await readExact(24)
        guard let widthHigh = serverInitData.first, serverInitData.count >= 24 else {
            throw VNCAuthError.authenticationRejected("Incomplete server init response.")
        }
        let initBytes = Array(serverInitData)
        desktopWidth = Int((UInt16(widthHigh) << 8) | UInt16(initBytes[1]))
        desktopHeight = Int((UInt16(initBytes[2]) << 8) | UInt16(initBytes[3]))

        let byte0 = UInt32(initBytes[20]) << 24
        let byte1 = UInt32(initBytes[21]) << 16
        let byte2 = UInt32(initBytes[22]) << 8
        let byte3 = UInt32(initBytes[23])
        let nameLen = Int(byte0 | byte1 | byte2 | byte3)

        // Bound desktop name before allocating; fail closed on excess.
        guard nameLen <= 1_048_576 else {
            throw VNCAuthError.authenticationRejected("Desktop name too large.")
        }
        // Bound desktop extents before accepting; fail closed on excess.
        guard desktopWidth > 0, desktopHeight > 0, desktopWidth <= 8192, desktopHeight <= 8192 else {
            throw VNCAuthError.authenticationRejected("Desktop dimensions out of range.")
        }
        let nameData = try await readExact(nameLen)
        desktopName = String(data: nameData, encoding: .utf8) ?? "Mac Desktop"
        let capturedDelegate = delegate
        let capturedSelf = self
        let capturedWidth = desktopWidth
        let capturedHeight = desktopHeight
        // Hop resize to MainActor; session state stays actor-isolated.
        await MainActor.run {
            capturedDelegate?.vncClient(capturedSelf, didResizeDesktopWidth: capturedWidth, height: capturedHeight)
        }
    }

    private func chooseSecurityType(
        from serverTypes: Data,
        preferred: AuthMethod,
        host: String
    ) throws -> RFBConstants.SecurityType {
        let types = Set(serverTypes.map(\.self))
        if preferred == .appleDH, types.contains(RFBConstants.SecurityType.appleDH.rawValue) {
            return .appleDH
        }
        if preferred == .vncDES, types.contains(RFBConstants.SecurityType.vncAuth.rawValue) {
            return .vncAuth
        }
        if types.contains(RFBConstants.SecurityType.vncAuth.rawValue) {
            return .vncAuth
        }
        if types.contains(RFBConstants.SecurityType.appleDH.rawValue) {
            return .appleDH
        }
        // Offer None only to loopback hosts; otherwise treat as no mutual support.
        if types.contains(RFBConstants.SecurityType.none.rawValue), isLoopbackHost(host) {
            return .none
        }
        throw VNCAuthError.unsupportedSecurityType(serverTypes.first ?? 0)
    }

    /// Loopback allowlist gates None auth to local-only hosts.
    private func isLoopbackHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Single owner is Connection; VNC only trims then delegates.
        return ConnectionProfile.isLoopbackHost(trimmed)
    }

    private func sendPixelFormat() async throws {
        var message = Data([RFBConstants.ClientMessage.setPixelFormat.rawValue, 0, 0, 0])
        message.append(PixelFormat.standard32Bit.wireBytes)
        try await sendExact(message)
    }

    private func sendSupportedEncodings() async throws {
        // Advertise only decodable types; undecoded types would desync frame stream.
        let encodings: [RFBConstants.Encoding] = [
            .raw,
            .copyRect,
            .desktopSize,
            .lastRect
        ]
        var message = Data([RFBConstants.ClientMessage.setEncodings.rawValue, 0])
        let count = UInt16(encodings.count)
        message.append(UInt8(count >> 8))
        message.append(UInt8(count & 0xFF))
        for enc in encodings {
            let val = UInt32(bitPattern: enc.rawValue)
            message.append(UInt8((val >> 24) & 0xFF))
            message.append(UInt8((val >> 16) & 0xFF))
            message.append(UInt8((val >> 8) & 0xFF))
            message.append(UInt8(val & 0xFF))
        }
        try await sendExact(message)
    }
}
