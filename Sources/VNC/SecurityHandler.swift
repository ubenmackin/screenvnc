// VNC — Security authentication handlers for standard VNC and macOS Screen Sharing.
import CommonCrypto
import CryptoKit
import Foundation
import Security

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

    /// Generates Diffie-Hellman ephemeral keypair for Apple ARD Type 30 authentication.
    public static func generateAppleDHEphemeralKeyPair(
        generator: UInt16,
        primeData: Data,
        keyLength: Int
    ) throws -> (privateKey: BigUInt, publicKeyData: Data) {
        let genVal = BigUInt(UInt64(generator))
        let modulus = BigUInt(bigEndian: primeData)
        // Fail closed on injected parameters; a hostile prime or generator collapses the group.
        try validateAppleDHPrime(primeData)
        guard generator >= 2 else {
            throw VNCAuthError.authenticationRejected("Invalid Diffie-Hellman generator: \(generator)")
        }

        // Generate 256-bit random private exponent
        var randomBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &randomBytes)
        guard status == errSecSuccess else {
            throw VNCAuthError.authenticationRejected("Failed to generate cryptographic random bytes.")
        }
        let privExp = BigUInt(bigEndian: Data(randomBytes))
        let clientPub = try genVal.power(privExp, modulus: modulus)
        let pubData = clientPub.serialize(minBytes: keyLength)
        return (privExp, pubData)
    }

    /// Computes Diffie-Hellman shared secret S = (A^b) mod p for Apple ARD Type 30.
    public static func computeAppleDHSharedSecret(
        serverPublicKeyData: Data,
        privateKey: BigUInt,
        primeData: Data,
        keyLength: Int
    ) throws -> Data {
        let peerPub = BigUInt(bigEndian: serverPublicKeyData)
        let modulus = BigUInt(bigEndian: primeData)
        // Parameters arrive independently on the wire; revalidate before modular math.
        try validateAppleDHPrime(primeData)
        // Reject peer keys that trivially collapse the group: 0, 1, p-1, or >= p.
        guard !peerPub.isZero, peerPub > BigUInt(1), peerPub < modulus - BigUInt(1) else {
            throw VNCAuthError.authenticationRejected("Invalid Diffie-Hellman server public key.")
        }
        let shared = try peerPub.power(privateKey, modulus: modulus)
        return shared.serialize(minBytes: keyLength)
    }

    /// Validates server-supplied Apple DH prime: odd, top bit set, at least 512 bits.
    /// Blocks p = 2 style degenerate moduli and small-subgroup confinement before any math runs.
    private static func validateAppleDHPrime(_ primeData: Data) throws {
        guard primeData.count >= 64, let leading = primeData.first, leading & 0x80 == 0x80,
              let trailing = primeData.last, trailing & 0x01 == 0x01
        else {
            throw VNCAuthError.authenticationRejected("Invalid Diffie-Hellman prime modulus.")
        }
    }

    /// Derives 16-byte AES-128 key by taking MD5 hash of the shared secret.
    public static func deriveAppleDHAESKey(sharedSecret: Data) -> Data {
        let digest = Insecure.MD5.hash(data: sharedSecret)
        return Data(digest)
    }

    /// Packs and encrypts credentials for macOS Screen Sharing Type 30 (Apple DH/ARD).
    /// Uses 128-byte block: username (64 bytes null-padded) + password (64 bytes null-padded)
    /// encrypted with AES-128-ECB.
    public static func prepareAppleDHCredentials(
        username: String,
        password: String,
        aesKey: Data
    ) throws -> Data {
        guard aesKey.count == 16 else {
            throw VNCAuthError.authenticationRejected("Invalid AES key length for Apple DH.")
        }

        var plainBlock = [UInt8](repeating: 0, count: 128)
        let userBytes = Array(username.utf8.prefix(63))
        for (idx, byte) in userBytes.enumerated() {
            plainBlock[idx] = byte
        }
        let passBytes = Array(password.utf8.prefix(63))
        for (idx, byte) in passBytes.enumerated() {
            plainBlock[64 + idx] = byte
        }

        var cipherBlock = [UInt8](repeating: 0, count: 128)
        var numBytesEncrypted: size_t = 0

        let cryptStatus = aesKey.withUnsafeBytes { keyPtr in
            CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode),
                keyPtr.baseAddress,
                16,
                nil,
                plainBlock,
                128,
                &cipherBlock,
                128,
                &numBytesEncrypted
            )
        }

        guard cryptStatus == kCCSuccess, numBytesEncrypted == 128 else {
            throw VNCAuthError.authenticationRejected("AES encryption of Apple DH credentials failed.")
        }

        return Data(cipherBlock)
    }
}
