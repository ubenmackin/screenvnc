// VNC — Decoders for Raw, CopyRect, ZRLE, and pseudo-encodings.
import Compression
import Foundation

public struct DecodedRect: Sendable {
    public let originX: Int
    public let originY: Int
    public let width: Int
    public let height: Int
    public let pixels: Data?

    public init(originX: Int, originY: Int, width: Int, height: Int, pixels: Data? = nil) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public struct DecodedCursor: Sendable {
    public let hotspotX: Int
    public let hotspotY: Int
    public let pixels: Data
    public let bitmask: Data

    public init(hotspotX: Int, hotspotY: Int, pixels: Data, bitmask: Data) {
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
        self.bitmask = bitmask
    }
}

public enum RFBEncodings {
    /// Decodes uncompressed Raw rectangular pixels.
    public static func decodeRaw(
        data: Data,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int,
        bytesPerPixel: Int = 4
    ) -> DecodedRect {
        let expectedBytes = width * height * bytesPerPixel
        let slice = data.prefix(expectedBytes)
        return DecodedRect(originX: originX, originY: originY, width: width, height: height, pixels: slice)
    }

    /// Decodes CopyRect source coordinates for hardware-accelerated local blitting.
    public static func decodeCopyRect(
        data: Data,
        destX _: Int,
        destY _: Int,
        width _: Int,
        height _: Int
    ) -> (srcX: Int, srcY: Int)? {
        guard let firstByte = data.first, data.count >= 4 else { return nil }
        let bytes = Array(data)
        let srcX = Int((UInt16(firstByte) << 8) | UInt16(bytes[1]))
        let srcY = Int((UInt16(bytes[2]) << 8) | UInt16(bytes[3]))
        return (srcX, srcY)
    }

    /// Decodes remote cursor shape and hotspot coordinates.
    public static func decodeCursor(
        data: Data,
        cursorX: Int,
        cursorY: Int,
        width: Int,
        height: Int,
        bytesPerPixel: Int = 4
    ) -> DecodedCursor? {
        let pixelBytes = width * height * bytesPerPixel
        let maskRowBytes = (width + 7) / 8
        let maskBytes = maskRowBytes * height
        guard data.count >= pixelBytes + maskBytes else { return nil }

        let pixels = data.prefix(pixelBytes)
        let bitmask = data.dropFirst(pixelBytes).prefix(maskBytes)
        return DecodedCursor(hotspotX: cursorX, hotspotY: cursorY, pixels: pixels, bitmask: bitmask)
    }

    /// Decompresses Zlib payload for ZRLE tile processing.
    public static func decompressZlib(data: Data, outputCapacity: Int) -> Data? {
        // Fail closed on empty input or capacity; avoids nil base addresses.
        guard !data.isEmpty, outputCapacity > 0 else { return nil }
        var destination = Data(count: outputCapacity)
        let decodedSize = destination.withUnsafeMutableBytes { destPtr in
            data.withUnsafeBytes { srcPtr in
                guard let destBase = destPtr.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = srcPtr.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destBase,
                    outputCapacity,
                    srcBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedSize > 0 else { return nil }
        return destination.prefix(decodedSize)
    }
}
