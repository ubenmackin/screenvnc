// Rendering — Primary active remote desktop session viewer and mode adapter.
import os
import SwiftUI
import UIKit

/// Session delegate bridges actor callbacks onto MainActor framebuffer.
@MainActor
private final class SessionClientBridge: VNCClientDelegate {
    private let framebuffer: Framebuffer
    private let onStateChange: @MainActor (VNCConnectionState) -> Void
    private let onCutText: @MainActor (String) -> Void

    init(
        framebuffer: Framebuffer,
        onStateChange: @escaping @MainActor (VNCConnectionState) -> Void,
        onCutText: @escaping @MainActor (String) -> Void
    ) {
        self.framebuffer = framebuffer
        self.onStateChange = onStateChange
        self.onCutText = onCutText
    }

    func vncClient(_ _: VNCClient, didUpdateState state: VNCConnectionState) {
        onStateChange(state)
    }

    func vncClient(_ _: VNCClient, didResizeDesktopWidth width: Int, height: Int) {
        framebuffer.resize(width: width, height: height)
    }

    func vncClient(_ _: VNCClient, didReceiveRawRect rect: DecodedRect) {
        framebuffer.applyRawRect(rect)
    }

    func vncClient(_ _: VNCClient, didReceiveCopyRect dest: DecodedRect, srcX: Int, srcY: Int) {
        framebuffer.applyCopyRect(dest: dest, srcX: srcX, srcY: srcY)
    }

    func vncClient(_ _: VNCClient, didReceiveCutText text: String) {
        // Stage server text for explicit user consent; never touch pasteboard here.
        onCutText(text)
    }
}

/// Transparent view bridging the system software keyboard to remote VNC key events.
public struct SoftwareKeyboardResponder: UIViewRepresentable {
    @Binding public var isActive: Bool
    public var onCharacter: @MainActor (Character) -> Void
    public var onDeleteBackward: @MainActor () -> Void

    public init(
        isActive: Binding<Bool>,
        onCharacter: @escaping @MainActor (Character) -> Void,
        onDeleteBackward: @escaping @MainActor () -> Void
    ) {
        _isActive = isActive
        self.onCharacter = onCharacter
        self.onDeleteBackward = onDeleteBackward
    }

    public func makeUIView(context _: Context) -> KeyInputView {
        let view = KeyInputView()
        view.onCharacter = onCharacter
        view.onDeleteBackward = onDeleteBackward
        return view
    }

    public func updateUIView(_ uiView: KeyInputView, context _: Context) {
        uiView.onCharacter = onCharacter
        uiView.onDeleteBackward = onDeleteBackward
        if isActive, !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        } else if !isActive, uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.resignFirstResponder()
            }
        }
    }

    @MainActor
    public final class KeyInputView: UIView, UIKeyInput {
        public var hasText: Bool {
            true
        }

        var onCharacter: (@MainActor (Character) -> Void)?
        var onDeleteBackward: (@MainActor () -> Void)?

        override public var canBecomeFirstResponder: Bool {
            true
        }

        public var autocorrectionType: UITextAutocorrectionType = .no
        public var autocapitalizationType: UITextAutocapitalizationType = .none
        public var smartQuotesType: UITextSmartQuotesType = .no
        public var smartDashesType: UITextSmartDashesType = .no
        public var keyboardType: UIKeyboardType = .asciiCapable

        public func insertText(_ text: String) {
            Task { @MainActor [weak self] in
                for char in text {
                    self?.onCharacter?(char)
                }
            }
        }

        public func deleteBackward() {
            Task { @MainActor [weak self] in
                self?.onDeleteBackward?()
            }
        }
    }
}

public struct InSessionView: View {
    public let profile: ConnectionProfile
    public var onDismiss: @MainActor () -> Void

    @State private var framebuffer = Framebuffer()
    private let client = VNCClient()
    @State private var sessionBridge: SessionClientBridge?
    private var settings = SettingsStore.shared
    @State private var activeModifiers: Set<MacKey> = []
    @State private var displayPreference: DisplayPreference
    @State private var pointerMode: PointerMode
    @State private var isTabletopConsoleEnabled: Bool
    @State private var isToolbarCollapsed: Bool = false
    @State private var isKeyboardActive: Bool = false
    @State private var tabletopCursor: CGPoint?
    @State private var connectionState: VNCConnectionState = .connecting
    @State private var errorMessage: String?
    @State private var pendingServerCutText: String?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    public init(profile: ConnectionProfile, onDismiss: @escaping @MainActor () -> Void) {
        self.profile = profile
        self.onDismiss = onDismiss
        _displayPreference = State(initialValue: profile.displayPreference)
        let preferredPointer = profile.pointerMode ?? SettingsStore.shared.defaultPointerMode
        _pointerMode = State(initialValue: preferredPointer)
        let shouldEnableTabletop = switch SettingsStore.shared.tabletopConsoleMode {
        case .alwaysSplitConsole:
            true
        case .alwaysFullCanvas, .auto:
            false
        }
        _isTabletopConsoleEnabled = State(initialValue: shouldEnableTabletop)
    }

