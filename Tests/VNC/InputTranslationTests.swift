// Tests — Framebuffer coordinate conversion, focal zoom, pan clamping, and scroll math.
@testable import ScreenVNC
import SwiftUI
import XCTest

@MainActor
final class InputTranslationTests: XCTestCase {
    func testCoordinateConversionCenter() {
        // Drives ViewportTransform directly: reading FramebufferView's @State outside a
        // live view install emits SwiftUI diagnostics and constructs fresh values per access.
        let transform = ViewportTransform(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            viewSize: CGSize(width: 1920, height: 1080)
        )

        let centerPoint = CGPoint(x: 960, y: 540)
        let remote = transform.convertToRemote(viewPoint: centerPoint)

        XCTAssertEqual(remote.x, 960)
        XCTAssertEqual(remote.y, 540)
    }

    func testCoordinateConversionClamping() {
        let transform = ViewportTransform(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            viewSize: CGSize(width: 1920, height: 1080)
        )

        let negativePoint = CGPoint(x: -100, y: -50)
        let remoteTopLeft = transform.convertToRemote(viewPoint: negativePoint)
        XCTAssertEqual(remoteTopLeft.x, 0)
        XCTAssertEqual(remoteTopLeft.y, 0)

        let beyondPoint = CGPoint(x: 3000, y: 2000)
        let remoteBottomRight = transform.convertToRemote(viewPoint: beyondPoint)
        XCTAssertEqual(remoteBottomRight.x, 1919)
        XCTAssertEqual(remoteBottomRight.y, 1079)
    }

    func testFitModeLetterboxTranslation() {
        // Portrait iPhone viewport (393x852) displaying 1920x1080 Mac desktop in .fit mode.
        let transform = ViewportTransform(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            viewSize: CGSize(width: 393, height: 852),
            displayPreference: .fit
        )
        let rect = transform.transformedContentRect
        XCTAssertEqual(rect.width, 393, accuracy: 0.5)
        XCTAssertEqual(rect.minY, (852 - rect.height) / 2.0, accuracy: 0.5)

        // Tapping the top menu bar of the fitted Mac image must map near y = 0, not jump.
        let topMenuTap = CGPoint(x: rect.midX, y: rect.minY + 1)
        let topRemote = transform.convertToRemote(viewPoint: topMenuTap)
        XCTAssertEqual(topRemote.x, 960, accuracy: 2)
        XCTAssertLessThanOrEqual(topRemote.y, 10)

        // Tapping the bottom Dock must map near y = 1079.
        let bottomTap = CGPoint(x: rect.midX, y: rect.maxY - 1)
        let bottomRemote = transform.convertToRemote(viewPoint: bottomTap)
        XCTAssertGreaterThanOrEqual(bottomRemote.y, 1070)
    }

    func testActualSizeAndZoomedPanRoundTrip() {
        let transform = ViewportTransform(
            framebufferWidth: 2560,
            framebufferHeight: 1600,
            viewSize: CGSize(width: 393, height: 852),
            displayPreference: .actualSize,
            zoomScale: 2.0,
            panOffset: CGSize(width: 240, height: -150)
        )
        let targetRemote = CGPoint(x: 1100, y: 700)
        let viewPoint = transform.convertToView(remotePoint: targetRemote)
        let roundTrip = transform.convertToRemote(viewPoint: viewPoint)

        XCTAssertEqual(roundTrip.x, Int(targetRemote.x), accuracy: 1)
        XCTAssertEqual(roundTrip.y, Int(targetRemote.y), accuracy: 1)
    }

