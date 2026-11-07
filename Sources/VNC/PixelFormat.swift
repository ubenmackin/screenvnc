// VNC — Remote Framebuffer 16-byte pixel format specification and serialization.
import Foundation

public struct PixelFormat: Sendable, Equatable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndianFlag: UInt8
    public var trueColourFlag: UInt8
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    /// Standard truecolor 32-bit ARGB/BGRA layout optimized for Apple platforms.
    public static let standard32Bit = PixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndianFlag: 0,
        trueColourFlag: 1,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    public init(
        bitsPerPixel: UInt8,
        depth: UInt8,
        bigEndianFlag: UInt8,
        trueColourFlag: UInt8,
        redMax: UInt16,
        greenMax: UInt16,
        blueMax: UInt16,
        redShift: UInt8,
        greenShift: UInt8,
        blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndianFlag = bigEndianFlag
        self.trueColourFlag = trueColourFlag
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    public init(data: Data) {
        guard let firstByte = data.first, data.count >= 13 else {
            self = .standard32Bit
            return
        }
        let bytes = Array(data)
        bitsPerPixel = firstByte
        depth = bytes.count > 1 ? bytes[1] : 24
        bigEndianFlag = bytes.count > 2 ? bytes[2] : 0
        trueColourFlag = bytes.count > 3 ? bytes[3] : 1
        redMax = (UInt16(bytes[4]) << 8) | UInt16(bytes[5])
        greenMax = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
        blueMax = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
        redShift = bytes[10]
        greenShift = bytes[11]
        blueShift = bytes[12]
    }

    public var wireBytes: Data {
        let bytes: [UInt8] = [
            bitsPerPixel,
            depth,
            bigEndianFlag,
            trueColourFlag,
            UInt8(redMax >> 8),
            UInt8(redMax & 0xFF),
            UInt8(greenMax >> 8),
            UInt8(greenMax & 0xFF),
            UInt8(blueMax >> 8),
            UInt8(blueMax & 0xFF),
            redShift,
            greenShift,
            blueShift,
            0,
            0,
            0
        ]
        return Data(bytes)
    }
}
