// Rendering — Zoomable, pannable SwiftUI framebuffer canvas with direct touch and trackpad translation.
import SwiftUI
import UIKit

public enum PointerMode: String, CaseIterable, Sendable, Codable {
    case directTouch
    case virtualTrackpad

    public var displayName: String {
        switch self {
        case .directTouch: "Direct Touch"
        case .virtualTrackpad: "Virtual Trackpad"
        }
    }
}

/// Transparent overlay capturing two-finger taps for remote right-click.
public struct TwoFingerTapView: UIViewRepresentable {
    public var onTwoFingerTap: (CGPoint) -> Void

    public init(onTwoFingerTap: @escaping (CGPoint) -> Void) {
        self.onTwoFingerTap = onTwoFingerTap
    }

    public func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        recognizer.numberOfTouchesRequired = 2
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    public func updateUIView(_: UIView, context _: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(onTwoFingerTap: onTwoFingerTap)
    }

    public final class Coordinator: NSObject {
        let onTwoFingerTap: (CGPoint) -> Void
        init(onTwoFingerTap: @escaping (CGPoint) -> Void) {
            self.onTwoFingerTap = onTwoFingerTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: gesture.view)
            onTwoFingerTap(point)
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
                    // Local virtual cursor indicator mapped to view space
                    let viewPos = convertToView(remotePoint: virtualCursor, in: geometry.size)
                    Circle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        .position(x: viewPos.x, y: viewPos.y)
                        .shadow(radius: 2)
                        .allowsHitTesting(false)
                }

                // Two-finger tap detector overlay for right click
                TwoFingerTapView { point in
                    handleTwoFingerTap(at: point, in: geometry.size)
                }
                .allowsHitTesting(true)
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
        guard !isInputDisabled else { return }
        if pointerMode == .directTouch {
            let remote = convertToRemote(point: value.location, in: viewSize)
            onPointerEvent(remote.x, remote.y, 0)
        } else {
            let geom = contentGeometry(in: viewSize)
            let drawWidth = max(1.0, geom.size.width)
            let scaleFactor = max(1.0, CGFloat(framebuffer.width) / drawWidth)

            let deltaX = (value.translation.width - lastPanOffset.width) * scaleFactor
            let deltaY = (value.translation.height - lastPanOffset.height) * scaleFactor

            virtualCursor.x = max(0, min(virtualCursor.x + deltaX, CGFloat(framebuffer.width - 1)))
            virtualCursor.y = max(0, min(virtualCursor.y + deltaY, CGFloat(framebuffer.height - 1)))
            lastPanOffset = value.translation
            onPointerEvent(Int(virtualCursor.x), Int(virtualCursor.y), 0)
        }
    }

    private func handleDragEnd(_ value: DragGesture.Value, in viewSize: CGSize) {
        guard !isInputDisabled else { return }
        lastPanOffset = .zero
        let distance = hypot(value.translation.width, value.translation.height)

        if pointerMode == .directTouch {
            let tapPoint = value.startLocation
            let remote = convertToRemote(point: tapPoint, in: viewSize)
            if distance < 8 {
                // Direct touch tap: position cursor first, wait, down, wait, up
                onPointerEvent(remote.x, remote.y, 0)
                Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: 20_000_000)
                    } catch {}
                    onPointerEvent(remote.x, remote.y, 1)
                    do {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    } catch {}
                    onPointerEvent(remote.x, remote.y, 0)
                }
            } else {
                onPointerEvent(remote.x, remote.y, 0)
            }
        } else {
            let posX = Int(virtualCursor.x)
            let posY = Int(virtualCursor.y)
            if distance < 6 {
                // Tap on virtual trackpad -> trigger left click
                onPointerEvent(posX, posY, 0)
                Task { @MainActor in
                    do {
                        try await Task.sleep(nanoseconds: 20_000_000)
                    } catch {}
                    onPointerEvent(posX, posY, 1)
                    do {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    } catch {}
                    onPointerEvent(posX, posY, 0)
                }
            } else {
                onPointerEvent(posX, posY, 0)
            }
        }
    }

    private func handleTwoFingerTap(at point: CGPoint, in viewSize: CGSize) {
        guard !isInputDisabled else { return }
        let (rx, ry): (Int, Int)
        if pointerMode == .directTouch {
            let remote = convertToRemote(point: point, in: viewSize)
            rx = remote.x
            ry = remote.y
        } else {
            rx = Int(virtualCursor.x)
            ry = Int(virtualCursor.y)
        }
        // Send right click: move -> down with mask 4 (RFB button 3) -> wait -> up
        onPointerEvent(rx, ry, 0)
        Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {}
            onPointerEvent(rx, ry, 4)
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {}
            onPointerEvent(rx, ry, 0)
        }
    }

    /// Computes the exact frame geometry and draw scale for current display preference.
    public func contentGeometry(in viewSize: CGSize) -> (origin: CGPoint, size: CGSize) {
        guard framebuffer.width > 0, framebuffer.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return (.zero, .zero)
        }
        let fbW = CGFloat(framebuffer.width)
        let fbH = CGFloat(framebuffer.height)
        let frameAspect = fbW / fbH
        let viewAspect = viewSize.width / viewSize.height

        var drawWidth: CGFloat
        var drawHeight: CGFloat

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
        return (CGPoint(x: originX, y: originY), CGSize(width: drawWidth, height: drawHeight))
    }

    /// Converts remote macOS framebuffer pixel coordinates to SwiftUI view space.
    public func convertToView(remotePoint: CGPoint, in viewSize: CGSize) -> CGPoint {
        let geom = contentGeometry(in: viewSize)
        guard framebuffer.width > 0, framebuffer.height > 0, geom.size.width > 0, geom.size.height > 0 else {
            return .zero
        }
        let viewX = geom.origin.x + (remotePoint.x / CGFloat(framebuffer.width)) * geom.size.width
        let viewY = geom.origin.y + (remotePoint.y / CGFloat(framebuffer.height)) * geom.size.height
        return CGPoint(x: viewX, y: viewY)
    }

    /// Normalizes SwiftUI view coordinates to remote macOS framebuffer pixel space.
    public func convertToRemote(point: CGPoint, in viewSize: CGSize) -> (x: Int, y: Int) {
        let geom = contentGeometry(in: viewSize)
        guard framebuffer.width > 0, framebuffer.height > 0, geom.size.width > 0, geom.size.height > 0 else {
            return (0, 0)
        }
        let relativeX = (point.x - geom.origin.x) / geom.size.width
        let relativeY = (point.y - geom.origin.y) / geom.size.height

        let remoteX = Int(max(0.0, min(relativeX * CGFloat(framebuffer.width), CGFloat(framebuffer.width - 1))))
        let remoteY = Int(max(0.0, min(relativeY * CGFloat(framebuffer.height), CGFloat(framebuffer.height - 1))))
        return (remoteX, remoteY)
    }
}
