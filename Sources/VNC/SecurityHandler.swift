// VNC — Security authentication handlers for standard VNC and macOS Screen Sharing.
import CommonCrypto
import CryptoKit
import Foundation

public enum VNCAuthError: LocalizedError, Equatable {
    case invalidChallengeLength
    case desEncryptionFailed
    case authenticationRejected(String)
    case unsupportedSecurityType(UInt8)

    public var errorDescription: String? {
        switch self {
        case .invalidChallengeLength:
            "Challenge must be exactly 16 bytes."
        case .desEncryptionFailed:
            "DES encryption failed during authentication."
        case let .authenticationRejected(reason):
            "Authentication rejected: \(reason)"
        case let .unsupportedSecurityType(type):
            "Server requested unsupported security type: \(type)"
        }
    }
}

public enum SecurityHandler {
    /// Reverses bit ordering of each password byte as mandated by RFC 6143 VNC DES auth.
    public static func reverseBits(_ byte: UInt8) -> UInt8 {
        var invertedByte = byte
        invertedByte = ((invertedByte & 0xF0) >> 4) | ((invertedByte & 0x0F) << 4)
        invertedByte = ((invertedByte & 0xCC) >> 2) | ((invertedByte & 0x33) << 2)
        invertedByte = ((invertedByte & 0xAA) >> 1) | ((invertedByte & 0x55) << 1)
        return invertedByte
    }

    /// Encrypts 16-byte server challenge using standard VNC DES bit-reversed key.
    public static func encryptVNCChallenge(_ challenge: Data, password: String) throws -> Data {
        guard challenge.count == 16 else {
            throw VNCAuthError.invalidChallengeLength
        }

        var keyBytes = [UInt8](repeating: 0, count: 8)
        let passBytes = Array(password.utf8.prefix(8))
        for (index, byte) in passBytes.enumerated() {
            keyBytes[index] = reverseBits(byte)
        }

        var response = Data(count: 16)
        var numBytesEncrypted: size_t = 0

        let status = response.withUnsafeMutableBytes { responsePtr in
            challenge.withUnsafeBytes { challengePtr in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmDES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes,
                    8,
                    nil,
                    challengePtr.baseAddress,
                    16,
                    responsePtr.baseAddress,
                    16,
                    &numBytesEncrypted
                )
            }
        }

        guard status == kCCSuccess, numBytesEncrypted == 16 else {
            throw VNCAuthError.desEncryptionFailed
        }
        return response
    }

    /// Encrypts user credentials for macOS Screen Sharing Type 30 (Apple DH/ARD).
    public static func prepareAppleDHCredentials(
        username: String,
        password: String,
        sharedKey: SymmetricKey
    ) throws -> Data {
        let payload = "\(username):\(password)"
        guard let data = payload.data(using: .utf8) else {
            throw VNCAuthError.authenticationRejected("Unable to encode credentials.")
        }
        // Encrypt credentials with AES-GCM using the negotiated key.
        let sealed = try AES.GCM.seal(data, using: sharedKey)
        guard let combined = sealed.combined else {
            throw VNCAuthError.authenticationRejected("Unable to seal credentials.")
        }
        return combined
    }
}
