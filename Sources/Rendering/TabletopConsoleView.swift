// Rendering — Dedicated lower-pane console for foldable tabletop pose (trackpad + extended Mac controls).
import SwiftUI

public struct TabletopConsoleView: View {
    @Binding public var activeModifiers: Set<MacKey>
    public var onPointerDelta: @MainActor (CGFloat, CGFloat, UInt8) -> Void
    public var onPointerClick: @MainActor (UInt8) -> Void
    public var onKeyPress: @MainActor (UInt32, Bool) -> Void
    public var onSendShortcut: @MainActor (String) -> Void
    public var isInputDisabled: Bool = false

    @State private var trackpadDragStart: CGPoint = .zero
    @State private var isLeftMouseDown = false
    @State private var isRightMouseDown = false

    public init(
        activeModifiers: Binding<Set<MacKey>>,
        onPointerDelta: @escaping @MainActor (CGFloat, CGFloat, UInt8) -> Void,
        onPointerClick: @escaping @MainActor (UInt8) -> Void,
        onKeyPress: @escaping @MainActor (UInt32, Bool) -> Void,
        onSendShortcut: @escaping @MainActor (String) -> Void,
        isInputDisabled: Bool = false
    ) {
        _activeModifiers = activeModifiers
        self.onPointerDelta = onPointerDelta
        self.onPointerClick = onPointerClick
        self.onKeyPress = onKeyPress
        self.onSendShortcut = onSendShortcut
        self.isInputDisabled = isInputDisabled
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // View-only suppresses trackpad deltas.
                        guard !isInputDisabled else { return }
                        let deltaX = value.translation.width
                        let deltaY = value.translation.height
                        onPointerDelta(deltaX, deltaY, 0)
                    }
            )
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
