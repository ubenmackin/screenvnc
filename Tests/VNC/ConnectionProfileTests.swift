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
        XCTAssertFalse(decoded.allowUnencryptedSession)
    }

    func testAllowUnencryptedSessionSuppressesPlaintextConsent() {
        var profile = ConnectionProfile(
            name: "MacBook Air",
            host: "macbookair.local",
            port: 5900,
            authMethod: .vncDES
        )
        XCTAssertTrue(profile.requiresPlaintextConsent)

        profile.allowUnencryptedSession = true
        XCTAssertFalse(profile.requiresPlaintextConsent)
    }

    func testLegacyProfileJSONDecodesWithoutAllowUnencryptedKey() throws {
        let legacyJSON = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Legacy Mac",
            "host": "192.168.1.42",
            "port": 5900,
            "authMethod": "vncDES",
            "username": "",
            "displayPreference": "fit",
            "qualityPreference": "adaptive",
            "isFavorite": false,
            "requiresBiometrics": false
        }
        """
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertEqual(decoded.name, "Legacy Mac")
        XCTAssertFalse(decoded.allowUnencryptedSession)
        XCTAssertTrue(decoded.requiresPlaintextConsent)
    }
}
