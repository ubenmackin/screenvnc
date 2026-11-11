// Rendering — Zoomable, pannable SwiftUI framebuffer canvas with real-time cursor and gesture overlay.
import Foundation
import os
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

/// Isolated framebuffer image layer so cursor movement never re-evaluates CGImage modifiers.
private struct FramebufferCanvasLayer: View {
    let image: CGImage
    let contentRect: CGRect

    var body: some View {
        Image(decorative: image, scale: 1.0, orientation: .up)
            .interpolation(.high)
            .resizable()
            .frame(width: max(contentRect.width, 1), height: max(contentRect.height, 1))
            .position(x: contentRect.midX, y: contentRect.midY)
    }
}

/// Renders either the remote macOS cursor image (hotspot-aligned) or a crisp virtual dot fallback.
private struct CursorIndicatorLayer: View {
    let cursorImage: CGImage?
    let hotspot: CGPoint
    let viewPosition: CGPoint
    let canvasScale: CGFloat
    let isLeftButtonHeld: Bool

    var body: some View {
        ZStack {
            if isLeftButtonHeld {
                Circle()
                    .stroke(Color.accentColor.opacity(0.85), lineWidth: 2.5)
                    .frame(width: 34, height: 34)
                    .position(x: viewPosition.x, y: viewPosition.y)
            }

            if let cursorImage {
                let visualScale = max(0.85, min(canvasScale, 2.0))
                let drawW = CGFloat(cursorImage.width) * visualScale
                let drawH = CGFloat(cursorImage.height) * visualScale
                let centerX = viewPosition.x + (CGFloat(cursorImage.width) * 0.5 - hotspot.x) * visualScale
                let centerY = viewPosition.y + (CGFloat(cursorImage.height) * 0.5 - hotspot.y) * visualScale

                Image(decorative: cursorImage, scale: 1.0, orientation: .up)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: max(drawW, 1), height: max(drawH, 1))
                    .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1)
                    .position(x: centerX, y: centerY)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.black.opacity(0.85), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .position(x: viewPosition.x, y: viewPosition.y)
            }
        }
        .allowsHitTesting(false)
    }
}

public struct FramebufferView: View {
    public var framebuffer: Framebuffer
    public var displayPreference: DisplayPreference
    public var pointerMode: PointerMode
    public var sharedCursor: Binding<CGPoint>?
    public var panInsets: EdgeInsets
    public var resetTrigger: Int
    public var onPointerEvent: @MainActor (Int, Int, UInt8) -> Void
    public var onInputCommand: (@MainActor (VNCInputCommand) -> Void)?
    public var onFlushMoves: (@MainActor () -> Void)?
    public var isInputDisabled: Bool

    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var internalCursor: CGPoint
    @State private var isLeftButtonHeld = false
    @State private var directTouchDragPoint: CGPoint?
    @State private var isHoverPointerActive = false
    @State private var scrollAccumulator = ScrollAccumulator()
    @State private var scrollAnchor: CGPoint?
    @State private var scrollCoastTask: Task<Void, Never>?
    @State private var inertiaTask: Task<Void, Never>?
    @State private var didApplyInitialPan = false

    private var settings = SettingsStore.shared
    private let logger = Logger(subsystem: "com.volcrypt.ScreenVNC", category: "FramebufferView")

    public init(
        framebuffer: Framebuffer,
        displayPreference: DisplayPreference = .fit,
        pointerMode: PointerMode = .directTouch,
        sharedCursor: Binding<CGPoint>? = nil,
        panInsets: EdgeInsets = EdgeInsets(),
        resetTrigger: Int = 0,
        onPointerEvent: @escaping @MainActor (Int, Int, UInt8) -> Void,
        onInputCommand: (@MainActor (VNCInputCommand) -> Void)? = nil,
        onFlushMoves: (@MainActor () -> Void)? = nil,
        isInputDisabled: Bool = false
    ) {
        self.framebuffer = framebuffer
        self.displayPreference = displayPreference
        self.pointerMode = pointerMode
        self.sharedCursor = sharedCursor
        self.panInsets = panInsets
        self.resetTrigger = resetTrigger
        self.onPointerEvent = onPointerEvent
        self.onInputCommand = onInputCommand
        self.onFlushMoves = onFlushMoves
        self.isInputDisabled = isInputDisabled
        let initial = sharedCursor?.wrappedValue ?? CGPoint(
            x: CGFloat(max(framebuffer.width, 1)) / 2.0,
            y: CGFloat(max(framebuffer.height, 1)) / 2.0
        )
        _internalCursor = State(initialValue: initial)
    }