    public var body: some View {
        GeometryReader { geometry in
            let mode = DeviceModeDetector.detectMode(
                horizontalSizeClass: horizontalSizeClass,
                verticalSizeClass: verticalSizeClass,
                screenSize: geometry.size
            )

            ZStack {
                Color.black.ignoresSafeArea()

                switch mode {
                case .mode1NormalPhone:
                    mode1Layout(geometry: geometry)
                case .mode2InnerDisplayOrPad:
                    mode2Layout(geometry: geometry)
                case .mode3DuoOuterScreen:
                    mode3Layout(geometry: geometry)
                }

                // Invisible software keyboard input responder
                SoftwareKeyboardResponder(
                    isActive: $isKeyboardActive,
                    onCharacter: handleTypedCharacter,
                    onDeleteBackward: handleBackspace
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .task {
            await startSession()
        }
        .onDisappear {
            Task { await client.disconnect() }
        }
        .alert("Connection Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                    onDismiss()
                }
            }
        )) {
            Button("OK", role: .cancel) { onDismiss() }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .alert(
            "Copy from Mac?",
            isPresented: Binding(
                get: { pendingServerCutText != nil },
                set: {
                    if !$0 {
                        pendingServerCutText = nil
                    }
                }
            )
        ) {
            // Pasteboard writes only on explicit tap; dismiss drops server text.
            Button("Copy") {
                if let text = pendingServerCutText {
                    UIPasteboard.general.string = text
                }
                pendingServerCutText = nil
            }
            Button("Dismiss", role: .cancel) {
                pendingServerCutText = nil
            }
        } message: {
            Text("The Mac copied text. Copy it to this device's clipboard?")
        }
    }

    /// Mode 1: Standard Phone — edge-to-edge canvas with unified collapsible floating dock.
    private func mode1Layout(geometry _: GeometryProxy) -> some View {
        ZStack(alignment: .bottom) {
            FramebufferView(
                framebuffer: framebuffer,
                displayPreference: displayPreference,
                pointerMode: pointerMode,
                onPointerEvent: handlePointerEvent,
                isInputDisabled: settings.viewOnly
            )
            .ignoresSafeArea()

            unifiedSessionDock
                .padding(.bottom, 12)
                .padding(.horizontal, 10)
        }
    }

    /// Mode 2: iPad or Duo Inner Screen — full canvas with optional tabletop console split.
    private func mode2Layout(geometry: GeometryProxy) -> some View {
        ZStack(alignment: .bottom) {
            if isTabletopConsoleEnabled, !settings.viewOnly {
                VStack(spacing: 0) {
                    FramebufferView(
                        framebuffer: framebuffer,
                        displayPreference: displayPreference,
                        pointerMode: pointerMode,
                        onPointerEvent: handlePointerEvent,
                        isInputDisabled: settings.viewOnly
                    )
                    .frame(height: geometry.size.height * 0.5)

                    Divider().background(Color.secondary)

                    TabletopConsoleView(
                        activeModifiers: $activeModifiers,
                        onPointerDelta: handlePointerDelta,
                        onPointerClick: handlePointerClick,
                        onKeyPress: handleKeyPress,
                        onSendShortcut: handleShortcut,
                        isInputDisabled: settings.viewOnly
                    )
                    .frame(height: geometry.size.height * 0.5)
                }
            } else {
                FramebufferView(
                    framebuffer: framebuffer,
                    displayPreference: displayPreference,
                    pointerMode: pointerMode,
                    onPointerEvent: handlePointerEvent,
                    isInputDisabled: settings.viewOnly
                )
                .ignoresSafeArea()

                unifiedSessionDock
                    .padding(.bottom, 16)
                    .padding(.horizontal, 16)
            }
        }
    }

    /// Mode 3: iPhone Duo Outer Screen — edge-to-edge canvas with thumb-accessible trailing rail.
    private func mode3Layout(geometry _: GeometryProxy) -> some View {
        ZStack(alignment: .trailing) {
            FramebufferView(
                framebuffer: framebuffer,
                displayPreference: displayPreference,
                pointerMode: pointerMode,
                onPointerEvent: handlePointerEvent,
                isInputDisabled: settings.viewOnly
            )
            .ignoresSafeArea()

            OuterScreenRailView(
                activeModifiers: $activeModifiers,
                isKeyboardActive: $isKeyboardActive,
                pointerMode: pointerMode,
                onTogglePointerMode: {
                    pointerMode = (pointerMode == .directTouch) ? .virtualTrackpad : .directTouch
                },
                onKeyPress: handleKeyPress,
                onSendShortcut: handleShortcut,
                onToggleDisplayPreference: toggleDisplayPreference,
                onDisconnect: onDismiss,
                isInputDisabled: settings.viewOnly
            )
            .padding(.trailing, 8)
        }
    }

    /// Unified floating control dock consolidating disconnect, keyboard, pointer, display mode, and keys.
    @ViewBuilder
    private var unifiedSessionDock: some View {
        if isToolbarCollapsed {
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        isToolbarCollapsed = false
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(radius: 6)
                }
            }
        } else {
            HStack(spacing: 8) {
                // Collapse toggle button
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        isToolbarCollapsed = true
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 36)
                }

