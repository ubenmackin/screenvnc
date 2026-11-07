// Tests — Framebuffer coordinate conversion math and boundary clamping.
@testable import ScreenVNC
import SwiftUI
import XCTest

@MainActor
final class InputTranslationTests: XCTestCase {
    func testCoordinateConversionCenter() {
        let framebuffer = Framebuffer(width: 1920, height: 1080)
        let fbView = FramebufferView(framebuffer: framebuffer) { _, _, _ in }

        // Test center point in matching aspect ratio view (16:9 view)
        let viewSize = CGSize(width: 1920, height: 1080)
        let centerPoint = CGPoint(x: 960, y: 540)
        let remote = fbView.convertToRemote(point: centerPoint, in: viewSize)

        XCTAssertEqual(remote.x, 960)
        XCTAssertEqual(remote.y, 540)
    }

    func testCoordinateConversionClamping() {
        let framebuffer = Framebuffer(width: 1920, height: 1080)
        let fbView = FramebufferView(framebuffer: framebuffer) { _, _, _ in }

        let viewSize = CGSize(width: 1920, height: 1080)
        // Outside top-left bounds
        let negativePoint = CGPoint(x: -100, y: -50)
        let remoteTopLeft = fbView.convertToRemote(point: negativePoint, in: viewSize)
        XCTAssertEqual(remoteTopLeft.x, 0)
        XCTAssertEqual(remoteTopLeft.y, 0)

        // Outside bottom-right bounds
        let beyondPoint = CGPoint(x: 3000, y: 2000)
        let remoteBottomRight = fbView.convertToRemote(point: beyondPoint, in: viewSize)
        XCTAssertEqual(remoteBottomRight.x, 1919)
        XCTAssertEqual(remoteBottomRight.y, 1079)
    }
}
