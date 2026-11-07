// Tests — Decoding logic for Raw, CopyRect, and Cursor pseudo-encodings.
@testable import ScreenVNC
import XCTest

final class RFBEncodingsTests: XCTestCase {
    func testDecodeRaw() {
        let testPixels = Data([10, 20, 30, 40, 50, 60, 70, 80])
        let rect = RFBEncodings.decodeRaw(
            data: testPixels,
            originX: 5,
            originY: 10,
            width: 2,
            height: 1,
            bytesPerPixel: 4
        )
        XCTAssertEqual(rect.originX, 5)
        XCTAssertEqual(rect.originY, 10)
        XCTAssertEqual(rect.width, 2)
        XCTAssertEqual(rect.height, 1)
        XCTAssertEqual(rect.pixels?.count, 8)
    }

    func testDecodeCopyRect() {
        // srcX = 100 (0x0064), srcY = 200 (0x00C8)
        let copyData = Data([0x00, 0x64, 0x00, 0xC8])
        let coords = RFBEncodings.decodeCopyRect(
            data: copyData,
            destX: 0,
            destY: 0,
            width: 50,
            height: 50
        )
        XCTAssertNotNil(coords)
        XCTAssertEqual(coords?.srcX, 100)
        XCTAssertEqual(coords?.srcY, 200)
    }

    func testDecodeCursor() {
        // Cursor 2x2 pixels = 16 bytes. Bitmask for 2x2: (2+7)/8 = 1 byte per row * 2 rows = 2 bytes.
        let pixelBytes = Data(repeating: 0xFF, count: 16)
        let maskBytes = Data([0b1100_0000, 0b1100_0000])
        var cursorData = pixelBytes
        cursorData.append(maskBytes)

        let cursor = RFBEncodings.decodeCursor(
            data: cursorData,
            cursorX: 1,
            cursorY: 1,
            width: 2,
            height: 2,
            bytesPerPixel: 4
        )
        XCTAssertNotNil(cursor)
        XCTAssertEqual(cursor?.hotspotX, 1)
        XCTAssertEqual(cursor?.hotspotY, 1)
        XCTAssertEqual(cursor?.pixels.count, 16)
        XCTAssertEqual(cursor?.bitmask.count, 2)
    }
}
