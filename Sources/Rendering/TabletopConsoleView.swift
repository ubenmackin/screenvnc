// Rendering — Dedicated lower-pane console for foldable tabletop pose (trackpad + extended Mac controls).
import SwiftUI

public struct TabletopConsoleView: View {
    @Binding public var activeModifiers: Set<MacKey>
    public var onPointerDelta: @MainActor (CGFloat, CGFloat, UInt8) -> Void
    public var onPointerClick: @MainActor (UInt8) -> Void
    public var onPointerScroll: (@MainActor (CGSize, CGPoint) -> Void)?
    public var onKeyPress: @MainActor (UInt32, Bool) -> Void
    public var onSendShortcut: @MainActor (String) -> Void
    public var isInputDisabled: Bool = false
    public var onGestureBegan: (@MainActor () -> Void)?

    @State private var isTapDragging = false

    public init(
        activeModifiers: Binding<Set<MacKey>>,
        onPointerDelta: @escaping @MainActor (CGFloat, CGFloat, UInt8) -> Void,
        onPointerClick: @escaping @MainActor (UInt8) -> Void,
        onPointerScroll: (@MainActor (CGSize, CGPoint) -> Void)? = nil,
        onKeyPress: @escaping @MainActor (UInt32, Bool) -> Void,
        onSendShortcut: @escaping @MainActor (String) -> Void,
        isInputDisabled: Bool = false,
        onGestureBegan: (@MainActor () -> Void)? = nil
    ) {
        _activeModifiers = activeModifiers
        self.onPointerDelta = onPointerDelta
        self.onPointerClick = onPointerClick
        self.onPointerScroll = onPointerScroll
        self.onKeyPress = onKeyPress
        self.onSendShortcut = onSendShortcut
        self.isInputDisabled = isInputDisabled
        self.onGestureBegan = onGestureBegan
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Virtual Trackpad Surface
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                VStack {
                    HStack {
                        Label("Virtual Trackpad", systemImage: "hand.draw")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 14)

                    Spacer()

                    // Click Buttons
                    HStack(spacing: 12) {
                        Button {
                            onPointerClick(1)
                        } label: {
                            Text("Left Click")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        Button {
                            onPointerClick(4)
                        } label: {
                            Text("Right Click")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
            .overlay {
                CanvasGestureOverlay(
                    configuration: CanvasGestureConfiguration(
                        pointerMode: .virtualTrackpad,
                        canPan: false,
                        isInputDisabled: isInputDisabled,
                        tapToClickInTrackpad: SettingsStore.shared.tapToClickInTrackpad,
                        twoFingerTrackpadAction: .scrollRemote
                    ),
                    callbacks: CanvasGestureCallbacks(
                        onPrimaryTap: { _, _ in
                            onPointerClick(RFBConstants.PointerButton.left.rawValue)
                        },
                        onRightClick: { _ in
                            onPointerClick(RFBConstants.PointerButton.right.rawValue)
                        },
                        onMiddleClick: { _ in
                            onPointerClick(RFBConstants.PointerButton.middle.rawValue)
                        },
                        onTrackpadMove: { delta, _ in
                            let speed = CGFloat(SettingsStore.shared.trackpadSensitivity) * 1.4
                            onPointerDelta(delta.width * speed, delta.height * speed, 0)
                        },
                        onDragStart: { _ in
                            isTapDragging = true
                            onPointerDelta(0, 0, RFBConstants.PointerButton.left.rawValue)
                        },
                        onDragMove: { _, delta in
                            let speed = CGFloat(SettingsStore.shared.trackpadSensitivity) * 1.4
                            onPointerDelta(delta.width * speed, delta.height * speed, RFBConstants.PointerButton.left.rawValue)
                        },
                        onDragEnd: { _ in
                            isTapDragging = false
                            onPointerDelta(0, 0, 0)
                        },
                        onViewportPanStart: {
                            onGestureBegan?()
                        },
                        onViewportPan: { _ in },
                        onViewportPanEnd: { _ in },
                        onPinchZoom: { _, _, _ in },
                        onTwoFingerScroll: { delta, _, velocity in
                            onPointerScroll?(delta, velocity)
                        },
                        onHoverMove: { _ in }
                    )
                )
                .padding(.bottom, 60)
            }
            .frame(maxHeight: .infinity)
            .disabled(isInputDisabled)
            .opacity(isInputDisabled ? 0.4 : 1.0)

            // Mac Keyboard Bar
            MacKeyboardBar(
                activeModifiers: $activeModifiers,
                onKeyPress: onKeyPress,
                onSendShortcut: onSendShortcut,
                isInputDisabled: isInputDisabled
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(8)
        .background(Color(uiColor: .systemBackground))
    }
}
