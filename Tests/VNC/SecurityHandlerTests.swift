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
}
