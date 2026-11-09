// Rendering — Primary active remote desktop session viewer and mode adapter.
import os
import SwiftUI
import UIKit

/// Session delegate bridges actor callbacks onto MainActor framebuffer.
@MainActor
private final class SessionClientBridge: VNCClientDelegate {
    private let framebuffer: Framebuffer
    private let onStateChange: @MainActor (VNCConnectionState) -> Void
    private let onResize: @MainActor (Int, Int) -> Void
    private let onCutText: @MainActor (String) -> Void

    init(
        framebuffer: Framebuffer,
        onStateChange: @escaping @MainActor (VNCConnectionState) -> Void,
        onResize: @escaping @MainActor (Int, Int) -> Void,
        onCutText: @escaping @MainActor (String) -> Void
    ) {
        self.framebuffer = framebuffer
        self.onStateChange = onStateChange
        self.onResize = onResize
        self.onCutText = onCutText
    }

    func vncClient(_ _: VNCClient, didUpdateState state: VNCConnectionState) {
        onStateChange(state)
    }

    func vncClient(_ _: VNCClient, didResizeDesktopWidth width: Int, height: Int) {
        framebuffer.resize(width: width, height: height)
        onResize(width, height)
    }

    func vncClient(_ _: VNCClient, didReceiveRawRect rect: DecodedRect) {
        framebuffer.applyRawRect(rect)
    }

    func vncClient(_ _: VNCClient, didReceiveCopyRect dest: DecodedRect, srcX: Int, srcY: Int) {
        framebuffer.applyCopyRect(dest: dest, srcX: srcX, srcY: srcY)
    }

    func vncClient(_ _: VNCClient, didReceiveUpdateBatch ops: [FramebufferUpdateOp]) {
        framebuffer.applyUpdateBatch(ops)
    }

    func vncClient(_ _: VNCClient, didUpdateCursor cursor: DecodedCursor?) {
        framebuffer.updateCursor(cursor)
    }

    func vncClient(_ _: VNCClient, didReceiveCutText text: String) {
        // Stage server text for explicit user consent; never touch pasteboard here.
        onCutText(text)
    }
}

/// Transparent view bridging software and external hardware keyboards to remote VNC key events.
public struct SoftwareKeyboardResponder: UIViewRepresentable {
    @Binding public var isActive: Bool
    public var onCharacter: @MainActor (Character) -> Void
    public var onDeleteBackward: @MainActor () -> Void
    public var onHardwareKey: (@MainActor (UInt32, Bool) -> Void)?
    public var onWindowSafeAreaChange: (@MainActor (EdgeInsets) -> Void)?

    public init(
        isActive: Binding<Bool>,
        onCharacter: @escaping @MainActor (Character) -> Void,
        onDeleteBackward: @escaping @MainActor () -> Void,
        onHardwareKey: (@MainActor (UInt32, Bool) -> Void)? = nil,
        onWindowSafeAreaChange: (@MainActor (EdgeInsets) -> Void)? = nil
    ) {
        _isActive = isActive
        self.onCharacter = onCharacter
        self.onDeleteBackward = onDeleteBackward
        self.onHardwareKey = onHardwareKey
        self.onWindowSafeAreaChange = onWindowSafeAreaChange
    }

    public func makeUIView(context _: Context) -> KeyInputView {
        let view = KeyInputView()
        view.onCharacter = onCharacter
        view.onDeleteBackward = onDeleteBackward
        view.onHardwareKey = onHardwareKey
        view.onWindowSafeAreaChange = onWindowSafeAreaChange
        return view
    }

    public func updateUIView(_ uiView: KeyInputView, context _: Context) {
        uiView.onCharacter = onCharacter
        uiView.onDeleteBackward = onDeleteBackward
        uiView.onHardwareKey = onHardwareKey
        uiView.onWindowSafeAreaChange = onWindowSafeAreaChange
        uiView.publishWindowSafeAreaIfNeeded()
        if isActive, !uiView.isFirstResponder {
            Task { uiView.becomeFirstResponder() }
        } else if !isActive, uiView.isFirstResponder {
            Task { uiView.resignFirstResponder() }
        }
    }

    @MainActor
    public final class KeyInputView: UIView, UIKeyInput {
        public var hasText: Bool {
            true
        }

        var onCharacter: (@MainActor (Character) -> Void)?
        var onDeleteBackward: (@MainActor () -> Void)?
        var onHardwareKey: (@MainActor (UInt32, Bool) -> Void)?
        var onWindowSafeAreaChange: (@MainActor (EdgeInsets) -> Void)?
        private var lastPublishedSafeInsets = EdgeInsets()

