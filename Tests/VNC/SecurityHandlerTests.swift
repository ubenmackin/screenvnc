// Tests — Bit reversal and VNC DES encryption verification against test vectors.
@testable import ScreenVNC
import XCTest

final class SecurityHandlerTests: XCTestCase {
    func testBitReversal() {
        // RFC 6143 VNC authentication requires MSB to LSB byte inversion.
        XCTAssertEqual(SecurityHandler.reverseBits(0b1000_0000), 0b0000_0001)
        XCTAssertEqual(SecurityHandler.reverseBits(0b0000_0001), 0b1000_0000)
        XCTAssertEqual(SecurityHandler.reverseBits(0b1100_1010), 0b0101_0011)
        XCTAssertEqual(SecurityHandler.reverseBits(0b0000_0000), 0b0000_0000)
        XCTAssertEqual(SecurityHandler.reverseBits(0b1111_1111), 0b1111_1111)
    }

    func testInvalidChallengeLengthThrows() {
        let shortChallenge = Data(repeating: 0x42, count: 10)
        XCTAssertThrowsError(try SecurityHandler.encryptVNCChallenge(shortChallenge, password: "test")) { error in
            XCTAssertEqual(error as? VNCAuthError, VNCAuthError.invalidChallengeLength)
        }
    }

    func testVNCChallengeEncryptionProduces16Bytes() throws {
        let challenge = Data(repeating: 0x1A, count: 16)
        let response = try SecurityHandler.encryptVNCChallenge(challenge, password: "password")
        XCTAssertEqual(response.count, 16)
        // Ensure ciphertext is non-trivial and differs from plaintext challenge
        XCTAssertNotEqual(response, challenge)
    }

    func testBigUIntModularExponentiation() throws {
        // (g^b) mod p with known values
        let generatorVal = BigUInt(5)
        let privateExponent = BigUInt(117)
        let primeModulus = BigUInt(1009) // prime
        let result = try generatorVal.power(privateExponent, modulus: primeModulus)
        XCTAssertTrue(result < primeModulus)
        XCTAssertFalse(result.isZero)
    }

    func testAppleDHSharedSecretAndCredentials() throws {
        // Test Diffie-Hellman round-trip between client and simulated server
        let generator: UInt16 = 2
        // 128-byte (1024-bit) dummy prime
        var primeBytes = [UInt8](repeating: 0xEE, count: 128)
        primeBytes[0] = 0x80 // ensure high bit
        primeBytes[127] = 0x01 // ensure odd
        let primeData = Data(primeBytes)

        let (clientPriv, clientPub) = try SecurityHandler.generateAppleDHEphemeralKeyPair(
            generator: generator,
            primeData: primeData,
            keyLength: 128
        )
        XCTAssertEqual(clientPub.count, 128)

        let (serverPriv, serverPub) = try SecurityHandler.generateAppleDHEphemeralKeyPair(
            generator: generator,
            primeData: primeData,
            keyLength: 128
        )
        XCTAssertEqual(serverPub.count, 128)

        // S_client = (serverPub ^ clientPriv) mod p
        let clientSecret = try SecurityHandler.computeAppleDHSharedSecret(
            serverPublicKeyData: serverPub,
            privateKey: clientPriv,
            primeData: primeData,
            keyLength: 128
        )
        // S_server = (clientPub ^ serverPriv) mod p
        let serverSecret = try SecurityHandler.computeAppleDHSharedSecret(
            serverPublicKeyData: clientPub,
            privateKey: serverPriv,
            primeData: primeData,
            keyLength: 128
        )

        // Diffie-Hellman property: both computed shared secrets must match!
        XCTAssertEqual(clientSecret, serverSecret)

        // Test AES credential encryption
        let aesKey = SecurityHandler.deriveAppleDHAESKey(sharedSecret: clientSecret)
        XCTAssertEqual(aesKey.count, 16)

        let encrypted = try SecurityHandler.prepareAppleDHCredentials(
            username: "admin",
            password: "secretpassword",
            aesKey: aesKey
        )
        XCTAssertEqual(encrypted.count, 128)
    }
}
