// Tests — RFB PixelFormat 16-byte serialization and round-trip parsing.
@testable import ScreenVNC
import XCTest

final class PixelFormatTests: XCTestCase {
    func testStandard32BitPixelFormat() {
        let format = PixelFormat.standard32Bit
        XCTAssertEqual(format.bitsPerPixel, 32)
        XCTAssertEqual(format.depth, 24)
        XCTAssertEqual(format.trueColourFlag, 1)
        XCTAssertEqual(format.redMax, 255)
        XCTAssertEqual(format.greenMax, 255)
        XCTAssertEqual(format.blueMax, 255)
        XCTAssertEqual(format.redShift, 16)
        XCTAssertEqual(format.greenShift, 8)
        XCTAssertEqual(format.blueShift, 0)
    }

    func testPixelFormatSerializationRoundTrip() {
        let original = PixelFormat.standard32Bit
        let wire = original.wireBytes
        XCTAssertEqual(wire.count, 16)

        let parsed = PixelFormat(data: wire)
        XCTAssertEqual(original, parsed)
    }
}