        override public var canBecomeFirstResponder: Bool {
            true
        }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            publishWindowSafeAreaIfNeeded()
        }

        override public func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            publishWindowSafeAreaIfNeeded()
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            publishWindowSafeAreaIfNeeded()
        }

        func publishWindowSafeAreaIfNeeded() {
            guard let window else { return }
            let raw = window.safeAreaInsets
            let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let converted = EdgeInsets(
                top: raw.top,
                leading: isRTL ? raw.right : raw.left,
                bottom: raw.bottom,
                trailing: isRTL ? raw.left : raw.right
            )
            guard converted != lastPublishedSafeInsets else { return }
            lastPublishedSafeInsets = converted
            Task {
                onWindowSafeAreaChange?(converted)
            }
        }

        public var autocorrectionType: UITextAutocorrectionType = .no
        public var autocapitalizationType: UITextAutocapitalizationType = .none
        public var smartQuotesType: UITextSmartQuotesType = .no
        public var smartDashesType: UITextSmartDashesType = .no
        public var keyboardType: UIKeyboardType = .asciiCapable

        public func insertText(_ text: String) {
            for char in text {
                onCharacter?(char)
            }
        }

        public func deleteBackward() {
            onDeleteBackward?()
        }

        override public func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handledAll = true
            for press in presses {
                guard let key = press.key else {
                    handledAll = false
                    continue
                }
                if let keysym = mappedKeysym(for: key, isDown: true) {
                    onHardwareKey?(keysym, true)
                } else {
                    handledAll = false
                }
            }
            if !handledAll {
                super.pressesBegan(presses, with: event)
            }
        }

        override public func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handledAll = true
            for press in presses {
                guard let key = press.key else {
                    handledAll = false
                    continue
                }
                if let keysym = mappedKeysym(for: key, isDown: false) {
                    onHardwareKey?(keysym, false)
                } else {
                    handledAll = false
                }
            }
            if !handledAll {
                super.pressesEnded(presses, with: event)
            }
        }

        private static let hidKeysymMap: [UIKeyboardHIDUsage: UInt32] = [
            .keyboardUpArrow: MacKey.arrowUp.rawValue,
            .keyboardDownArrow: MacKey.arrowDown.rawValue,
            .keyboardLeftArrow: MacKey.arrowLeft.rawValue,
            .keyboardRightArrow: MacKey.arrowRight.rawValue,
            .keyboardEscape: MacKey.escape.rawValue,
            .keyboardTab: MacKey.tab.rawValue,
            .keyboardReturnOrEnter: MacKey.return.rawValue,
            .keypadEnter: MacKey.return.rawValue,
            .keyboardDeleteOrBackspace: MacKey.backspace.rawValue,
            .keyboardDeleteForward: 0xFFFF,
            .keyboardHome: 0xFF50,
            .keyboardEnd: 0xFF57,
            .keyboardPageUp: 0xFF55,
            .keyboardPageDown: 0xFF56,
            .keyboardF1: 0xFFBE,
            .keyboardF2: 0xFFBF,
            .keyboardF3: 0xFFC0,
            .keyboardF4: 0xFFC1,
            .keyboardF5: 0xFFC2,
            .keyboardF6: 0xFFC3,
            .keyboardF7: 0xFFC4,
            .keyboardF8: 0xFFC5,
            .keyboardF9: 0xFFC6,
            .keyboardF10: 0xFFC7,
            .keyboardF11: 0xFFC8,
            .keyboardF12: 0xFFC9,
            .keyboardLeftGUI: MacKey.command.rawValue,
            .keyboardRightGUI: MacKey.command.rawValue,
            .keyboardLeftAlt: MacKey.option.rawValue,
            .keyboardRightAlt: MacKey.option.rawValue,
            .keyboardLeftControl: MacKey.control.rawValue,
            .keyboardRightControl: MacKey.control.rawValue,
            .keyboardLeftShift: MacKey.shift.rawValue,
            .keyboardRightShift: MacKey.shift.rawValue
        ]

        private func mappedKeysym(for key: UIKey, isDown _: Bool) -> UInt32? {
            if let mapped = Self.hidKeysymMap[key.keyCode] {
                return mapped
            }

            // Route Command/Control/Option shortcuts directly; plain characters flow via insertText.
            let nonShiftModifiers: UIKeyModifierFlags = [.command, .control, .alternate]
            if !key.modifierFlags.isDisjoint(with: nonShiftModifiers),
               let scalar = key.charactersIgnoringModifiers.unicodeScalars.first
            {
                return scalar.value <= 0xFF ? UInt32(scalar.value) : (0x0100_0000 | UInt32(scalar.value))
            }
            return nil
        }
    }
}

