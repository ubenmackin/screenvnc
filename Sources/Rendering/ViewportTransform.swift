// Rendering — Viewport geometry, focal-point zoom/pan math, and pointer translation.
import CoreGraphics
import SwiftUI

public struct ViewportTransform: Sendable, Equatable {
    public var framebufferWidth: Int
    public var framebufferHeight: Int
    public var viewSize: CGSize
    public var displayPreference: DisplayPreference
    public var zoomScale: CGFloat
    public var panOffset: CGSize
    public var panInsets: EdgeInsets

    public init(
        framebufferWidth: Int,
        framebufferHeight: Int,
        viewSize: CGSize,
        displayPreference: DisplayPreference = .fit,
        zoomScale: CGFloat = 1.0,
        panOffset: CGSize = .zero,
        panInsets: EdgeInsets = EdgeInsets()
    ) {
        self.framebufferWidth = framebufferWidth
        self.framebufferHeight = framebufferHeight
        self.viewSize = viewSize
        self.displayPreference = displayPreference
        self.zoomScale = zoomScale
        self.panOffset = panOffset
        self.panInsets = panInsets
    }

    public var isValid: Bool {
        framebufferWidth > 0 && framebufferHeight > 0 && viewSize.width > 0 && viewSize.height > 0
    }

    /// Unzoomed, centered content rect for the active display preference.
    public var baseContentRect: CGRect {
        guard isValid else { return .zero }
        let fbW = CGFloat(framebufferWidth)
        let fbH = CGFloat(framebufferHeight)
        let frameAspect = fbW / fbH
        let viewAspect = viewSize.width / viewSize.height

        let drawWidth: CGFloat
        let drawHeight: CGFloat
        switch displayPreference {
        case .fit:
            if frameAspect > viewAspect {
                drawWidth = viewSize.width
                drawHeight = viewSize.width / frameAspect
            } else {
                drawWidth = viewSize.height * frameAspect
                drawHeight = viewSize.height
            }
        case .fill:
            if frameAspect > viewAspect {
                drawWidth = viewSize.height * frameAspect
                drawHeight = viewSize.height
            } else {
                drawWidth = viewSize.width
                drawHeight = viewSize.width / frameAspect
            }
        case .actualSize:
            drawWidth = fbW
            drawHeight = fbH
        }

        let originX = (viewSize.width - drawWidth) / 2.0
        let originY = (viewSize.height - drawHeight) / 2.0
        return CGRect(x: originX, y: originY, width: drawWidth, height: drawHeight)
    }

    /// Live content rect after applying zoomScale around view center and panOffset.
    public var transformedContentRect: CGRect {
        guard isValid else { return .zero }
        let base = baseContentRect
        let scaledW = base.width * zoomScale
        let scaledH = base.height * zoomScale
        let originX = (viewSize.width - scaledW) / 2.0 + panOffset.width
        let originY = (viewSize.height - scaledH) / 2.0 + panOffset.height
        return CGRect(x: originX, y: originY, width: scaledW, height: scaledH)
    }

    public var minZoomScale: CGFloat {
        guard isValid else { return 1.0 }
        switch displayPreference {
        case .fit, .fill:
            return 1.0
        case .actualSize:
            let fitScale = min(
                viewSize.width / CGFloat(framebufferWidth),
                viewSize.height / CGFloat(framebufferHeight)
            )
            return max(0.15, min(1.0, fitScale))
        }
    }

    public var maxZoomScale: CGFloat {
        6.0
    }

    public var canPan: Bool {
        let rect = transformedContentRect
        return rect.width > viewSize.width + 0.5 || rect.height > viewSize.height + 0.5
    }

