// Rendering — Mac-specific modifier keys, function keys, and shortcut trigger bar.
import os
import SwiftUI

public enum MacKey: UInt32, CaseIterable, Identifiable {
    case escape = 0xFF1B
    case tab = 0xFF09
    case backspace = 0xFF08
    case `return` = 0xFF0D
    case arrowLeft = 0xFF51
    case arrowUp = 0xFF52
    case arrowRight = 0xFF53
    case arrowDown = 0xFF54
    case command = 0xFFEB
    case option = 0xFFE9
    case control = 0xFFE3
    case shift = 0xFFE1

    public var id: UInt32 {
        rawValue
    }

    public var symbol: String {
        switch self {
        case .escape: "Esc"
        case .tab: "Tab"
        case .backspace: "⌫"
        case .return: "⏎"
        case .arrowLeft: "←"
        case .arrowUp: "↑"
        case .arrowRight: "→"
        case .arrowDown: "↓"
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        }
    }

    public var isModifier: Bool {
        switch self {
        case .command, .option, .control, .shift: true
        default: false
        }
    }
}

/// Shared sticky-modifier toggle; single owner for modifier state changes.
@MainActor
public func toggleStickyMacModifier(
    _ key: MacKey,
    activeModifiers: inout Set<MacKey>,
    onKeyPress: @MainActor (UInt32, Bool) -> Void
) {
    if activeModifiers.contains(key) {
        activeModifiers.remove(key)
        onKeyPress(key.rawValue, false)
    } else {
        activeModifiers.insert(key)
        onKeyPress(key.rawValue, true)
    }
}

public struct MacKeyboardBar: View {
    @Binding public var activeModifiers: Set<MacKey>
    public var onKeyPress: @MainActor (UInt32, Bool) -> Void
    public var onSendShortcut: @MainActor (String) -> Void
    public var isInputDisabled: Bool = false

    @State private var showingShortcutsMenu = false

    public init(
        activeModifiers: Binding<Set<MacKey>>,
        onKeyPress: @escaping @MainActor (UInt32, Bool) -> Void,
        onSendShortcut: @escaping @MainActor (String) -> Void,
        isInputDisabled: Bool = false
    ) {
        _activeModifiers = activeModifiers
        self.onKeyPress = onKeyPress
        self.onSendShortcut = onSendShortcut
        self.isInputDisabled = isInputDisabled
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Modifiers with sticky toggle state
                ForEach([MacKey.command, .option, .control, .shift]) { key in
                    Button {
                        toggleStickyMacModifier(key, activeModifiers: &activeModifiers, onKeyPress: onKeyPress)
                    } label: {
                        Text(key.symbol)
                            .font(.system(.body, design: .rounded).bold())
                            .frame(minWidth: 40, minHeight: 36)
                            .background(
                                activeModifiers.contains(key) ? Color.accentColor : Color.secondary.opacity(0.2)
                            )
                            .foregroundStyle(activeModifiers.contains(key) ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                Divider().frame(height: 24)

                // Navigation & Action Keys
                ForEach([MacKey.escape, .tab, .backspace, .return]) { key in
                    Button {
                        triggerKeyTap(key)
                    } label: {
                        Text(key.symbol)
                            .font(.system(.body, design: .rounded))
                            .frame(minWidth: 40, minHeight: 36)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                Divider().frame(height: 24)

                // Arrow keys
                ForEach([MacKey.arrowLeft, .arrowUp, .arrowDown, .arrowRight]) { key in
                    Button {
                        triggerKeyTap(key)
                    } label: {
                        Text(key.symbol)
                            .font(.system(.body, design: .rounded))
                            .frame(minWidth: 36, minHeight: 36)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                Divider().frame(height: 24)

                // Mac Quick Shortcuts Menu
                Menu {
                    Button("⌘ + Tab (App Switcher)") { onSendShortcut("cmd_tab") }
                    Button("⌘ + Space (Spotlight)") { onSendShortcut("spotlight") }
                    Button("⌃ + ↑ (Mission Control)") { onSendShortcut("mission_control") }
                    Button("⌘ + W (Close Window)") { onSendShortcut("close_window") }
                    Button("⌘ + Q (Quit App)") { onSendShortcut("quit_app") }
                    Button("⌃ + ⌘ + Q (Lock Mac)") { onSendShortcut("lock_mac") }
                } label: {
                    Label("Mac Actions", systemImage: "macbook.and.iphone")
                        .font(.system(.subheadline, design: .rounded))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 36)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
        .disabled(isInputDisabled)
        .opacity(isInputDisabled ? 0.4 : 1.0)
    }

    private func triggerKeyTap(_ key: MacKey) {
        onKeyPress(key.rawValue, true)
        Task {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch is CancellationError {
                // Ensure key-up below keeps pair balanced on cancellation
            } catch {
                Logger(subsystem: "com.volcrypt.ScreenVNC", category: "MacKeyboardBar")
                    .debug("Key tap sleep interrupted: \(error.localizedDescription)")
            }
            onKeyPress(key.rawValue, false)
        }
    }
}
