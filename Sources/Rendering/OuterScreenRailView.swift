// Rendering — Trailing vertical control rail for iPhone Duo outer display per Apple HIG.
import SwiftUI

public struct OuterScreenRailView: View {
    @Binding public var activeModifiers: Set<MacKey>
    @Binding public var isKeyboardActive: Bool
    public var pointerMode: PointerMode
    public var onTogglePointerMode: @MainActor () -> Void
    public var onKeyPress: @MainActor (UInt32, Bool) -> Void
    public var onSendShortcut: @MainActor (String) -> Void
    public var onToggleDisplayPreference: @MainActor () -> Void
    public var onDisconnect: @MainActor () -> Void
    public var isInputDisabled: Bool = false

    @State private var isCollapsed: Bool = false

    public init(
        activeModifiers: Binding<Set<MacKey>>,
        isKeyboardActive: Binding<Bool>,
        pointerMode: PointerMode = .directTouch,
        onTogglePointerMode: @escaping @MainActor () -> Void = {},
        onKeyPress: @escaping @MainActor (UInt32, Bool) -> Void,
        onSendShortcut: @escaping @MainActor (String) -> Void,
        onToggleDisplayPreference: @escaping @MainActor () -> Void,
        onDisconnect: @escaping @MainActor () -> Void,
        isInputDisabled: Bool = false
    ) {
        _activeModifiers = activeModifiers
        _isKeyboardActive = isKeyboardActive
        self.pointerMode = pointerMode
        self.onTogglePointerMode = onTogglePointerMode
        self.onKeyPress = onKeyPress
        self.onSendShortcut = onSendShortcut
        self.onToggleDisplayPreference = onToggleDisplayPreference
        self.onDisconnect = onDisconnect
        self.isInputDisabled = isInputDisabled
    }

    public var body: some View {
        if isCollapsed {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    isCollapsed = false
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .shadow(radius: 4)
            }
        } else {
            VStack(spacing: 10) {
                // Collapse action button
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        isCollapsed = true
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 28)
                }

                // Disconnect Action
                SessionDisconnectButton(onDisconnect: onDisconnect)

                Divider().frame(width: 20)

                // Software Keyboard Toggle
                SessionKeyboardToggleButton(
                    isKeyboardActive: isKeyboardActive,
                    isInputDisabled: isInputDisabled
                ) {
                    isKeyboardActive.toggle()
                }

                // Pointer Mode Toggle
                SessionPointerModeButton(
                    pointerMode: pointerMode,
                    isInputDisabled: isInputDisabled
                ) {
                    onTogglePointerMode()
                }

                Divider().frame(width: 20)

                // Modifiers within direct thumb reach
                ForEach([MacKey.command, .option, .control, .shift]) { key in
                    SessionModifierButton(
                        key: key,
                        isActive: activeModifiers.contains(key),
                        isInputDisabled: isInputDisabled
                    ) {
                        toggleStickyMacModifier(key, activeModifiers: &activeModifiers, onKeyPress: onKeyPress)
                    }
                }

                Divider().frame(width: 20)

                // Zoom / Aspect Mode Toggle
                SessionDisplayModeButton {
                    onToggleDisplayPreference()
                }

                // Quick Mac Actions Menu
                SessionMacActionsMenu(
                    onSendShortcut: onSendShortcut,
                    isInputDisabled: isInputDisabled
                )
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 4)
        }
    }
}