    /// Clamps panOffset so desktop edges stay reachable past safe areas and floating chrome.
    public func clampedPanOffset(_ proposed: CGSize) -> CGSize {
        guard isValid else { return .zero }
        let base = baseContentRect
        let scaledW = base.width * zoomScale
        let scaledH = base.height * zoomScale

        let clampedX: CGFloat
        if scaledW <= viewSize.width {
            clampedX = 0
        } else {
            let halfOverflowX = (scaledW - viewSize.width) / 2.0
            let minX = -halfOverflowX - panInsets.trailing
            let maxX = halfOverflowX + panInsets.leading
            clampedX = min(max(proposed.width, minX), maxX)
        }

        let clampedY: CGFloat
        if scaledH <= viewSize.height {
            clampedY = 0
        } else {
            let halfOverflowY = (scaledH - viewSize.height) / 2.0
            let minY = -halfOverflowY - panInsets.bottom
            let maxY = halfOverflowY + panInsets.top
            clampedY = min(max(proposed.height, minY), maxY)
        }

        return CGSize(width: clampedX, height: clampedY)
    }

    /// Computes updated zoomScale and panOffset keeping the pinch anchor stationary.
    public func focalZoomUpdate(
        scaleDelta: CGFloat,
        anchor: CGPoint,
        translationDelta: CGSize
    ) -> (zoomScale: CGFloat, panOffset: CGSize) {
        guard isValid else { return (zoomScale, panOffset) }
        let oldRect = transformedContentRect
        guard oldRect.width > 0, oldRect.height > 0 else { return (zoomScale, panOffset) }

        let normalizedX = (anchor.x - oldRect.minX) / oldRect.width
        let normalizedY = (anchor.y - oldRect.minY) / oldRect.height

        let newZoom = min(max(zoomScale * scaleDelta, minZoomScale), maxZoomScale)
        let base = baseContentRect
        let newW = base.width * newZoom
        let newH = base.height * newZoom

        let newOriginX = anchor.x + translationDelta.width - normalizedX * newW
        let newOriginY = anchor.y + translationDelta.height - normalizedY * newH

        let rawPan = CGSize(
            width: newOriginX - (viewSize.width - newW) / 2.0,
            height: newOriginY - (viewSize.height - newH) / 2.0
        )

        var updated = self
        updated.zoomScale = newZoom
        let clampedPan = updated.clampedPanOffset(rawPan)
        return (newZoom, clampedPan)
    }

    /// Computes an initial pan offset centering a remote point (or top-left menu bar) in the safe viewport.
    public func initialPanOffset(focusedOn remotePoint: CGPoint?) -> CGSize {
        guard isValid else { return .zero }
        let target = remotePoint ?? .zero
        let safeCenter = CGPoint(
            x: panInsets.leading + max(0, viewSize.width - panInsets.leading - panInsets.trailing) / 2.0,
            y: panInsets.top + max(0, viewSize.height - panInsets.top - panInsets.bottom) / 2.0
        )
        let rect = transformedContentRect
        let currentPoint = CGPoint(
            x: rect.minX + (target.x / CGFloat(framebufferWidth)) * rect.width,
            y: rect.minY + (target.y / CGFloat(framebufferHeight)) * rect.height
        )
        let delta = CGSize(
            width: panOffset.width + (safeCenter.x - currentPoint.x),
            height: panOffset.height + (safeCenter.y - currentPoint.y)
        )
        return clampedPanOffset(delta)
    }

    /// Maps a point in the viewport coordinate space to clamped remote framebuffer pixels.
    public func convertToRemote(viewPoint: CGPoint) -> (x: Int, y: Int) {
        let rect = transformedContentRect
        guard isValid, rect.width > 0, rect.height > 0 else { return (0, 0) }
        let relativeX = (viewPoint.x - rect.minX) / rect.width
        let relativeY = (viewPoint.y - rect.minY) / rect.height

        let remoteX = Int(max(0.0, min(relativeX * CGFloat(framebufferWidth), CGFloat(framebufferWidth - 1))))
        let remoteY = Int(max(0.0, min(relativeY * CGFloat(framebufferHeight), CGFloat(framebufferHeight - 1))))
        return (remoteX, remoteY)
    }

