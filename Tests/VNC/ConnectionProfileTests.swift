// Tests — Validation, serialization, and default configuration of connection profiles.
@testable import ScreenVNC
import XCTest

final class ConnectionProfileTests: XCTestCase {
    func testValidProfileValidation() throws {
        let profile = ConnectionProfile(
            name: "Mac Studio",
            host: "192.168.1.100",
            port: 5900,
            authMethod: .appleDH,
            username: "admin"
        )
        XCTAssertNoThrow(try profile.validate())
    }

    func testEmptyHostValidationFails() {
        let profile = ConnectionProfile(
            name: "Invalid Mac",
            host: "   ",
            port: 5900
        )
        XCTAssertThrowsError(try profile.validate()) { error in
            XCTAssertEqual(error as? ProfileValidationError, ProfileValidationError.emptyHost)
        }
    }

    func testInvalidPortValidationFails() {
        let profileZero = ConnectionProfile(host: "mac.local", port: 0)
        XCTAssertThrowsError(try profileZero.validate()) { error in
            XCTAssertEqual(error as? ProfileValidationError, ProfileValidationError.invalidPort(0))
        }

        let profileTooLarge = ConnectionProfile(host: "mac.local", port: 70000)
        XCTAssertThrowsError(try profileTooLarge.validate()) { error in
            XCTAssertEqual(error as? ProfileValidationError, ProfileValidationError.invalidPort(70000))
        }
    }

    func testAppleDHRequiresUsername() {
        let profile = ConnectionProfile(
            host: "mac.local",
            authMethod: .appleDH,
            username: ""
        )
        XCTAssertThrowsError(try profile.validate()) { error in
            XCTAssertEqual(error as? ProfileValidationError, ProfileValidationError.missingUsername)
        }
    }

    func testCodableRoundTrip() throws {
        let original = ConnectionProfile(
            name: "Test Mac",
            host: "10.0.0.5",
            port: 5901,
            authMethod: .vncDES,
            username: "",
            displayPreference: .actualSize,
            qualityPreference: .high,
            isFavorite: true,
            requiresBiometrics: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(original.id, decoded.id)
        XCTAssertEqual(original.name, decoded.name)
        XCTAssertEqual(original.host, decoded.host)
        XCTAssertEqual(original.port, decoded.port)
        XCTAssertEqual(original.authMethod, decoded.authMethod)
        XCTAssertEqual(original.isFavorite, decoded.isFavorite)
        XCTAssertEqual(original.requiresBiometrics, decoded.requiresBiometrics)
    }
}
