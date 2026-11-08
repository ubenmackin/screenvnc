// Rendering — Framebuffer double-buffering, invalidation coalescing, and image generation.
import CoreGraphics
import Foundation
import Observation

@Observable
@MainActor
public final class Framebuffer {
    public private(set) var width: Int
    public private(set) var height: Int
    public private(set) var image: CGImage?
    public private(set) var hasReceivedFirstFrame: Bool = false
    public var cursorPosition: CGPoint = .zero
    public var isCursorVisible: Bool = false

    private var pixelBuffer: Data
    private let bytesPerPixel = 4
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue

    public init(width: Int = 1920, height: Int = 1080) {
        // Cap absurd sizes so corrupt dimensions cannot force a huge allocation.
        let cappedWidth = min(max(width, 1), 16384)
        let cappedHeight = min(max(height, 1), 16384)
        let (pixels, mulOverflow) = cappedWidth.multipliedReportingOverflow(by: cappedHeight)
        let (byteCount, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        // Fail closed to minimal canvas when dimensions overflow.
        guard !mulOverflow, !byteOverflow else {
            self.width = 1
            self.height = 1
            pixelBuffer = Data(count: 1 * bytesPerPixel)
            regenerateImage()
            return
        }
        self.width = cappedWidth
        self.height = cappedHeight
        pixelBuffer = Data(count: byteCount)
        regenerateImage()
    }

    public func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        // Cap absurd sizes so a corrupt DesktopSize cannot force a huge allocation.
        guard width <= 16384, height <= 16384 else { return }
        let (pixels, mulOverflow) = width.multipliedReportingOverflow(by: height)
        guard !mulOverflow else { return }
        let (_, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        guard !byteOverflow else { return }
        self.width = width
        self.height = height
        hasReceivedFirstFrame = false
        pixelBuffer = Data(count: width * height * bytesPerPixel)
        regenerateImage()
    }

    /// Applies incoming Raw rectangle updates directly into the shared pixel buffer.
    public func applyRawRect(_ rect: DecodedRect) {
        guard let pixels = rect.pixels, rect.width > 0, rect.height > 0 else { return }
        // Reject negative origins outright; memcpy cannot rewind the buffer safely.
        guard rect.originX >= 0, rect.originY >= 0, rect.originX < width, rect.originY < height else { return }
        // Clip overhang so row copies never spill into the next scanline.
        let visibleWidth = min(rect.width, width - rect.originX)
        let visibleHeight = min(rect.height, height - rect.originY)
        guard visibleWidth > 0, visibleHeight > 0 else { return }
        // Fail closed on truncated payloads or overflowing dimensions.
        let (rowBytes, rowOverflow) = rect.width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !rowOverflow else { return }
        let (expectedBytes, expOverflow) = rowBytes.multipliedReportingOverflow(by: rect.height)
        guard !expOverflow, pixels.count >= expectedBytes else { return }
        let rectRowBytes = rect.width * bytesPerPixel
        let copyBytes = visibleWidth * bytesPerPixel
        var didCopyRow = false

        pixelBuffer.withUnsafeMutableBytes { (bufferPtr: UnsafeMutableRawBufferPointer) in
            pixels.withUnsafeBytes { (rectPtr: UnsafeRawBufferPointer) in
                guard let base = bufferPtr.baseAddress, let srcBase = rectPtr.baseAddress else { return }
                for row in 0 ..< visibleHeight {
                    let destY = rect.originY + row
                    let destOffset = (destY * width + rect.originX) * bytesPerPixel
                    let srcOffset = row * rectRowBytes
                    if destOffset >= 0, destOffset + copyBytes <= bufferPtr.count,
                       srcOffset + copyBytes <= rectPtr.count
                    {
                        memcpy(base.advanced(by: destOffset), srcBase.advanced(by: srcOffset), copyBytes)
                        didCopyRow = true
                    }
                }
            }
        }
        // Flip readiness only when at least one row landed; keeps spinner honest.
        guard didCopyRow else { return }
        hasReceivedFirstFrame = true
        regenerateImage()
    }

    /// Applies hardware-accelerated CopyRect blits within the local framebuffer.
    public func applyCopyRect(dest: DecodedRect, srcX: Int, srcY: Int) {
        guard dest.width > 0, dest.height > 0 else { return }
        // Reject negative origins outright; memmove cannot rewind the buffer safely.
        guard dest.originX >= 0, dest.originY >= 0, srcX >= 0, srcY >= 0,
              dest.originX < width, dest.originY < height, srcX < width, srcY < height
        else { return }
        // Fail closed unless both rects fit entirely; avoids wrap-around blits.
        guard dest.width <= width - dest.originX,
              dest.height <= height - dest.originY,
              dest.width <= width - srcX,
              dest.height <= height - srcY
        else { return }
        let blitRowBytes = dest.width * bytesPerPixel
        var didMoveRow = false

        pixelBuffer.withUnsafeMutableBytes { (bufferPtr: UnsafeMutableRawBufferPointer) in
            guard let base = bufferPtr.baseAddress else { return }
            for row in 0 ..< dest.height {
                let destY = dest.originY + row
                let sourceY = srcY + row
                let destOffset = (destY * width + dest.originX) * bytesPerPixel
                let srcOffset = (sourceY * width + srcX) * bytesPerPixel
                if destOffset >= 0, destOffset + blitRowBytes <= bufferPtr.count,
                   srcOffset >= 0, srcOffset + blitRowBytes <= bufferPtr.count
                {
                    memmove(base.advanced(by: destOffset), base.advanced(by: srcOffset), blitRowBytes)
                    didMoveRow = true
                }
            }
        }
        // Flip readiness only when at least one row moved; keeps spinner honest.
        guard didMoveRow else { return }
        hasReceivedFirstFrame = true
        regenerateImage()
    }

    private func regenerateImage() {
        guard width > 0, height > 0 else { return }
        let rowBytes = width * bytesPerPixel
        guard let provider = CGDataProvider(data: pixelBuffer as CFData) else { return }

        image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
