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
                Button(role: .destructive) {
                    onDisconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                }

                Divider().frame(width: 20)

                // Software Keyboard Toggle
                Button {
                    isKeyboardActive.toggle()
                } label: {
                    Image(systemName: isKeyboardActive ? "keyboard.fill" : "keyboard")
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .background(isKeyboardActive ? Color.accentColor : Color.secondary.opacity(0.15))
                        .foregroundStyle(isKeyboardActive ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(isInputDisabled)
                .opacity(isInputDisabled ? 0.4 : 1.0)

                // Pointer Mode Toggle
                Button {
                    onTogglePointerMode()
                } label: {
                    Image(systemName: pointerMode == .directTouch ? "hand.point.up.fill" : "cursorarrow.rays")
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(isInputDisabled)
                .opacity(isInputDisabled ? 0.4 : 1.0)

                Divider().frame(width: 20)

                // Modifiers within direct thumb reach
                ForEach([MacKey.command, .option, .control, .shift]) { key in
                    Button {
                        toggleStickyMacModifier(key, activeModifiers: &activeModifiers, onKeyPress: onKeyPress)
                    } label: {
                        Text(key.symbol)
                            .font(.system(.subheadline, design: .rounded).bold())
                            .frame(width: 36, height: 36)
                            .background(activeModifiers.contains(key) ? Color.accentColor : Color.secondary.opacity(0.2))
                            .foregroundStyle(activeModifiers.contains(key) ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .disabled(isInputDisabled)
                    .opacity(isInputDisabled ? 0.4 : 1.0)
                }

                Divider().frame(width: 20)

                // Zoom / Aspect Mode Toggle
                Button {
                    onToggleDisplayPreference()
                } label: {
                    Image(systemName: "aspectratio")
                        .font(.system(size: 16))
                        .frame(width: 36, height: 36)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                // Quick Mac Actions Menu
                Menu {
                    Button("⌘ + Tab (App Switcher)") { onSendShortcut("cmd_tab") }
                    Button("⌘ + Space (Spotlight)") { onSendShortcut("spotlight") }
                    Button("⌃ + ↑ (Mission Control)") { onSendShortcut("mission_control") }
                    Button("⌘ + W (Close Window)") { onSendShortcut("close_window") }
                    Button("⌘ + Q (Quit App)") { onSendShortcut("quit_app") }
                    Button("⌃ + ⌘ + Q (Lock Mac)") { onSendShortcut("lock_mac") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 36)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(isInputDisabled)
                .opacity(isInputDisabled ? 0.4 : 1.0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 4)
        }
    }
}
