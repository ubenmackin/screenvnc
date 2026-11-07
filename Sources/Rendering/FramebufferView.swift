// Rendering — Zoomable, pannable SwiftUI framebuffer canvas with direct touch and trackpad translation.
import SwiftUI

public enum PointerMode: String, CaseIterable, Sendable {
    case directTouch
    case virtualTrackpad

    public var displayName: String {
        switch self {
        case .directTouch: "Direct Touch"
        case .virtualTrackpad: "Virtual Trackpad"
        }
    }
}

public struct FramebufferView: View {
    public var framebuffer: Framebuffer
    public var displayPreference: DisplayPreference
    public var pointerMode: PointerMode
    public var onPointerEvent: @MainActor (Int, Int, UInt8) -> Void
    public var isInputDisabled: Bool = false

    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var virtualCursor: CGPoint = .init(x: 960, y: 540)

    public init(
        framebuffer: Framebuffer,
        displayPreference: DisplayPreference = .fit,
        pointerMode: PointerMode = .directTouch,
        onPointerEvent: @escaping @MainActor (Int, Int, UInt8) -> Void,
        isInputDisabled: Bool = false
    ) {
        self.framebuffer = framebuffer
        self.displayPreference = displayPreference
        self.pointerMode = pointerMode
        self.onPointerEvent = onPointerEvent
        self.isInputDisabled = isInputDisabled
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                if let image = framebuffer.image {
                    let canvasImage = Image(decorative: image, scale: 1.0, orientation: .up)
                        .interpolation(.high)
                        .resizable()

                    Group {
                        switch displayPreference {
                        case .fit:
                            canvasImage.scaledToFit()
                        case .fill:
                            canvasImage.scaledToFill()
                        case .actualSize:
                            canvasImage.frame(width: CGFloat(framebuffer.width), height: CGFloat(framebuffer.height))
                        }
                    }
                    .scaleEffect(zoomScale)
                    .offset(panOffset)
                    .gesture(magnificationGesture)
                    .gesture(pointerGesture(in: geometry.size))
                } else {
                    ProgressView("Connecting to Framebuffer...")
                        .tint(.white)
                        .foregroundStyle(.white)
                }

                if pointerMode == .virtualTrackpad {
                    // Local virtual cursor indicator
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .position(x: virtualCursor.x, y: virtualCursor.y)
                        .shadow(radius: 2)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoomScale = max(0.5, min(lastZoomScale * value, 5.0))
            }
            .onEnded { _ in
                lastZoomScale = zoomScale
            }
    }

    private func pointerGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChange(value, in: viewSize)
            }
            .onEnded { value in
                handleDragEnd(value, in: viewSize)
            }
    }

    private func handleDragChange(_ value: DragGesture.Value, in viewSize: CGSize) {
        // View-only suppresses remote input, zoom stays local.
        guard !isInputDisabled else { return }
        if pointerMode == .directTouch {
            let remote = convertToRemote(point: value.location, in: viewSize)
            onPointerEvent(remote.x, remote.y, 1) // Button 1 pressed while dragging
        } else {
            // Trackpad relative motion
            let deltaX = value.translation.width - lastPanOffset.width
            let deltaY = value.translation.height - lastPanOffset.height
            virtualCursor.x = max(0, min(virtualCursor.x + deltaX, CGFloat(framebuffer.width)))
            virtualCursor.y = max(0, min(virtualCursor.y + deltaY, CGFloat(framebuffer.height)))
            lastPanOffset = value.translation
            onPointerEvent(Int(virtualCursor.x), Int(virtualCursor.y), 0)
        }
    }

    private func handleDragEnd(_ value: DragGesture.Value, in viewSize: CGSize) {
        // View-only suppresses remote input, zoom stays local.
        guard !isInputDisabled else { return }
        lastPanOffset = .zero
        if pointerMode == .directTouch {
            let remote = convertToRemote(point: value.location, in: viewSize)
            onPointerEvent(remote.x, remote.y, 0) // Button released
        } else {
            onPointerEvent(Int(virtualCursor.x), Int(virtualCursor.y), 0)
        }
    }

    /// Normalizes SwiftUI view coordinates to remote macOS framebuffer pixel space.
    public func convertToRemote(point: CGPoint, in viewSize: CGSize) -> (x: Int, y: Int) {
        guard framebuffer.width > 0, framebuffer.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return (0, 0)
        }
        let frameAspect = CGFloat(framebuffer.width) / CGFloat(framebuffer.height)
        let viewAspect = viewSize.width / viewSize.height

        var drawWidth: CGFloat = viewSize.width
        var drawHeight: CGFloat = viewSize.height

        if frameAspect > viewAspect {
            drawHeight = viewSize.width / frameAspect
        } else {
            drawWidth = viewSize.height * frameAspect
        }

        let originX = (viewSize.width - drawWidth) / 2.0
        let originY = (viewSize.height - drawHeight) / 2.0

        let relativeX = (point.x - originX) / drawWidth
        let relativeY = (point.y - originY) / drawHeight

        let remoteX = Int(max(0.0, min(relativeX * CGFloat(framebuffer.width), CGFloat(framebuffer.width - 1))))
        let remoteY = Int(max(0.0, min(relativeY * CGFloat(framebuffer.height), CGFloat(framebuffer.height - 1))))
        return (remoteX, remoteY)
    }
}
