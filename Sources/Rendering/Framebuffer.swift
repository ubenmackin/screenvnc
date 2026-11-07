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
    public var cursorPosition: CGPoint = .zero
    public var isCursorVisible: Bool = false

    private var pixelBuffer: Data
    private let bytesPerPixel = 4
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue

    public init(width: Int = 1920, height: Int = 1080) {
        let initialWidth = max(width, 1)
        let initialHeight = max(height, 1)
        self.width = initialWidth
        self.height = initialHeight
        pixelBuffer = Data(count: initialWidth * initialHeight * bytesPerPixel)
        regenerateImage()
    }

    public func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        self.width = width
        self.height = height
        pixelBuffer = Data(count: width * height * bytesPerPixel)
        regenerateImage()
    }

    /// Applies incoming Raw rectangle updates directly into the shared pixel buffer.
    public func applyRawRect(_ rect: DecodedRect) {
        guard let pixels = rect.pixels, rect.width > 0, rect.height > 0 else { return }
        let rectRowBytes = rect.width * bytesPerPixel

        pixelBuffer.withUnsafeMutableBytes { (bufferPtr: UnsafeMutableRawBufferPointer) in
            pixels.withUnsafeBytes { (rectPtr: UnsafeRawBufferPointer) in
                guard let base = bufferPtr.baseAddress, let srcBase = rectPtr.baseAddress else { return }
                for row in 0 ..< rect.height {
                    let destY = rect.originY + row
                    guard destY < height else { break }
                    let destOffset = (destY * width + rect.originX) * bytesPerPixel
                    let srcOffset = row * rectRowBytes
                    if destOffset + rectRowBytes <= bufferPtr.count, srcOffset + rectRowBytes <= rectPtr.count {
                        memcpy(base.advanced(by: destOffset), srcBase.advanced(by: srcOffset), rectRowBytes)
                    }
                }
            }
        }
        regenerateImage()
    }

    /// Applies hardware-accelerated CopyRect blits within the local framebuffer.
    public func applyCopyRect(dest: DecodedRect, srcX: Int, srcY: Int) {
        guard dest.width > 0, dest.height > 0 else { return }
        let blitRowBytes = dest.width * bytesPerPixel

        pixelBuffer.withUnsafeMutableBytes { (bufferPtr: UnsafeMutableRawBufferPointer) in
            guard let base = bufferPtr.baseAddress else { return }
            for row in 0 ..< dest.height {
                let destY = dest.originY + row
                let sourceY = srcY + row
                guard destY < height, sourceY < height else { continue }
                let destOffset = (destY * width + dest.originX) * bytesPerPixel
                let srcOffset = (sourceY * width + srcX) * bytesPerPixel
                if destOffset + blitRowBytes <= bufferPtr.count, srcOffset + blitRowBytes <= bufferPtr.count {
                    memmove(base.advanced(by: destOffset), base.advanced(by: srcOffset), blitRowBytes)
                }
            }
        }
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
