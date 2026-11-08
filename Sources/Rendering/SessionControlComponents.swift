// Rendering — Shared session controls for dock and outer rail.
import SwiftUI

/// Shared disconnect control; always enabled so session can exit cleanly.
public struct SessionDisconnectButton: View {
    public var onDisconnect: @MainActor () -> Void

    public init(onDisconnect: @escaping @MainActor () -> Void) {
        self.onDisconnect = onDisconnect
    }

    public var body: some View {
        Button(role: .destructive) {
            onDisconnect()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.red)
                .frame(width: 36, height: 36)
        }
    }
}

/// Shared software keyboard toggle with consistent selected styling.
public struct SessionKeyboardToggleButton: View {
    public var isKeyboardActive: Bool
    public var isInputDisabled: Bool
    public var onToggle: @MainActor () -> Void

    public init(
        isKeyboardActive: Bool,
        isInputDisabled: Bool = false,
        onToggle: @escaping @MainActor () -> Void
    ) {
        self.isKeyboardActive = isKeyboardActive
        self.isInputDisabled = isInputDisabled
        self.onToggle = onToggle
    }

    public var body: some View {
        Button {
            onToggle()
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
    }
}

/// Shared pointer mode toggle; single owner for direct versus trackpad icon.
public struct SessionPointerModeButton: View {
    public var pointerMode: PointerMode
    public var isInputDisabled: Bool
    public var onToggle: @MainActor () -> Void

    public init(
        pointerMode: PointerMode,
        isInputDisabled: Bool = false,
        onToggle: @escaping @MainActor () -> Void
    ) {
        self.pointerMode = pointerMode
        self.isInputDisabled = isInputDisabled
        self.onToggle = onToggle
    }

    public var body: some View {
        Button {
            onToggle()
        } label: {
            Image(systemName: pointerMode == .directTouch ? "hand.point.up.fill" : "cursorarrow.rays")
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .disabled(isInputDisabled)
        .opacity(isInputDisabled ? 0.4 : 1.0)
    }
}

/// Shared display preference toggle; available even while view-only.
public struct SessionDisplayModeButton: View {
    public var onToggle: @MainActor () -> Void

    public init(onToggle: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
    }

    public var body: some View {
        Button {
            onToggle()
        } label: {
            Image(systemName: "aspectratio")
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Shared sticky modifier key with selected state; caller owns set mutation.
public struct SessionModifierButton: View {
    public var key: MacKey
    public var isActive: Bool
    public var isInputDisabled: Bool
    public var onToggle: @MainActor () -> Void

    public init(
        key: MacKey,
        isActive: Bool,
        isInputDisabled: Bool = false,
        onToggle: @escaping @MainActor () -> Void
    ) {
        self.key = key
        self.isActive = isActive
        self.isInputDisabled = isInputDisabled
        self.onToggle = onToggle
    }

    public var body: some View {
        Button {
            onToggle()
        } label: {
            Text(key.symbol)
                .font(.system(.body, design: .rounded).bold())
                .frame(width: 36, height: 36)
                .background(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundStyle(isActive ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .disabled(isInputDisabled)
        .opacity(isInputDisabled ? 0.4 : 1.0)
    }
}

/// Shared Mac shortcut menu; single list of remote action identifiers.
public struct SessionMacActionsMenu: View {
    public var onSendShortcut: @MainActor (String) -> Void
    public var onResetZoom: (@MainActor () -> Void)?
    public var onShowGestureGuide: (@MainActor () -> Void)?
    public var isInputDisabled: Bool

    public init(
        onSendShortcut: @escaping @MainActor (String) -> Void,
        onResetZoom: (@MainActor () -> Void)? = nil,
        onShowGestureGuide: (@MainActor () -> Void)? = nil,
        isInputDisabled: Bool = false
    ) {
        self.onSendShortcut = onSendShortcut
        self.onResetZoom = onResetZoom
        self.onShowGestureGuide = onShowGestureGuide
        self.isInputDisabled = isInputDisabled
    }

    public var body: some View {
        Menu {
            Section("Mac Shortcuts") {
                Button("⌘ + Tab (App Switcher)") { onSendShortcut("cmd_tab") }
                Button("⌘ + Space (Spotlight)") { onSendShortcut("spotlight") }
                Button("⌃ + ↑ (Mission Control)") { onSendShortcut("mission_control") }
                Button("⌘ + W (Close Window)") { onSendShortcut("close_window") }
                Button("⌘ + Q (Quit App)") { onSendShortcut("quit_app") }
                Button("⌃ + ⌘ + Q (Lock Mac)") { onSendShortcut("lock_mac") }
            }
            .disabled(isInputDisabled)

            if onResetZoom != nil || onShowGestureGuide != nil {
                Section("Viewer") {
                    if let onResetZoom {
                        Button("Reset Zoom & Pan", systemImage: "arrow.up.left.and.down.right.magnifyingglass") {
                            onResetZoom()
                        }
                    }
                    if let onShowGestureGuide {
                        Button("Gesture Guide", systemImage: "hand.raised") {
                            onShowGestureGuide()
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18))
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