                // Disconnect action
                SessionDisconnectButton(onDisconnect: onDismiss)

                Divider().frame(height: 22)

                // Software Keyboard Toggle
                SessionKeyboardToggleButton(
                    isKeyboardActive: isKeyboardActive,
                    isInputDisabled: settings.viewOnly
                ) {
                    isKeyboardActive.toggle()
                }

                // Mouse Mode Toggle
                SessionPointerModeButton(
                    pointerMode: pointerMode,
                    isInputDisabled: settings.viewOnly
                ) {
                    pointerMode = (pointerMode == .directTouch) ? .virtualTrackpad : .directTouch
                }

                // Display Mode Toggle
                SessionDisplayModeButton {
                    toggleDisplayPreference()
                }

                Divider().frame(height: 22)

                // Modifiers
                ForEach([MacKey.command, .option, .control, .shift]) { key in
                    SessionModifierButton(
                        key: key,
                        isActive: activeModifiers.contains(key),
                        isInputDisabled: settings.viewOnly
                    ) {
                        toggleStickyMacModifier(key, activeModifiers: &activeModifiers, onKeyPress: handleKeyPress)
                    }
                }

                Divider().frame(height: 22)

                // Mac Actions Menu
                SessionMacActionsMenu(
                    onSendShortcut: handleShortcut,
                    isInputDisabled: settings.viewOnly
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 6)
        }
    }

    private func toggleDisplayPreference() {
        switch displayPreference {
        case .fit: displayPreference = .actualSize
        case .actualSize: displayPreference = .fill
        case .fill: displayPreference = .fit
        }
    }

    private func startSession() async {
        if sessionBridge == nil {
            let stateBinding = $connectionState
            let errorBinding = $errorMessage
            let cutTextBinding = $pendingServerCutText
            sessionBridge = SessionClientBridge(
                framebuffer: framebuffer,
                onStateChange: { newState in
                    stateBinding.wrappedValue = newState
                    if case let .failed(message) = newState {
                        errorBinding.wrappedValue = message
                    }
                },
                onCutText: { text in
                    cutTextBinding.wrappedValue = text
                }
            )
        }
        if let bridge = sessionBridge {
            await client.setDelegate(bridge)
        }
        await client.setViewOnly(settings.viewOnly)
        let password = KeychainManager.shared.getPassword(for: profile.id)
        do {
            try await client.connect(profile: profile, password: password)
            ProfileStore.shared.updateLastConnected(for: profile.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handlePointerEvent(posX: Int, posY: Int, buttonMask: UInt8) {
        guard !settings.viewOnly else { return }
        Task { await client.sendPointerEvent(posX: posX, posY: posY, buttonMask: buttonMask) }
    }

    private func handlePointerDelta(deltaX: CGFloat, deltaY: CGFloat, buttonMask: UInt8) {
        guard !settings.viewOnly, framebuffer.width > 0, framebuffer.height > 0 else { return }
        // Incremental deltas accumulate onto persistent cursor; never snap to center.
        let base = tabletopCursor ?? CGPoint(
            x: CGFloat(framebuffer.width) / 2.0,
            y: CGFloat(framebuffer.height) / 2.0
        )
        let clampedX = max(0, min(base.x + deltaX, CGFloat(framebuffer.width - 1)))
        let clampedY = max(0, min(base.y + deltaY, CGFloat(framebuffer.height - 1)))
        tabletopCursor = CGPoint(x: clampedX, y: clampedY)
        Task { await client.sendPointerEvent(posX: Int(clampedX), posY: Int(clampedY), buttonMask: buttonMask) }
    }

    private func waitBriefly() async {
        do {
            try await Task.sleep(nanoseconds: 50_000_000)
        } catch is CancellationError {
        } catch {
            Logger(subsystem: "com.volcrypt.ScreenVNC", category: "InSessionView")
                .debug("waitBriefly interrupted: \(error.localizedDescription)")
        }
    }

    private func handlePointerClick(buttonMask: UInt8) {
        guard !settings.viewOnly, framebuffer.width > 0, framebuffer.height > 0 else { return }
        // Click at persistent cursor so trackpad position never snaps to center.
        let cursor = tabletopCursor ?? CGPoint(
            x: CGFloat(framebuffer.width) / 2.0,
            y: CGFloat(framebuffer.height) / 2.0
        )
        tabletopCursor = cursor
        let clickX = Int(cursor.x)
        let clickY = Int(cursor.y)
        Task {
            await client.sendPointerEvent(posX: clickX, posY: clickY, buttonMask: buttonMask)
            await waitBriefly()
            await client.sendPointerEvent(posX: clickX, posY: clickY, buttonMask: 0)
        }
    }

    private func handleKeyPress(key: UInt32, down: Bool) {
        guard !settings.viewOnly else { return }
        Task { await client.sendKeyEvent(key: key, down: down) }
    }

    private func handleTypedCharacter(_ char: Character) {
        guard !settings.viewOnly else { return }
        let key: UInt32
        if char == "\n" || char == "\r" {
            key = MacKey.return.rawValue
        } else if char == "\t" {
            key = MacKey.tab.rawValue
        } else if let scalar = char.unicodeScalars.first {
            key = UInt32(scalar.value)
        } else {
            return
        }
        Task {
            await client.sendKeyEvent(key: key, down: true)
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {}
            await client.sendKeyEvent(key: key, down: false)
        }
    }

    private func handleBackspace() {
        guard !settings.viewOnly else { return }
        Task {
            await client.sendKeyEvent(key: MacKey.backspace.rawValue, down: true)
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {}
            await client.sendKeyEvent(key: MacKey.backspace.rawValue, down: false)
        }
    }

    private func handleShortcut(_ name: String) {
        guard !settings.viewOnly else { return }
        Task {
            switch name {
            case "cmd_tab":
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: true)
                await client.sendKeyEvent(key: MacKey.tab.rawValue, down: true)
                await waitBriefly()
                await client.sendKeyEvent(key: MacKey.tab.rawValue, down: false)
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: false)
            case "spotlight":
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: true)
                await client.sendKeyEvent(key: 0x0020, down: true)
                await waitBriefly()
                await client.sendKeyEvent(key: 0x0020, down: false)
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: false)
            case "lock_mac":
                await client.sendKeyEvent(key: MacKey.control.rawValue, down: true)
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: true)
                await client.sendKeyEvent(key: 0x0071, down: true)
                await waitBriefly()
                await client.sendKeyEvent(key: 0x0071, down: false)
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: false)
                await client.sendKeyEvent(key: MacKey.control.rawValue, down: false)
            case "mission_control":
                await client.sendKeyEvent(key: MacKey.control.rawValue, down: true)
                await client.sendKeyEvent(key: MacKey.arrowUp.rawValue, down: true)
                await waitBriefly()
                await client.sendKeyEvent(key: MacKey.arrowUp.rawValue, down: false)
                await client.sendKeyEvent(key: MacKey.control.rawValue, down: false)
            case "close_window":
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: true)
                await client.sendKeyEvent(key: 0x0077, down: true)
                await waitBriefly()
                await client.sendKeyEvent(key: 0x0077, down: false)
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: false)
            case "quit_app":
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: true)
                await client.sendKeyEvent(key: 0x0071, down: true)
                await waitBriefly()
                await client.sendKeyEvent(key: 0x0071, down: false)
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: false)
            default:
                break
            }
        }
    }
}