public struct InSessionView: View {
    public let profile: ConnectionProfile
    public var onDismiss: @MainActor () -> Void

    @State private var framebuffer = Framebuffer()
    @State private var client = VNCClient()
    @State private var inputPipeline = VNCInputPipeline()
    @State private var sessionBridge: SessionClientBridge?
    private var settings = SettingsStore.shared
    @State private var activeModifiers: Set<MacKey> = []
    @State private var displayPreference: DisplayPreference
    @State private var pointerMode: PointerMode
    @State private var isTabletopConsoleEnabled: Bool
    @State private var isToolbarCollapsed: Bool = false
    @State private var isKeyboardActive: Bool = false
    @State private var isShowingGestureGuide: Bool = false
    @State private var zoomResetTrigger: Int = 0
    @State private var windowSafeInsets = EdgeInsets()
    @State private var sharedCursor: CGPoint = .init(x: 960, y: 540)
    @State private var tabletopScrollAccumulator = ScrollAccumulator()
    @State private var connectionState: VNCConnectionState = .connecting
    @State private var errorMessage: String?
    @State private var pendingServerCutText: String?
    @State private var isAwaitingPlaintextConsent = false
    @State private var sessionTask: Task<Void, Never>?

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

                // Invisible software & hardware keyboard input responder
                SoftwareKeyboardResponder(
                    isActive: $isKeyboardActive,
                    onCharacter: handleTypedCharacter,
                    onDeleteBackward: handleBackspace,
                    onHardwareKey: handleKeyPress,
                    onWindowSafeAreaChange: { windowSafeInsets = $0 }
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .task {
            // Plaintext VNC-DES beyond loopback dials only after explicit user consent.
            if profile.requiresPlaintextConsent {
                isAwaitingPlaintextConsent = true
            } else {
                await runSessionTasks()
            }
        }
        .onDisappear {
            // Cancel the consent-path handle so its task group unwinds with the view.
            sessionTask?.cancel()
            Task { await client.disconnect() }
        }
        .alert(
            "Unencrypted Connection",
            isPresented: $isAwaitingPlaintextConsent
        ) {
            Button("Always Allow", role: .destructive) {
                var updated = profile
                updated.allowUnencryptedSession = true
                ProfileStore.shared.save(updated)
                sessionTask = Task {
                    await startSessionAfterConsentDismissal()
                }
            }
            Button("Continue Once") {
                sessionTask = Task {
                    await startSessionAfterConsentDismissal()
                }
            }
            Button("Cancel", role: .cancel) {
                onDismiss()
            }
        } message: {
            Text("\(profile.name) uses a password exchange that a network observer can crack offline. This session will not be encrypted. Continue?")
        }
        .sheet(isPresented: $isShowingGestureGuide) {
            GestureGuideView()
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

    private func effectiveSafeInsets(for geometry: GeometryProxy) -> EdgeInsets {
        EdgeInsets(
            top: max(geometry.safeAreaInsets.top, windowSafeInsets.top),
            leading: max(geometry.safeAreaInsets.leading, windowSafeInsets.leading),
            bottom: max(geometry.safeAreaInsets.bottom, windowSafeInsets.bottom),
            trailing: max(geometry.safeAreaInsets.trailing, windowSafeInsets.trailing)
        )
    }

    /// Mode 1: Standard Phone — edge-to-edge canvas with unified collapsible floating dock.
    private func mode1Layout(geometry: GeometryProxy) -> some View {
        let safe = effectiveSafeInsets(for: geometry)
        let bottomClearance = safe.bottom + (isToolbarCollapsed ? 60 : 84)
        let insets = EdgeInsets(
            top: safe.top,
            leading: safe.leading,
            bottom: bottomClearance,
            trailing: safe.trailing
        )
        return ZStack(alignment: .bottom) {
            FramebufferView(
                framebuffer: framebuffer,
                displayPreference: displayPreference,
                pointerMode: pointerMode,
                sharedCursor: $sharedCursor,
                panInsets: insets,
                resetTrigger: zoomResetTrigger,
                onPointerEvent: handlePointerEvent,
                onInputCommand: enqueueInput,
                onFlushMoves: { inputPipeline.flushPendingMove() },
                isInputDisabled: settings.viewOnly
            )
            .ignoresSafeArea()

            unifiedSessionDock
                .padding(.bottom, max(safe.bottom, 12))
                .padding(.horizontal, 10)
        }
    }

    /// Mode 2: iPad or Duo Inner Screen — full canvas with optional tabletop console split.
    private func mode2Layout(geometry: GeometryProxy) -> some View {
        let safe = effectiveSafeInsets(for: geometry)
        let bottomClearance = safe.bottom + (isToolbarCollapsed ? 64 : 88)
        let insets = EdgeInsets(
            top: safe.top,
            leading: safe.leading,
            bottom: bottomClearance,
            trailing: safe.trailing
        )
        return ZStack(alignment: .bottom) {
            if isTabletopConsoleEnabled, !settings.viewOnly {
                VStack(spacing: 0) {
                    FramebufferView(
                        framebuffer: framebuffer,
                        displayPreference: displayPreference,
                        pointerMode: pointerMode,
                        sharedCursor: $sharedCursor,
                        resetTrigger: zoomResetTrigger,
                        onPointerEvent: handlePointerEvent,
                        onInputCommand: enqueueInput,
                        onFlushMoves: { inputPipeline.flushPendingMove() },
                        isInputDisabled: settings.viewOnly
                    )
                    .frame(height: geometry.size.height * 0.5)

                    Divider().background(Color.secondary)

                    TabletopConsoleView(
                        activeModifiers: $activeModifiers,
                        onPointerDelta: handlePointerDelta,
                        onPointerClick: handlePointerClick,
                        onPointerScroll: handleTabletopScroll,
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
                    sharedCursor: $sharedCursor,
                    panInsets: insets,
                    resetTrigger: zoomResetTrigger,
                    onPointerEvent: handlePointerEvent,
                    onInputCommand: enqueueInput,
                    onFlushMoves: { inputPipeline.flushPendingMove() },
                    isInputDisabled: settings.viewOnly
                )
                .ignoresSafeArea()

                unifiedSessionDock
                    .padding(.bottom, max(safe.bottom, 16))
                    .padding(.horizontal, 16)
            }
        }
    }

    /// Mode 3: iPhone Duo Outer Screen — edge-to-edge canvas with thumb-accessible trailing rail.
    private func mode3Layout(geometry: GeometryProxy) -> some View {
        let safe = effectiveSafeInsets(for: geometry)
        let insets = EdgeInsets(
            top: safe.top,
            leading: safe.leading,
            bottom: safe.bottom,
            trailing: safe.trailing + 64
        )
        return ZStack(alignment: .trailing) {
            FramebufferView(
                framebuffer: framebuffer,
                displayPreference: displayPreference,
                pointerMode: pointerMode,
                sharedCursor: $sharedCursor,
                panInsets: insets,
                resetTrigger: zoomResetTrigger,
                onPointerEvent: handlePointerEvent,
                onInputCommand: enqueueInput,
                onFlushMoves: { inputPipeline.flushPendingMove() },
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
                onResetZoom: { zoomResetTrigger += 1 },
                onShowGestureGuide: { isShowingGestureGuide = true },
                isInputDisabled: settings.viewOnly
            )
            .padding(.trailing, max(safe.trailing, 8))
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
                    onResetZoom: { zoomResetTrigger += 1 },
                    onShowGestureGuide: { isShowingGestureGuide = true },
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

    /// Waits for UIKit to finish dismissing the consent alert before dialing so any
    /// immediate connection failure alert is never dropped during transition.
    private func startSessionAfterConsentDismissal() async {
        do {
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            return
        }
        await runSessionTasks()
    }

    /// Runs the input pipeline and session dial concurrently, exactly as the prior `.task` group did.
    private func runSessionTasks() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await inputPipeline.run(client: client)
            }
            group.addTask {
                await startSession()
            }
            await group.waitForAll()
        }
    }

    private func startSession() async {
        if sessionBridge == nil {
            let stateBinding = $connectionState
            let errorBinding = $errorMessage
            let cutTextBinding = $pendingServerCutText
            let cursorBinding = $sharedCursor
            sessionBridge = SessionClientBridge(
                framebuffer: framebuffer,
                onStateChange: { newState in
                    stateBinding.wrappedValue = newState
                    if case let .failed(message) = newState {
                        errorBinding.wrappedValue = message
                    }
                },
                onResize: { width, height in
                    cursorBinding.wrappedValue = CGPoint(
                        x: CGFloat(max(width, 1)) / 2.0,
                        y: CGFloat(max(height, 1)) / 2.0
                    )
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
            HostReachabilityService.shared.recordStatus(.online, for: profile.id)
        } catch is CancellationError {
            return
        } catch {
            HostReachabilityService.shared.recordStatus(.offline, for: profile.id)
            errorMessage = error.localizedDescription
        }
    }

    private func enqueueInput(_ command: VNCInputCommand) {
        // Releases bypass view-only so disabling input mid-drag cannot latch the remote button.
        if case .pointerUp = command {
            inputPipeline.enqueue(command)
            return
        }
        guard !settings.viewOnly else { return }
        inputPipeline.enqueue(command)
    }

    private func handlePointerEvent(posX: Int, posY: Int, buttonMask: UInt8) {
        guard !settings.viewOnly else { return }
        inputPipeline.enqueue(.pointerMove(posX: posX, posY: posY, buttonMask: buttonMask))
    }

    private func handlePointerDelta(deltaX: CGFloat, deltaY: CGFloat, buttonMask: UInt8) {
        guard !settings.viewOnly, framebuffer.width > 0, framebuffer.height > 0 else { return }
        let clampedX = max(0, min(sharedCursor.x + deltaX, CGFloat(framebuffer.width - 1)))
        let clampedY = max(0, min(sharedCursor.y + deltaY, CGFloat(framebuffer.height - 1)))
        sharedCursor = CGPoint(x: clampedX, y: clampedY)
        framebuffer.cursorPosition = sharedCursor
        inputPipeline.enqueue(.pointerMove(posX: Int(clampedX), posY: Int(clampedY), buttonMask: buttonMask))
    }

    private func handlePointerClick(buttonMask: UInt8) {
        guard !settings.viewOnly, framebuffer.width > 0, framebuffer.height > 0 else { return }
        inputPipeline.enqueue(.click(posX: Int(sharedCursor.x), posY: Int(sharedCursor.y), buttonMask: buttonMask))
    }

    private func handleTabletopScroll(delta: CGSize) {
        guard !settings.viewOnly else { return }
        let steps = tabletopScrollAccumulator.consume(
            deltaX: delta.width,
            deltaY: delta.height,
            naturalScrolling: settings.naturalScrolling
        )
        guard steps.stepsX != 0 || steps.stepsY != 0 else { return }
        inputPipeline.enqueue(.scroll(
            posX: Int(sharedCursor.x),
            posY: Int(sharedCursor.y),
            stepsX: steps.stepsX,
            stepsY: steps.stepsY,
            activeButtons: 0
        ))
    }

    private func handleKeyPress(key: UInt32, down: Bool) {
        guard !settings.viewOnly else { return }
        inputPipeline.enqueue(.keyEvent(key: key, down: down))
    }

    private func handleTypedCharacter(_ char: Character) {
        guard !settings.viewOnly else { return }
        let key: UInt32
        if char == "\n" || char == "\r" {
            key = MacKey.return.rawValue
        } else if char == "\t" {
            key = MacKey.tab.rawValue
        } else if let scalar = char.unicodeScalars.first {
            key = scalar.value <= 0xFF ? UInt32(scalar.value) : (0x0100_0000 | UInt32(scalar.value))
        } else {
            return
        }
        inputPipeline.enqueue(.keyTap(key: key))
    }

    private func handleBackspace() {
        guard !settings.viewOnly else { return }
        inputPipeline.enqueue(.keyTap(key: MacKey.backspace.rawValue))
    }

    private func handleShortcut(_ name: String) {
        guard !settings.viewOnly else { return }
        switch name {
        case "cmd_tab":
            inputPipeline.enqueue(.keyChord(keys: [MacKey.command.rawValue, MacKey.tab.rawValue]))
        case "spotlight":
            inputPipeline.enqueue(.keyChord(keys: [MacKey.command.rawValue, 0x0020]))
        case "lock_mac":
            inputPipeline.enqueue(.keyChord(keys: [MacKey.control.rawValue, MacKey.command.rawValue, 0x0071]))
        case "mission_control":
            inputPipeline.enqueue(.keyChord(keys: [MacKey.control.rawValue, MacKey.arrowUp.rawValue]))
        case "close_window":
            inputPipeline.enqueue(.keyChord(keys: [MacKey.command.rawValue, 0x0077]))
        case "quit_app":
            inputPipeline.enqueue(.keyChord(keys: [MacKey.command.rawValue, 0x0071]))
        default:
            break
        }
    }
}
