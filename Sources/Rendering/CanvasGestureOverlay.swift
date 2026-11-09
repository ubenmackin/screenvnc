// Rendering — Multi-touch, trackpad, pinch/pan, scroll, and hardware pointer overlay.
import SwiftUI
import UIKit

private enum TwoFingerMode {
    case undecided
    case scrolling
    case pinching
}

private enum OneFingerDragKind {
    case none
    case trackpadMove
    case viewportPan
    case buttonDrag
}

@MainActor
public struct CanvasGestureCallbacks {
    public var onPrimaryTap: @MainActor (CGPoint, Bool) -> Void
    public var onRightClick: @MainActor (CGPoint) -> Void
    public var onMiddleClick: @MainActor (CGPoint) -> Void
    public var onTrackpadMove: @MainActor (CGSize, CGPoint) -> Void
    public var onTrackpadEnd: (@MainActor () -> Void)?
    public var onDragStart: @MainActor (CGPoint) -> Void
    public var onDragMove: @MainActor (CGPoint, CGSize) -> Void
    public var onDragEnd: @MainActor (CGPoint) -> Void
    public var onViewportPanStart: @MainActor () -> Void
    public var onViewportPan: @MainActor (CGSize) -> Void
    public var onViewportPanEnd: @MainActor (CGPoint) -> Void
    public var onPinchZoom: @MainActor (CGFloat, CGPoint, CGSize) -> Void
    public var onTwoFingerScroll: @MainActor (CGSize, CGPoint) -> Void
    public var onHoverMove: @MainActor (CGPoint) -> Void

    public init(
        onPrimaryTap: @escaping @MainActor (CGPoint, Bool) -> Void,
        onRightClick: @escaping @MainActor (CGPoint) -> Void,
        onMiddleClick: @escaping @MainActor (CGPoint) -> Void,
        onTrackpadMove: @escaping @MainActor (CGSize, CGPoint) -> Void,
        onTrackpadEnd: (@MainActor () -> Void)? = nil,
        onDragStart: @escaping @MainActor (CGPoint) -> Void,
        onDragMove: @escaping @MainActor (CGPoint, CGSize) -> Void,
        onDragEnd: @escaping @MainActor (CGPoint) -> Void,
        onViewportPanStart: @escaping @MainActor () -> Void,
        onViewportPan: @escaping @MainActor (CGSize) -> Void,
        onViewportPanEnd: @escaping @MainActor (CGPoint) -> Void,
        onPinchZoom: @escaping @MainActor (CGFloat, CGPoint, CGSize) -> Void,
        onTwoFingerScroll: @escaping @MainActor (CGSize, CGPoint) -> Void,
        onHoverMove: @escaping @MainActor (CGPoint) -> Void
    ) {
        self.onPrimaryTap = onPrimaryTap
        self.onRightClick = onRightClick
        self.onMiddleClick = onMiddleClick
        self.onTrackpadMove = onTrackpadMove
        self.onTrackpadEnd = onTrackpadEnd
        self.onDragStart = onDragStart
        self.onDragMove = onDragMove
        self.onDragEnd = onDragEnd
        self.onViewportPanStart = onViewportPanStart
        self.onViewportPan = onViewportPan
        self.onViewportPanEnd = onViewportPanEnd
        self.onPinchZoom = onPinchZoom
        self.onTwoFingerScroll = onTwoFingerScroll
        self.onHoverMove = onHoverMove
    }
}

public struct CanvasGestureConfiguration: Sendable, Equatable {
    public var pointerMode: PointerMode
    public var canPan: Bool
    public var isInputDisabled: Bool
    public var tapToClickInTrackpad: Bool
    public var twoFingerTrackpadAction: TwoFingerTrackpadAction