    private var activeCursor: CGPoint {
        sharedCursor?.wrappedValue ?? internalCursor
    }

    private func setActiveCursor(_ point: CGPoint) {
        let clamped = clampRemotePoint(point)
        internalCursor = clamped
        sharedCursor?.wrappedValue = clamped
        framebuffer.cursorPosition = clamped
    }

    public var body: some View {
        GeometryReader { geometry in
            let transform = makeTransform(in: geometry.size)
            let contentRect = transform.transformedContentRect
            let cursorViewPos = transform.convertToView(remotePoint: activeCursor)
            let canvasScale = contentRect.width / CGFloat(max(framebuffer.width, 1))

            ZStack {
                Color.black

                if framebuffer.hasReceivedFirstFrame, let image = framebuffer.image {
                    FramebufferCanvasLayer(image: image, contentRect: contentRect)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(.white)
                        Text("Connecting to Mac Desktop...")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }

                if pointerMode == .virtualTrackpad || isHoverPointerActive {
                    CursorIndicatorLayer(
                        cursorImage: framebuffer.cursorImage,
                        hotspot: framebuffer.cursorHotspot,
                        viewPosition: cursorViewPos,
                        canvasScale: canvasScale,
                        isLeftButtonHeld: isLeftButtonHeld
                    )
                } else if let dragPoint = directTouchDragPoint {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.9), lineWidth: 2.5)
                        .frame(width: 38, height: 38)
                        .position(x: dragPoint.x, y: dragPoint.y)
                        .allowsHitTesting(false)
                }

                CanvasGestureOverlay(
                    configuration: CanvasGestureConfiguration(
                        pointerMode: pointerMode,
                        canPan: transform.canPan,
                        isInputDisabled: isInputDisabled,
                        tapToClickInTrackpad: settings.tapToClickInTrackpad,
                        twoFingerTrackpadAction: settings.twoFingerTrackpadAction
                    ),
                    callbacks: makeCallbacks(in: geometry.size)
                )

                if shouldShowZoomBadge(in: geometry.size) {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                resetViewport(in: geometry.size, animated: true)
                            } label: {
                                HStack(spacing: 6) {
                                    Text("\(effectiveZoomLabel(in: geometry.size))")
                                        .font(.caption.monospacedDigit().bold())
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.caption.bold())
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                                .shadow(radius: 4)
                            }
                            .padding(.top, max(panInsets.top, 12))
                            .padding(.trailing, max(panInsets.trailing, 12))
                        }
                        Spacer()
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .onAppear {
                applyInitialPanIfNeeded(in: geometry.size)
            }
            .onChange(of: framebuffer.hasReceivedFirstFrame) { _, received in
                if received {
                    applyInitialPanIfNeeded(in: geometry.size)
                }
            }
            .onChange(of: framebuffer.width) { _, _ in
                setActiveCursor(activeCursor)
                panOffset = makeTransform(in: geometry.size).clampedPanOffset(panOffset)
            }
            .onChange(of: framebuffer.height) { _, _ in
                setActiveCursor(activeCursor)
                panOffset = makeTransform(in: geometry.size).clampedPanOffset(panOffset)
            }
            .onChange(of: displayPreference) { _, _ in
                resetViewport(in: geometry.size, animated: true)
            }
            .onChange(of: resetTrigger) { _, _ in
                resetViewport(in: geometry.size, animated: true)
            }
            .onChange(of: geometry.size) { _, newSize in
                panOffset = makeTransform(in: newSize).clampedPanOffset(panOffset)
            }
            .onDisappear {
                inertiaTask?.cancel()
                inertiaTask = nil
                scrollCoastTask?.cancel()
                scrollCoastTask = nil
            }
        }
    }

    // MARK: - Gesture Callbacks

    private func makeCallbacks(in viewSize: CGSize) -> CanvasGestureCallbacks {
        CanvasGestureCallbacks(
            onPrimaryTap: { viewPoint, _ in
                handlePrimaryTap(at: viewPoint, in: viewSize)
            },
            onRightClick: { viewPoint in
                handleSecondaryTap(at: viewPoint, in: viewSize, button: .right)
            },
            onMiddleClick: { viewPoint in
                handleSecondaryTap(at: viewPoint, in: viewSize, button: .middle)
            },
            onTrackpadMove: { translationDelta, velocity in
                handleTrackpadMove(translationDelta: translationDelta, velocity: velocity, in: viewSize)
            },
            onTrackpadEnd: {
                onFlushMoves?()
            },
            onDragStart: { viewPoint in
                handleDragStart(at: viewPoint, in: viewSize)
            },
            onDragMove: { viewPoint, delta in
                handleDragMove(to: viewPoint, delta: delta, in: viewSize)
            },
            onDragEnd: { viewPoint in
                handleDragEnd(at: viewPoint, in: viewSize)
            },
            onViewportPanStart: {
                scrollAccumulator.reset()
                scrollAnchor = nil
                scrollCoastTask?.cancel()
                scrollCoastTask = nil
                inertiaTask?.cancel()
                inertiaTask = nil
            },
            onViewportPan: { delta in
                applyPan(delta: delta, in: viewSize)
            },
            onViewportPanEnd: { velocity in
                startPanInertia(velocity: velocity, in: viewSize)
            },
            onPinchZoom: { scaleDelta, anchor, translationDelta in
                applyFocalPinch(
                    scaleDelta: scaleDelta,
                    anchor: anchor,
                    translationDelta: translationDelta,
                    in: viewSize
                )
            },
            onTwoFingerScroll: { delta, viewPoint, velocity in
                handleScroll(delta: delta, at: viewPoint, velocity: velocity, in: viewSize)
            },
            onTwoFingerScrollEnd: { velocity in
                handleScrollEnd(velocity: velocity, in: viewSize)
            },
            onScrollStart: {
                handleScrollStart()
            },
            onHoverMove: { viewPoint in
                handleHoverMove(to: viewPoint, in: viewSize)
            }
        )
    }

    private func handlePrimaryTap(at viewPoint: CGPoint, in viewSize: CGSize) {
        guard !isInputDisabled else { return }
        isHoverPointerActive = false
        let target = resolveTargetRemotePoint(viewPoint: viewPoint, in: viewSize)
        setActiveCursor(CGPoint(x: target.x, y: target.y))
        dispatchClick(posX: target.x, posY: target.y, buttonMask: RFBConstants.PointerButton.left.rawValue)
    }

    private func handleSecondaryTap(at viewPoint: CGPoint, in viewSize: CGSize, button: RFBConstants.PointerButton) {
        guard !isInputDisabled else { return }
        let target = resolveTargetRemotePoint(viewPoint: viewPoint, in: viewSize)
        setActiveCursor(CGPoint(x: target.x, y: target.y))
        dispatchClick(posX: target.x, posY: target.y, buttonMask: button.rawValue)
    }

    private func handleTrackpadMove(translationDelta: CGSize, velocity: CGPoint, in viewSize: CGSize) {
        guard !isInputDisabled else { return }
        isHoverPointerActive = false
        let transform = makeTransform(in: viewSize)
        let remoteDelta = transform.trackpadDelta(
            translationDelta: translationDelta,
            velocity: velocity,
            sensitivity: settings.trackpadSensitivity
        )
        let next = clampRemotePoint(CGPoint(
            x: activeCursor.x + remoteDelta.width,
            y: activeCursor.y + remoteDelta.height
        ))
        setActiveCursor(next)

        // Smoothly pan zoomed viewport when cursor approaches screen edges.
        let viewCursor = transform.convertToView(remotePoint: next)
        let autoPan = transform.edgeAutoPanDelta(cursorViewPoint: viewCursor, deltaTime: 1.0 / 60.0)
        if autoPan != .zero {
            let proposed = CGSize(width: panOffset.width + autoPan.width, height: panOffset.height + autoPan.height)
            panOffset = transform.clampedPanOffset(proposed)
        }

        let buttonMask: UInt8 = isLeftButtonHeld ? RFBConstants.PointerButton.left.rawValue : 0
        dispatchMove(posX: Int(next.x), posY: Int(next.y), buttonMask: buttonMask)
    }

    private func handleDragStart(at viewPoint: CGPoint, in viewSize: CGSize) {
        guard !isInputDisabled else { return }
        isHoverPointerActive = false
        isLeftButtonHeld = true
        let target = resolveTargetRemotePoint(viewPoint: viewPoint, in: viewSize)
        setActiveCursor(CGPoint(x: target.x, y: target.y))
        if pointerMode == .directTouch {
            directTouchDragPoint = viewPoint
        }
        let leftMask = RFBConstants.PointerButton.left.rawValue
        if let onInputCommand {
            onInputCommand(.pointerDown(posX: target.x, posY: target.y, buttonMask: leftMask))
        } else {
            onPointerEvent(target.x, target.y, 0)
            onPointerEvent(target.x, target.y, leftMask)
        }
    }

    private func handleDragMove(to viewPoint: CGPoint, delta: CGSize, in viewSize: CGSize) {
        guard !isInputDisabled else { return }
        let transform = makeTransform(in: viewSize)
        let nextPoint: CGPoint
        if pointerMode == .directTouch {
            let remote = transform.convertToRemote(viewPoint: viewPoint)
            nextPoint = CGPoint(x: remote.x, y: remote.y)
            directTouchDragPoint = viewPoint
        } else {
            let remoteDelta = transform.trackpadDelta(
                translationDelta: delta,
                velocity: .zero,
                sensitivity: settings.trackpadSensitivity
            )
            nextPoint = clampRemotePoint(CGPoint(
                x: activeCursor.x + remoteDelta.width,
                y: activeCursor.y + remoteDelta.height
            ))
            let viewCursor = transform.convertToView(remotePoint: nextPoint)
            let autoPan = transform.edgeAutoPanDelta(cursorViewPoint: viewCursor, deltaTime: 1.0 / 60.0)
            if autoPan != .zero {
                let proposed = CGSize(width: panOffset.width + autoPan.width, height: panOffset.height + autoPan.height)
                panOffset = transform.clampedPanOffset(proposed)
            }
        }
        setActiveCursor(nextPoint)
        dispatchMove(
            posX: Int(nextPoint.x),
            posY: Int(nextPoint.y),
            buttonMask: RFBConstants.PointerButton.left.rawValue
        )
    }

    private func handleDragEnd(at viewPoint: CGPoint, in viewSize: CGSize) {
        isLeftButtonHeld = false
        directTouchDragPoint = nil
        // Release dispatches unconditionally: the view-only gates in enqueueInput and
        // sendPointerEvent block presses, and skipping here would latch the remote
        // left button when input is disabled mid-drag.
        let target: (x: Int, y: Int)
        if pointerMode == .directTouch {
            target = makeTransform(in: viewSize).convertToRemote(viewPoint: viewPoint)
            setActiveCursor(CGPoint(x: target.x, y: target.y))
        } else {
            target = (Int(activeCursor.x), Int(activeCursor.y))
        }
        if let onInputCommand {
            onInputCommand(.pointerUp(posX: target.x, posY: target.y))
        } else {
            onPointerEvent(target.x, target.y, 0)
        }
    }

    private func handleScrollStart() {
        // Indirect pulses get a fresh anchor so prior touch scrolls never leak targets.
        scrollAccumulator.reset()
        scrollAnchor = nil
        scrollCoastTask?.cancel()
        scrollCoastTask = nil
    }

    private func emitScrollSteps(stepsX: Int, stepsY: Int, at anchor: CGPoint, in viewSize: CGSize) {
        // Single emission path keeps live and coasted pulses on the same target.
        let target = resolveTargetRemotePoint(viewPoint: anchor, in: viewSize)
        let activeButtons: UInt8 = isLeftButtonHeld ? RFBConstants.PointerButton.left.rawValue : 0
        if let onInputCommand {
            onInputCommand(.scroll(
                posX: target.x,
                posY: target.y,
                stepsX: stepsX,
                stepsY: stepsY,
                activeButtons: activeButtons
            ))
        } else {
            emitFallbackScroll(posX: target.x, posY: target.y, stepsX: stepsX, stepsY: stepsY)
        }
    }

    private func handleScroll(delta: CGSize, at viewPoint: CGPoint, velocity: CGPoint, in viewSize: CGSize) {
        guard !isInputDisabled else { return }
        if scrollAnchor == nil {
            scrollAnchor = viewPoint
        }
        guard let anchor = scrollAnchor else { return }
        let steps = scrollAccumulator.consume(
            deltaX: delta.width,
            deltaY: delta.height,
            velocity: velocity,
            naturalScrolling: settings.naturalScrolling
        )
        guard steps.stepsX != 0 || steps.stepsY != 0 else { return }
        emitScrollSteps(stepsX: steps.stepsX, stepsY: steps.stepsY, at: anchor, in: viewSize)
    }

    private func handleScrollEnd(velocity: CGPoint, in viewSize: CGSize) {
        guard !isInputDisabled, ScrollAccumulator.shouldCoast(velocity: velocity), let anchor = scrollAnchor else { return }
        scrollCoastTask?.cancel()
        // Coast freezes lift target and buttons; natural scrolling rereads live
        // per tick. Task holds only snapshots plus a local accumulator copy
        // so a retained View never mutates @State or retargets on rotation.
        let liftTarget = resolveTargetRemotePoint(viewPoint: anchor, in: viewSize)
        let liftButtons: UInt8 = isLeftButtonHeld ? RFBConstants.PointerButton.left.rawValue : 0
        let liftVelocity = velocity
        let seedAccumulator = scrollAccumulator
        let liftInputCommand = onInputCommand
        let liftPointerEvent = onPointerEvent
        scrollCoastTask = Task { @MainActor in
            var accumulator = seedAccumulator
            var emptyTicks = 0
            for tickIndex in 0 ..< 8 {
                if Task.isCancelled {
                    break
                }
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    break
                }
                if Task.isCancelled {
                    break
                }
                let decay = pow(0.85, Double(tickIndex))
                let decayed = CGSize(
                    width: liftVelocity.x * 0.016 * CGFloat(decay),
                    height: liftVelocity.y * 0.016 * CGFloat(decay)
                )
                let steps = accumulator.consume(
                    deltaX: decayed.width,
                    deltaY: decayed.height,
                    naturalScrolling: SettingsStore.shared.naturalScrolling
                )
                if steps.stepsX == 0, steps.stepsY == 0 {
                    emptyTicks += 1
                    if emptyTicks >= 2 {
                        break
                    }
                    continue
                }
                emptyTicks = 0
                if let liftInputCommand {
                    liftInputCommand(.scroll(
                        posX: liftTarget.x,
                        posY: liftTarget.y,
                        stepsX: steps.stepsX,
                        stepsY: steps.stepsY,
                        activeButtons: liftButtons
                    ))
                } else {
                    Self.emitFallbackScrollSteps(
                        posX: liftTarget.x,
                        posY: liftTarget.y,
                        stepsX: steps.stepsX,
                        stepsY: steps.stepsY,
                        onPointerEvent: liftPointerEvent
                    )
                }
            }
        }
    }

    private func handleHoverMove(to viewPoint: CGPoint, in viewSize: CGSize) {
        guard !isInputDisabled else { return }
        isHoverPointerActive = true
        let remote = makeTransform(in: viewSize).convertToRemote(viewPoint: viewPoint)
        setActiveCursor(CGPoint(x: remote.x, y: remote.y))
        let buttonMask: UInt8 = isLeftButtonHeld ? RFBConstants.PointerButton.left.rawValue : 0
        dispatchMove(posX: remote.x, posY: remote.y, buttonMask: buttonMask)
    }

    // MARK: - Pan & Zoom Helpers

    private func applyPan(delta: CGSize, in viewSize: CGSize) {
        let sign: CGFloat = settings.invertPanDirection ? -1.0 : 1.0
        let proposed = CGSize(
            width: panOffset.width + delta.width * sign,
            height: panOffset.height + delta.height * sign
        )
        panOffset = makeTransform(in: viewSize).clampedPanOffset(proposed)
    }

    private func startPanInertia(velocity: CGPoint, in viewSize: CGSize) {
        let transform = makeTransform(in: viewSize)
        guard transform.canPan else { return }
        let sign: CGFloat = settings.invertPanDirection ? -1.0 : 1.0
        var vx = velocity.x * sign
        var vy = velocity.y * sign
        guard hypot(vx, vy) > 90 else { return }

        inertiaTask?.cancel()
        inertiaTask = Task {
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled, hypot(vx, vy) > 14 {
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch is CancellationError {
                    break
                } catch {
                    logger.debug("Pan inertia stopped: \(error.localizedDescription)")
                    break
                }
                let now = clock.now
                let elapsed = last.duration(to: now)
                let dt = CGFloat(elapsed.components.seconds) + CGFloat(elapsed.components.attoseconds) / 1e18
                last = now
                let clampedDt = min(max(dt, 0.004), 0.05)

                let currentTransform = makeTransform(in: viewSize)
                let nextOffset = CGSize(
                    width: panOffset.width + vx * clampedDt,
                    height: panOffset.height + vy * clampedDt
                )
                let clamped = currentTransform.clampedPanOffset(nextOffset)
                if clamped.width == panOffset.width {
                    vx = 0
                }
                if clamped.height == panOffset.height {
                    vy = 0
                }
                panOffset = clamped

                let damping = pow(0.92, clampedDt * 60.0)
                vx *= damping
                vy *= damping
            }
        }
    }

    private func applyFocalPinch(
        scaleDelta: CGFloat,
        anchor: CGPoint,
        translationDelta: CGSize,
        in viewSize: CGSize
    ) {
        let transform = makeTransform(in: viewSize)
        let result = transform.focalZoomUpdate(
            scaleDelta: scaleDelta,
            anchor: anchor,
            translationDelta: translationDelta
        )
        zoomScale = result.zoomScale
        panOffset = result.panOffset
    }

    private func resetViewport(in viewSize: CGSize, animated: Bool) {
        inertiaTask?.cancel()
        inertiaTask = nil
        let targetTransform = ViewportTransform(
            framebufferWidth: framebuffer.width,
            framebufferHeight: framebuffer.height,
            viewSize: viewSize,
            displayPreference: displayPreference,
            zoomScale: 1.0,
            panOffset: .zero,
            panInsets: panInsets
        )
        let initialPan: CGSize = if displayPreference == .fit {
            .zero
        } else {
            targetTransform.initialPanOffset(focusedOn: didApplyInitialPan ? activeCursor : nil)
        }
        if animated {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                zoomScale = 1.0
                panOffset = initialPan
            }
        } else {
            zoomScale = 1.0
            panOffset = initialPan
        }
    }

    private func applyInitialPanIfNeeded(in viewSize: CGSize) {
        guard !didApplyInitialPan, viewSize.width > 0, viewSize.height > 0 else { return }
        if framebuffer.hasReceivedFirstFrame {
            didApplyInitialPan = true
        }
        if displayPreference != .fit {
            let transform = ViewportTransform(
                framebufferWidth: framebuffer.width,
                framebufferHeight: framebuffer.height,
                viewSize: viewSize,
                displayPreference: displayPreference,
                zoomScale: 1.0,
                panOffset: .zero,
                panInsets: panInsets
            )
            panOffset = transform.initialPanOffset(focusedOn: nil)
        }
    }

    private func shouldShowZoomBadge(in viewSize: CGSize) -> Bool {
        guard framebuffer.hasReceivedFirstFrame else { return false }
        if abs(zoomScale - 1.0) > 0.03 {
            return true
        }
        if displayPreference == .fit, hypot(panOffset.width, panOffset.height) > 2 {
            return true
        }
        return displayPreference != .fit && makeTransform(in: viewSize).canPan && abs(zoomScale - 1.0) > 0.03
    }

    private func effectiveZoomLabel(in viewSize: CGSize) -> String {
        let base = makeTransform(in: viewSize).transformedContentRect.width
        let fitWidth = ViewportTransform(
            framebufferWidth: framebuffer.width,
            framebufferHeight: framebuffer.height,
            viewSize: viewSize,
            displayPreference: .fit
        ).baseContentRect.width
        let relative = fitWidth > 0 ? base / fitWidth : zoomScale
        return String(format: "%.1f×", relative)
    }

    // MARK: - Dispatch Helpers

    private func resolveTargetRemotePoint(viewPoint: CGPoint, in viewSize: CGSize) -> (x: Int, y: Int) {
        if pointerMode == .directTouch || isHoverPointerActive {
            return makeTransform(in: viewSize).convertToRemote(viewPoint: viewPoint)
        }
        return (Int(activeCursor.x), Int(activeCursor.y))
    }

    private func dispatchMove(posX: Int, posY: Int, buttonMask: UInt8) {
        if let onInputCommand {
            onInputCommand(.pointerMove(posX: posX, posY: posY, buttonMask: buttonMask))
        } else {
            onPointerEvent(posX, posY, buttonMask)
        }
    }

    private func dispatchClick(posX: Int, posY: Int, buttonMask: UInt8) {
        if let onInputCommand {
            onInputCommand(.click(posX: posX, posY: posY, buttonMask: buttonMask))
        } else {
            onPointerEvent(posX, posY, 0)
            onPointerEvent(posX, posY, buttonMask)
            onPointerEvent(posX, posY, 0)
        }
    }

    private func emitFallbackScroll(posX: Int, posY: Int, stepsX: Int, stepsY: Int) {
        Self.emitFallbackScrollSteps(
            posX: posX,
            posY: posY,
            stepsX: stepsX,
            stepsY: stepsY,
            onPointerEvent: onPointerEvent
        )
    }

    @MainActor
    private static func emitFallbackScrollSteps(
        posX: Int,
        posY: Int,
        stepsX: Int,
        stepsY: Int,
        onPointerEvent: @MainActor (Int, Int, UInt8) -> Void
    ) {
        // Shared fallback path so live and coasted pulses emit identical clicks.
        let vButton = stepsY > 0 ? RFBConstants.PointerButton.scrollUp.rawValue : RFBConstants.PointerButton.scrollDown.rawValue
        for _ in 0 ..< min(abs(stepsY), 12) {
            onPointerEvent(posX, posY, vButton)
            onPointerEvent(posX, posY, 0)
        }
        let hButton = stepsX > 0 ? RFBConstants.PointerButton.scrollLeft.rawValue : RFBConstants.PointerButton.scrollRight.rawValue
        for _ in 0 ..< min(abs(stepsX), 12) {
            onPointerEvent(posX, posY, hButton)
            onPointerEvent(posX, posY, 0)
        }
    }

    private func clampRemotePoint(_ point: CGPoint) -> CGPoint {
        let maxX = CGFloat(max(framebuffer.width - 1, 0))
        let maxY = CGFloat(max(framebuffer.height - 1, 0))
        return CGPoint(
            x: max(0, min(point.x, maxX)),
            y: max(0, min(point.y, maxY))
        )
    }

    private func makeTransform(in viewSize: CGSize) -> ViewportTransform {
        ViewportTransform(
            framebufferWidth: framebuffer.width,
            framebufferHeight: framebuffer.height,
            viewSize: viewSize,
            displayPreference: displayPreference,
            zoomScale: zoomScale,
            panOffset: panOffset,
            panInsets: panInsets
        )
    }

    // MARK: - Public Coordinate API (Tested Directly)

    /// Computes the exact frame geometry and draw scale for current display preference.
    public func contentGeometry(in viewSize: CGSize) -> (origin: CGPoint, size: CGSize) {
        let rect = makeTransform(in: viewSize).transformedContentRect
        return (rect.origin, rect.size)
    }

    /// Converts remote macOS framebuffer pixel coordinates to SwiftUI view space.
    public func convertToView(remotePoint: CGPoint, in viewSize: CGSize) -> CGPoint {
        makeTransform(in: viewSize).convertToView(remotePoint: remotePoint)
    }

    /// Normalizes SwiftUI view coordinates to remote macOS framebuffer pixel space.
    public func convertToRemote(point: CGPoint, in viewSize: CGSize) -> (x: Int, y: Int) {
        makeTransform(in: viewSize).convertToRemote(viewPoint: point)
    }
}
