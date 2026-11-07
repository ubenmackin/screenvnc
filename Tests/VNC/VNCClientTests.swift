// VNC Tests — ScreenVNC client stub coverage.
@testable import ScreenVNC
import XCTest

final class VNCClientTests: XCTestCase {
    func testClientInit() {
        _ = VNCClient()
        XCTAssertTrue(true)
    }
}
