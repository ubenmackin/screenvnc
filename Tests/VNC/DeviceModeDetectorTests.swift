// Tests — Mode classification and hinge posture detection for iPhone, iPad, and Duo.
@testable import ScreenVNC
import SwiftUI
import XCTest

final class DeviceModeDetectorTests: XCTestCase {
    func testDetectMode2ForTabletOrUnfoldedDuo() {
        // Regular horizontal + regular vertical traits -> Mode 2 (iPad / Duo Inner Display)
        let mode = DeviceModeDetector.detectMode(
            horizontalSizeClass: .regular,
            verticalSizeClass: .regular,
            screenSize: CGSize(width: 800, height: 1100)
        )
        XCTAssertEqual(mode, .mode2InnerDisplayOrPad)
    }

    func testDetectMode1ForStandardPhone() {
        // Standard iPhone (e.g. iPhone 17 Pro): 393 x 852 (aspect ratio ~ 2.16)
        let mode = DeviceModeDetector.detectMode(
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular,
            screenSize: CGSize(width: 393, height: 852)
        )
        XCTAssertEqual(mode, .mode1NormalPhone)
    }

    func testDetectMode3ForDuoOuterScreen() {
        // iPhone Duo outer display: 5.4" (1398 x 2034, aspect ratio ~ 1.45:1)
        let mode = DeviceModeDetector.detectMode(
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular,
            screenSize: CGSize(width: 466, height: 678)
        )
        XCTAssertEqual(mode, .mode3DuoOuterScreen)
    }

    func testHingePostureDetection() {
        XCTAssertEqual(DeviceModeDetector.detectPosture(hingeAngle: 0), .closed)
        XCTAssertEqual(DeviceModeDetector.detectPosture(hingeAngle: 10), .closed)
        XCTAssertEqual(DeviceModeDetector.detectPosture(hingeAngle: 90), .tabletop)
        XCTAssertEqual(DeviceModeDetector.detectPosture(hingeAngle: 120), .tabletop)
        XCTAssertEqual(DeviceModeDetector.detectPosture(hingeAngle: 180), .flat)
    }
}