    public init(
        pointerMode: PointerMode,
        canPan: Bool,
        isInputDisabled: Bool,
        tapToClickInTrackpad: Bool,
        twoFingerTrackpadAction: TwoFingerTrackpadAction
    ) {
        self.pointerMode = pointerMode
        self.canPan = canPan
        self.isInputDisabled = isInputDisabled
        self.tapToClickInTrackpad = tapToClickInTrackpad
        self.twoFingerTrackpadAction = twoFingerTrackpadAction
    }
}

public struct CanvasGestureOverlay: UIViewRepresentable {
    public var configuration: CanvasGestureConfiguration
    public var callbacks: CanvasGestureCallbacks

    public init(configuration: CanvasGestureConfiguration, callbacks: CanvasGestureCallbacks) {
        self.configuration = configuration
        self.callbacks = callbacks
    }

    public func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        context.coordinator.installRecognizers(on: view)
        return view
    }

    public func updateUIView(_: UIView, context: Context) {
        context.coordinator.configuration = configuration
        context.coordinator.callbacks = callbacks
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(configuration: configuration, callbacks: callbacks)
    }

    @MainActor
    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: CanvasGestureConfiguration
        var callbacks: CanvasGestureCallbacks

        private var singleTap: UITapGestureRecognizer?
        private var secondaryClickTap: UITapGestureRecognizer?
        private var twoFingerTap: UITapGestureRecognizer?
        private var threeFingerTap: UITapGestureRecognizer?
        private var oneFingerPan: UIPanGestureRecognizer?
        private var twoFingerPan: UIPanGestureRecognizer?
        private var threeFingerPan: UIPanGestureRecognizer?
        private var pinchRecognizer: UIPinchGestureRecognizer?
        private var longPressRecognizer: UILongPressGestureRecognizer?
        private var hoverRecognizer: UIHoverGestureRecognizer?
        private var indirectScrollRecognizer: UIPanGestureRecognizer?

        private var lastTapTimestamp: TimeInterval = 0
        private var lastTapLocation: CGPoint = .zero
        private var oneFingerDragKind: OneFingerDragKind = .none
        private var lastOneFingerTranslation: CGPoint = .zero
        private var lastOneFingerLocation: CGPoint = .zero

        private var longPressDragging = false
        private var lastLongPressLocation: CGPoint = .zero

        private var twoFingerMode: TwoFingerMode = .undecided
        private var lastTwoFingerTranslation: CGPoint = .zero
        private var lastPinchAnchor: CGPoint = .zero
        private var lastThreeFingerTranslation: CGPoint = .zero
        private var lastIndirectScrollTranslation: CGPoint = .zero

        private let haptic = UIImpactFeedbackGenerator(style: .medium)

        init(configuration: CanvasGestureConfiguration, callbacks: CanvasGestureCallbacks) {
            self.configuration = configuration
            self.callbacks = callbacks
        }

        func installRecognizers(on view: UIView) {
            let tap1 = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            tap1.numberOfTouchesRequired = 1
            tap1.numberOfTapsRequired = 1
            tap1.delegate = self

            let secondaryTap = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryMouseTap(_:)))
            secondaryTap.numberOfTouchesRequired = 1
            secondaryTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            secondaryTap.buttonMaskRequired = .secondary
            secondaryTap.delegate = self

            let tap2 = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            tap2.numberOfTouchesRequired = 2
            tap2.numberOfTapsRequired = 1
            tap2.delegate = self

            let tap3 = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
            tap3.numberOfTouchesRequired = 3
            tap3.numberOfTapsRequired = 1
            tap3.delegate = self

            let pan1 = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
            pan1.minimumNumberOfTouches = 1
            pan1.maximumNumberOfTouches = 1
            pan1.allowedScrollTypesMask = []
            pan1.delegate = self

            let pan2 = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
            pan2.minimumNumberOfTouches = 2
            pan2.maximumNumberOfTouches = 2
            pan2.allowedScrollTypesMask = []
            pan2.delegate = self

            let pan3 = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerPan(_:)))
            pan3.minimumNumberOfTouches = 3
            pan3.maximumNumberOfTouches = 3
            pan3.allowedScrollTypesMask = []
            pan3.delegate = self

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.numberOfTouchesRequired = 1
            longPress.minimumPressDuration = 0.34
            longPress.allowableMovement = 14
            longPress.delegate = self

            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            hover.delegate = self

            let indirectScroll = UIPanGestureRecognizer(target: self, action: #selector(handleIndirectScroll(_:)))
            indirectScroll.allowedTouchTypes = []
            indirectScroll.allowedScrollTypesMask = .all
            indirectScroll.delegate = self

            let all: [UIGestureRecognizer] = [
                tap1, secondaryTap, tap2, tap3,
                pan1, pan2, pan3, pinch, longPress,
                hover, indirectScroll
            ]
            for recognizer in all {
                view.addGestureRecognizer(recognizer)
            }

            singleTap = tap1
            secondaryClickTap = secondaryTap
            twoFingerTap = tap2
            threeFingerTap = tap3
            oneFingerPan = pan1
            twoFingerPan = pan2
            threeFingerPan = pan3
            pinchRecognizer = pinch
            longPressRecognizer = longPress
            hoverRecognizer = hover
            indirectScrollRecognizer = indirectScroll
        }

        // MARK: - Gesture Handlers

        @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard !configuration.isInputDisabled else { return }
            if configuration.pointerMode == .virtualTrackpad, !configuration.tapToClickInTrackpad {
                return
            }
            let location = gesture.location(in: gesture.view)
            let now = ProcessInfo.processInfo.systemUptime
            let isDoubleTap = (now - lastTapTimestamp) < 0.34 &&
                hypot(location.x - lastTapLocation.x, location.y - lastTapLocation.y) <= 22
            let targetLocation = isDoubleTap ? lastTapLocation : location
            lastTapTimestamp = now
            lastTapLocation = targetLocation
            callbacks.onPrimaryTap(targetLocation, isDoubleTap)
        }

        @objc private func handleSecondaryMouseTap(_ gesture: UITapGestureRecognizer) {
            guard !configuration.isInputDisabled else { return }
            callbacks.onRightClick(gesture.location(in: gesture.view))
        }

        @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            guard !configuration.isInputDisabled else { return }
            callbacks.onRightClick(gesture.location(in: gesture.view))
        }

        @objc private func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
            guard !configuration.isInputDisabled else { return }
            callbacks.onMiddleClick(gesture.location(in: gesture.view))
        }

        @objc private func handleOneFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard !longPressDragging, let view = gesture.view else { return }
            let location = gesture.location(in: view)
            let translation = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)

            switch gesture.state {
            case .began:
                beginOneFingerPan(at: location)
            case .changed:
                updateOneFingerPan(location: location, translation: translation, velocity: velocity)
            case .ended, .cancelled, .failed:
                endOneFingerPan(location: location, velocity: velocity, isEnded: gesture.state == .ended)
            default:
                break
            }
        }

        private func beginOneFingerPan(at location: CGPoint) {
            // Once 1-finger pan starts moving, cancel pending long-press recognition immediately.
            if let lp = longPressRecognizer, lp.state == .possible {
                lp.isEnabled = false
                lp.isEnabled = true
            }
            lastOneFingerTranslation = .zero
            lastOneFingerLocation = location
            callbacks.onViewportPanStart()

            if configuration.isInputDisabled {
                oneFingerDragKind = configuration.canPan ? .viewportPan : .none
                return
            }

            if configuration.pointerMode == .virtualTrackpad {
                oneFingerDragKind = shouldStartTapDrag(at: location) ? .buttonDrag : .trackpadMove
                if oneFingerDragKind == .buttonDrag {
                    haptic.prepare()
                    haptic.impactOccurred(intensity: 0.65)
                    callbacks.onDragStart(location)
                }
            } else if configuration.canPan {
                oneFingerDragKind = .viewportPan
            } else {
                oneFingerDragKind = .buttonDrag
                callbacks.onDragStart(location)
            }
        }

        private func shouldStartTapDrag(at location: CGPoint) -> Bool {
            let now = ProcessInfo.processInfo.systemUptime
            return configuration.tapToClickInTrackpad &&
                (now - lastTapTimestamp) < 0.32 &&
                hypot(location.x - lastTapLocation.x, location.y - lastTapLocation.y) <= 28
        }

        private func updateOneFingerPan(location: CGPoint, translation: CGPoint, velocity: CGPoint) {
            let delta = CGSize(
                width: translation.x - lastOneFingerTranslation.x,
                height: translation.y - lastOneFingerTranslation.y
            )
            lastOneFingerTranslation = translation
            lastOneFingerLocation = location

            switch oneFingerDragKind {
            case .none:
                break
            case .trackpadMove:
                callbacks.onTrackpadMove(delta, velocity)
            case .viewportPan:
                callbacks.onViewportPan(delta)
            case .buttonDrag:
                callbacks.onDragMove(location, delta)
            }
        }

        private func endOneFingerPan(location: CGPoint, velocity: CGPoint, isEnded: Bool) {
            let endedKind = oneFingerDragKind
            oneFingerDragKind = .none
            lastOneFingerTranslation = .zero
            switch endedKind {
            case .none:
                break
            case .trackpadMove:
                callbacks.onTrackpadEnd?()
            case .viewportPan:
                if isEnded {
                    callbacks.onViewportPanEnd(velocity)
                }
            case .buttonDrag:
                callbacks.onDragEnd(location)
            }
        }

        @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard !configuration.isInputDisabled, let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                if let pan1 = oneFingerPan {
                    pan1.isEnabled = false
                    pan1.isEnabled = true
                }
                oneFingerDragKind = .none
                haptic.prepare()
                haptic.impactOccurred(intensity: 0.85)
                longPressDragging = true
                lastLongPressLocation = location
                callbacks.onDragStart(location)
            case .changed:
                guard longPressDragging else { return }
                let delta = CGSize(
                    width: location.x - lastLongPressLocation.x,
                    height: location.y - lastLongPressLocation.y
                )
                lastLongPressLocation = location
                callbacks.onDragMove(location, delta)
            case .ended, .cancelled, .failed:
                guard longPressDragging else { return }
                longPressDragging = false
                callbacks.onDragEnd(location)
            default:
                break
            }
        }

        @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let location = gesture.location(in: view)
            let velocity = gesture.velocity(in: view)

            switch gesture.state {
            case .began:
                lastTwoFingerTranslation = .zero
                callbacks.onViewportPanStart()
                if twoFingerMode == .pinching {
                    return
                }
                twoFingerMode = .undecided

            case .changed:
                let delta = CGSize(
                    width: translation.x - lastTwoFingerTranslation.x,
                    height: translation.y - lastTwoFingerTranslation.y
                )
                lastTwoFingerTranslation = translation

                if twoFingerMode == .pinching {
                    return
                }
                if twoFingerMode == .undecided {
                    let travel = hypot(translation.x, translation.y)
                    let pinchDelta = abs((pinchRecognizer?.scale ?? 1.0) - 1.0)
                    if travel >= 10, pinchDelta < 0.08 {
                        twoFingerMode = .scrolling
                    } else {
                        return
                    }
                }

                if configuration.pointerMode == .virtualTrackpad,
                   configuration.twoFingerTrackpadAction == .panViewport
                {
                    callbacks.onViewportPan(delta)
                } else if !configuration.isInputDisabled {
                    callbacks.onTwoFingerScroll(delta, location)
                }

            case .ended, .cancelled, .failed:
                let wasPanning = twoFingerMode == .scrolling &&
                    configuration.pointerMode == .virtualTrackpad &&
                    configuration.twoFingerTrackpadAction == .panViewport
                if twoFingerMode == .scrolling {
                    twoFingerMode = .undecided
                }
                lastTwoFingerTranslation = .zero
                if wasPanning, gesture.state == .ended {
                    callbacks.onViewportPanEnd(velocity)
                }

            default:
                break
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view else { return }
            let anchor = gesture.location(in: view)

            switch gesture.state {
            case .began:
                lastPinchAnchor = anchor
                callbacks.onViewportPanStart()
                if twoFingerMode == .scrolling {
                    return
                }

            case .changed:
                if twoFingerMode == .scrolling {
                    gesture.scale = 1.0
                    lastPinchAnchor = anchor
                    return
                }
                if twoFingerMode == .undecided {
                    if abs(gesture.scale - 1.0) < 0.06 {
                        return
                    }
                    twoFingerMode = .pinching
                }
                let scaleDelta = gesture.scale
                gesture.scale = 1.0
                let translationDelta = CGSize(
                    width: anchor.x - lastPinchAnchor.x,
                    height: anchor.y - lastPinchAnchor.y
                )
                lastPinchAnchor = anchor
                callbacks.onPinchZoom(scaleDelta, anchor, translationDelta)

            case .ended, .cancelled, .failed:
                if twoFingerMode == .pinching {
                    twoFingerMode = .undecided
                }
                gesture.scale = 1.0

            default:
                break
            }
        }

        @objc private func handleThreeFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)

            switch gesture.state {
            case .began:
                lastThreeFingerTranslation = .zero
                callbacks.onViewportPanStart()
            case .changed:
                let delta = CGSize(
                    width: translation.x - lastThreeFingerTranslation.x,
                    height: translation.y - lastThreeFingerTranslation.y
                )
                lastThreeFingerTranslation = translation
                callbacks.onViewportPan(delta)
            case .ended, .cancelled, .failed:
                lastThreeFingerTranslation = .zero
                if gesture.state == .ended {
                    callbacks.onViewportPanEnd(velocity)
                }
            default:
                break
            }
        }

        @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
            guard !configuration.isInputDisabled, let view = gesture.view else { return }
            switch gesture.state {
            case .began, .changed:
                callbacks.onHoverMove(gesture.location(in: view))
            case .ended, .cancelled:
                callbacks.onTrackpadEnd?()
            default:
                break
            }
        }

        @objc private func handleIndirectScroll(_ gesture: UIPanGestureRecognizer) {
            guard !configuration.isInputDisabled, let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                lastIndirectScrollTranslation = .zero
            case .changed:
                let delta = CGSize(
                    width: translation.x - lastIndirectScrollTranslation.x,
                    height: translation.y - lastIndirectScrollTranslation.y
                )
                lastIndirectScrollTranslation = translation
                callbacks.onTwoFingerScroll(delta, location)
            case .ended, .cancelled, .failed:
                lastIndirectScrollTranslation = .zero
            default:
                break
            }
        }

        // MARK: - UIGestureRecognizerDelegate

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Allow 2-finger pan and pinch to observe touches concurrently until one locks.
            let isTwoFingerPair =
                (gestureRecognizer === pinchRecognizer && otherGestureRecognizer === twoFingerPan) ||
                (gestureRecognizer === twoFingerPan && otherGestureRecognizer === pinchRecognizer)
            if isTwoFingerPair {
                return true
            }
            return false
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Taps wait on higher-finger taps (which fail immediately on touch-up without delay).
            if gestureRecognizer === singleTap {
                return otherGestureRecognizer === twoFingerTap ||
                    otherGestureRecognizer === threeFingerTap ||
                    otherGestureRecognizer === secondaryClickTap
            }
            if gestureRecognizer === twoFingerTap {
                return otherGestureRecognizer === threeFingerTap
            }
            return false
        }
    }
}
