// Tests — Keyboard avoidance overlap and dock padding math.
@testable import ScreenVNC
import XCTest

@MainActor
final class SessionKeyboardAvoidanceTests: XCTestCase {
    func testHiddenKeyboardOverlapIsZero() {
        XCTAssertEqual(keyboardOverlap(keyboardHeight: 0, bottomSafeInset: 0), 0)
        XCTAssertEqual(keyboardOverlap(keyboardHeight: 0, bottomSafeInset: 34), 0)
    }

    func testOverlapClampsNegativeToZero() {
        // Keyboard shorter than the home-indicator inset must not pull chrome downward.
        XCTAssertEqual(keyboardOverlap(keyboardHeight: 20, bottomSafeInset: 34), 0)
    }

    func testDockedKeyboardSubtractsBottomInset() {
        XCTAssertEqual(
            keyboardOverlap(keyboardHeight: 336, bottomSafeInset: 34),
            302,
            accuracy: 0.001
        )
    }

    func testFloatingKeyboardHeightWithoutInset() {
        // Floating keyboard reports its own frame height with no bottom inset consumed.
        XCTAssertEqual(
            keyboardOverlap(keyboardHeight: 260, bottomSafeInset: 0),
            260,
            accuracy: 0.001
        )
    }

    func testHomeIndicatorInsetSubtraction() {
        XCTAssertEqual(
            keyboardOverlap(keyboardHeight: 350, bottomSafeInset: 34),
            316,
            accuracy: 0.001
        )
    }

    func testMode1DockPaddingUsesBase12() {
        XCTAssertEqual(
            sessionDockBottomPadding(safeBottom: 0, base: 12, overlap: 0),
            12,
            accuracy: 0.001
        )
        XCTAssertEqual(
            sessionDockBottomPadding(safeBottom: 34, base: 12, overlap: 302),
            336,
            accuracy: 0.001
        )
    }

    func testMode2DockPaddingUsesBase16() {
        XCTAssertEqual(
            sessionDockBottomPadding(safeBottom: 0, base: 16, overlap: 0),
            16,
            accuracy: 0.001
        )
        XCTAssertEqual(
            sessionDockBottomPadding(safeBottom: 21, base: 16, overlap: 260),
            281,
            accuracy: 0.001
        )
    }

    func testDockPaddingPrefersLargerSafeBottomOverBase() {
        // Safe area wins over the mode base; overlap always stacks on top.
        XCTAssertEqual(
            sessionDockBottomPadding(safeBottom: 34, base: 12, overlap: 0),
            34,
            accuracy: 0.001
        )
        XCTAssertEqual(
            sessionDockBottomPadding(safeBottom: 8, base: 16, overlap: 10),
            26,
            accuracy: 0.001
        )
    }
}