    /// Maps a remote framebuffer pixel coordinate into viewport coordinate space.
    public func convertToView(remotePoint: CGPoint) -> CGPoint {
        let rect = transformedContentRect
        guard isValid, rect.width > 0, rect.height > 0 else { return .zero }
        let viewX = rect.minX + (remotePoint.x / CGFloat(framebufferWidth)) * rect.width
        let viewY = rect.minY + (remotePoint.y / CGFloat(framebufferHeight)) * rect.height
        return CGPoint(x: viewX, y: viewY)
    }

    /// Converts incremental finger travel into remote pointer deltas with velocity acceleration.
    public func trackpadDelta(
        translationDelta: CGSize,
        velocity: CGPoint,
        sensitivity: Double
    ) -> CGSize {
        guard isValid else { return .zero }
        let rect = transformedContentRect
        let drawWidth = max(1.0, rect.width)
        let baseScale = max(0.35, CGFloat(framebufferWidth) / drawWidth)
        let speed = hypot(velocity.x, velocity.y)
        // Precision damping below ~120 pt/s; progressive acceleration up to 2.2x on fast swipes.
        let normalizedSpeed = min(max((speed - 80.0) / 850.0, 0.0), 1.0)
        let accel = 0.85 + normalizedSpeed * 1.35
        let factor = baseScale * CGFloat(sensitivity) * accel
        return CGSize(width: translationDelta.width * factor, height: translationDelta.height * factor)
    }

    /// Returns a pan delta that keeps a moving trackpad cursor inside zoomed viewport margins.
    public func edgeAutoPanDelta(cursorViewPoint: CGPoint, deltaTime: CGFloat) -> CGSize {
        guard isValid, canPan, deltaTime > 0 else { return .zero }
        let margin: CGFloat = 34.0
        let maxSpeed: CGFloat = 420.0
        let leftBound = panInsets.leading + margin
        let rightBound = viewSize.width - panInsets.trailing - margin
        let topBound = panInsets.top + margin
        let bottomBound = viewSize.height - panInsets.bottom - margin

        var shiftX: CGFloat = 0
        if cursorViewPoint.x < leftBound, leftBound > panInsets.leading {
            let ratio = min(1.0, (leftBound - cursorViewPoint.x) / margin)
            shiftX = ratio * maxSpeed * deltaTime
        } else if cursorViewPoint.x > rightBound, (viewSize.width - panInsets.trailing) > rightBound {
            let ratio = min(1.0, (cursorViewPoint.x - rightBound) / margin)
            shiftX = -ratio * maxSpeed * deltaTime
        }

        var shiftY: CGFloat = 0
        if cursorViewPoint.y < topBound, topBound > panInsets.top {
            let ratio = min(1.0, (topBound - cursorViewPoint.y) / margin)
            shiftY = ratio * maxSpeed * deltaTime
        } else if cursorViewPoint.y > bottomBound, (viewSize.height - panInsets.bottom) > bottomBound {
            let ratio = min(1.0, (cursorViewPoint.y - bottomBound) / margin)
            shiftY = -ratio * maxSpeed * deltaTime
        }

        return CGSize(width: shiftX, height: shiftY)
    }
}

/// Accumulates sub-threshold two-finger or wheel deltas into discrete RFB scroll steps.
public struct ScrollAccumulator: Sendable {
    public var remainderX: CGFloat = 0
    public var remainderY: CGFloat = 0
    public let stepThreshold: CGFloat

    public init(stepThreshold: CGFloat = 18.0) {
        self.stepThreshold = max(1.0, stepThreshold)
    }

    public mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    /// Returns signed wheel steps (positive = RFB scrollUp/scrollLeft) for an incremental drag delta.
    public mutating func consume(deltaX: CGFloat, deltaY: CGFloat, naturalScrolling: Bool) -> (stepsX: Int, stepsY: Int) {
        let sign: CGFloat = naturalScrolling ? -1.0 : 1.0
        remainderX += deltaX * sign
        remainderY += deltaY * sign

        let stepsX = Int(remainderX / stepThreshold)
        let stepsY = Int(remainderY / stepThreshold)
        remainderX -= CGFloat(stepsX) * stepThreshold
        remainderY -= CGFloat(stepsY) * stepThreshold
        return (stepsX, stepsY)
    }
}
