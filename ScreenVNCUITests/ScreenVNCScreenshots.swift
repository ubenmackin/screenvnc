// UI Tests — ScreenVNC screenshot capture stub.
import XCTest

final class ScreenVNCScreenshots: XCTestCase {
    @MainActor func testLaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(true)
    }
}
