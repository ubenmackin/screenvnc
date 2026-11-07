// Rendering — Trailing vertical control rail for iPhone Duo outer display per Apple HIG.
import SwiftUI

public struct OuterScreenRailView: View {
    @Binding public var activeModifiers: Set<MacKey>
    public var onKeyPress: @MainActor (UInt32, Bool) -> Void
    public var onSendShortcut: @MainActor (String) -> Void
    public var onToggleDisplayPreference: @MainActor () -> Void
    public var onDisconnect: @MainActor () -> Void
    public var isInputDisabled: Bool = false

    public init(
        activeModifiers: Binding<Set<MacKey>>,
        onKeyPress: @escaping @MainActor (UInt32, Bool) -> Void,
        onSendShortcut: @escaping @MainActor (String) -> Void,
        onToggleDisplayPreference: @escaping @MainActor () -> Void,
        onDisconnect: @escaping @MainActor () -> Void,
        isInputDisabled: Bool = false
    ) {
        _activeModifiers = activeModifiers
        self.onKeyPress = onKeyPress
        self.onSendShortcut = onSendShortcut
        self.onToggleDisplayPreference = onToggleDisplayPreference
        self.onDisconnect = onDisconnect
        self.isInputDisabled = isInputDisabled
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Disconnect Action
            Button(role: .destructive) {
                onDisconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
            }

            Divider().frame(width: 24)

            // Modifiers within direct thumb reach
            ForEach([MacKey.command, .option, .control, .shift]) { key in
                Button {
                    toggleStickyMacModifier(key, activeModifiers: &activeModifiers, onKeyPress: onKeyPress)
                } label: {
                    Text(key.symbol)
                        .font(.system(.subheadline, design: .rounded).bold())
                        .frame(width: 40, height: 40)
                        .background(activeModifiers.contains(key) ? Color.accentColor : Color.secondary.opacity(0.2))
                        .foregroundStyle(activeModifiers.contains(key) ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                // View-only keeps disconnect/display live.
                .disabled(isInputDisabled)
                .opacity(isInputDisabled ? 0.4 : 1.0)
            }

            Divider().frame(width: 24)

            // Zoom / Aspect Mode Toggle
            Button {
                onToggleDisplayPreference()
            } label: {
                Image(systemName: "aspectratio")
                    .font(.system(size: 18))
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Quick Mac Actions Menu
            Menu {
                Button("⌘ + Tab (App Switcher)") { onSendShortcut("cmd_tab") }
                Button("⌘ + Space (Spotlight)") { onSendShortcut("spotlight") }
                Button("⌃ + ↑ (Mission Control)") { onSendShortcut("mission_control") }
                Button("⌘ + W (Close Window)") { onSendShortcut("close_window") }
                Button("⌘ + Q (Quit App)") { onSendShortcut("quit_app") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .frame(width: 40, height: 40)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            // View-only keeps disconnect/display live.
            .disabled(isInputDisabled)
            .opacity(isInputDisabled ? 0.4 : 1.0)

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 4)
    }
}