    func testFocalPointPinchKeepsAnchorStationary() {
        // When both axes exceed viewport dimensions, the pinch anchor plus translation stays invariant.
        let initial = ViewportTransform(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            viewSize: CGSize(width: 800, height: 450),
            displayPreference: .fit,
            zoomScale: 2.0,
            panOffset: CGSize(width: 20, height: -10)
        )
        let anchor = CGPoint(x: 240, y: 180)
        let remoteAtAnchor = initial.convertToRemote(viewPoint: anchor)
        let pinnedRemoteBefore = initial.convertToView(remotePoint: CGPoint(
            x: remoteAtAnchor.x,
            y: remoteAtAnchor.y
        ))

        let translation = CGSize(width: 15, height: -25)
        let updatedState = initial.focalZoomUpdate(scaleDelta: 1.5, anchor: anchor, translationDelta: translation)

        var zoomed = initial
        zoomed.zoomScale = updatedState.zoomScale
        zoomed.panOffset = updatedState.panOffset

        let viewAfter = zoomed.convertToView(remotePoint: CGPoint(x: remoteAtAnchor.x, y: remoteAtAnchor.y))
        XCTAssertEqual(viewAfter.x, pinnedRemoteBefore.x + translation.width, accuracy: 2.0)
        XCTAssertEqual(viewAfter.y, pinnedRemoteBefore.y + translation.height, accuracy: 2.0)

        // When only X overflows (portrait fit at 1.5x), X stays anchored while non-overflowing Y centers.
        let portrait = ViewportTransform(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            viewSize: CGSize(width: 400, height: 800),
            displayPreference: .fit,
            zoomScale: 1.5,
            panOffset: CGSize(width: 20, height: 0)
        )
        let portraitResult = portrait.focalZoomUpdate(scaleDelta: 1.5, anchor: CGPoint(x: 120, y: 400), translationDelta: .zero)
        XCTAssertEqual(portraitResult.panOffset.height, 0, accuracy: 0.1)
    }

    func testPanClampingRespectsBoundsAndInsets() {
        let fitUnzoomed = ViewportTransform(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            viewSize: CGSize(width: 393, height: 852),
            displayPreference: .fit,
            zoomScale: 1.0
        )
        XCTAssertFalse(fitUnzoomed.canPan)
        XCTAssertEqual(fitUnzoomed.clampedPanOffset(CGSize(width: 200, height: 200)), .zero)

        let actual = ViewportTransform(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            viewSize: CGSize(width: 400, height: 800),
            displayPreference: .actualSize,
            zoomScale: 1.0,
            panInsets: EdgeInsets(top: 50, leading: 0, bottom: 80, trailing: 0)
        )
        XCTAssertTrue(actual.canPan)
        // Left edge at most reaches 0; top edge can drop below 50pt top safe-area inset.
        let maxTopLeft = actual.clampedPanOffset(CGSize(width: 5000, height: 5000))
        XCTAssertEqual(maxTopLeft.width, (1920 - 400) / 2.0, accuracy: 0.5)
        XCTAssertEqual(maxTopLeft.height, (1080 - 800) / 2.0 + 50.0, accuracy: 0.5)

        let minBottomRight = actual.clampedPanOffset(CGSize(width: -5000, height: -5000))
        XCTAssertEqual(minBottomRight.height, -((1080 - 800) / 2.0) - 80.0, accuracy: 0.5)
    }

    func testTrackpadDeltaScalesWithZoomAndVelocity() {
        let unzoomed = ViewportTransform(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            viewSize: CGSize(width: 400, height: 800),
            displayPreference: .fit,
            zoomScale: 1.0
        )
        let zoomed = ViewportTransform(
            framebufferWidth: 1920,
            framebufferHeight: 1080,
            viewSize: CGSize(width: 400, height: 800),
            displayPreference: .fit,
            zoomScale: 3.0
        )

        let slowUnzoomed = unzoomed.trackpadDelta(
            translationDelta: CGSize(width: 10, height: 0),
            velocity: CGPoint(x: 40, y: 0),
            sensitivity: 1.0
        )
        let fastUnzoomed = unzoomed.trackpadDelta(
            translationDelta: CGSize(width: 10, height: 0),
            velocity: CGPoint(x: 900, y: 0),
            sensitivity: 1.0
        )
        let slowZoomed = zoomed.trackpadDelta(
            translationDelta: CGSize(width: 10, height: 0),
            velocity: CGPoint(x: 40, y: 0),
            sensitivity: 1.0
        )

        XCTAssertGreaterThan(fastUnzoomed.width, slowUnzoomed.width)
        XCTAssertLessThan(slowZoomed.width, slowUnzoomed.width)
    }

    func testScrollAccumulatorNaturalAndClassicDirections() {
        var natural = ScrollAccumulator(stepThreshold: 18)
        // Swiping fingers up (negative deltaY) with Natural Scrolling emits RFB scrollUp (positive stepsY).
        XCTAssertEqual(natural.consume(deltaX: 0, deltaY: -10, naturalScrolling: true).stepsY, 0)
        XCTAssertEqual(natural.consume(deltaX: 0, deltaY: -10, naturalScrolling: true).stepsY, 1)

        var classic = ScrollAccumulator(stepThreshold: 18)
        XCTAssertEqual(classic.consume(deltaX: 0, deltaY: -20, naturalScrolling: false).stepsY, -1)
    }
}
