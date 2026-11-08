// Tests — Decoding logic for Raw, CopyRect, Cursor pseudo-encoding, and batched framebuffer updates.
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

    func testDecodeCursorAndPremultipliedBGRA() {
        // 2x2 cursor: top-left & bottom-right opaque (MSB 0b1000_0000 and 0b0100_0000).
        let pixelBytes = Data([
            10, 20, 30, 0, // (0,0) opaque
            40, 50, 60, 0, // (1,0) transparent
            70, 80, 90, 0, // (0,1) transparent
            110, 120, 130, 0 // (1,1) opaque
        ])
        let maskBytes = Data([0b1000_0000, 0b0100_0000])
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

        let bgra = cursor?.premultipliedBGRA()
        XCTAssertEqual(bgra?.count, 16)
        if let bytes = bgra.map({ Array($0) }) {
            // (0,0) opaque -> alpha 0xFF
            XCTAssertEqual(bytes[0], 10)
            XCTAssertEqual(bytes[3], 0xFF)
            // (1,0) transparent -> zeroed premultiplied BGRA
            XCTAssertEqual(bytes[4], 0)
            XCTAssertEqual(bytes[7], 0)
            // (0,1) transparent
            XCTAssertEqual(bytes[11], 0)
            // (1,1) opaque
            XCTAssertEqual(bytes[12], 110)
            XCTAssertEqual(bytes[15], 0xFF)
        }
    }

    @MainActor
    func testFramebufferBatchAndCursorUpdate() {
        let fb = Framebuffer(width: 8, height: 8)
        XCTAssertFalse(fb.hasReceivedFirstFrame)

        let rawPixels = Data(repeating: 0xAA, count: 2 * 2 * 4)
        let rawRect = DecodedRect(originX: 0, originY: 0, width: 2, height: 2, pixels: rawPixels)
        let copyDest = DecodedRect(originX: 4, originY: 4, width: 2, height: 2)
        fb.applyUpdateBatch([
            .raw(rawRect),
            .copy(dest: copyDest, srcX: 0, srcY: 0)
        ])

        XCTAssertTrue(fb.hasReceivedFirstFrame)
        XCTAssertNotNil(fb.image)

        let cursor = DecodedCursor(
            hotspotX: 0,
            hotspotY: 0,
            width: 1,
            height: 1,
            pixels: Data([0xFF, 0xFF, 0xFF, 0x00]),
            bitmask: Data([0x80])
        )
        fb.updateCursor(cursor)
        XCTAssertTrue(fb.isCursorVisible)
        XCTAssertNotNil(fb.cursorImage)

        fb.updateCursor(nil)
        XCTAssertFalse(fb.isCursorVisible)
        XCTAssertNil(fb.cursorImage)
    }
}
