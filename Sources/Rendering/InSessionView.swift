// Rendering — Primary active remote desktop session viewer and mode adapter.
import os
import SwiftUI

/// Session delegate bridges actor callbacks onto MainActor framebuffer.
@MainActor
private final class SessionClientBridge: VNCClientDelegate {
    private let framebuffer: Framebuffer
    private let onStateChange: @MainActor (VNCConnectionState) -> Void

    init(framebuffer: Framebuffer, onStateChange: @escaping @MainActor (VNCConnectionState) -> Void) {
        self.framebuffer = framebuffer
        self.onStateChange = onStateChange
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

    func vncClient(_ _: VNCClient, didReceiveCutText _: String) {
        // Clipboard text ignored in this slice; kept for contract completeness.
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
    @State private var pointerMode: PointerMode = .directTouch
    @State private var isTabletopConsoleEnabled: Bool = false
    @State private var connectionState: VNCConnectionState = .connecting
    @State private var errorMessage: String?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    public init(profile: ConnectionProfile, onDismiss: @escaping @MainActor () -> Void) {
        self.profile = profile
        self.onDismiss = onDismiss
        _displayPreference = State(initialValue: profile.displayPreference)
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
            }
        }
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
                    errorMessage = nil; onDismiss()
                }
            }
        )) {
            Button("OK", role: .cancel) { onDismiss() }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    /// Mode 1: Standard Phone — fitted canvas with bottom floating auto-collapsible Mac bar.
    private func mode1Layout(geometry _: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            topSessionBar
            FramebufferView(
                framebuffer: framebuffer,
                displayPreference: displayPreference,
                pointerMode: pointerMode,
                onPointerEvent: handlePointerEvent,
                isInputDisabled: settings.viewOnly
            )
            if settings.viewOnly {
                // View-only banner replaces input bar.
                viewOnlyBanner
            } else {
                MacKeyboardBar(
                    activeModifiers: $activeModifiers,
                    onKeyPress: handleKeyPress,
                    onSendShortcut: handleShortcut
                )
            }
        }
    }

    /// Mode 2: iPad or Duo Inner Screen — expandable full canvas with toggleable tabletop split console.
    private func mode2Layout(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            topSessionBar

            if isTabletopConsoleEnabled, !settings.viewOnly {
                // Tabletop split console: upper remote display + lower virtual trackpad and keyboard.
                VStack(spacing: 0) {
                    FramebufferView(
                        framebuffer: framebuffer,
                        displayPreference: displayPreference,
                        pointerMode: .directTouch,
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
                    .frame(height: geometry.size.height * 0.5 - 50)
                }
            } else {
                // Full canvas mode: maximized remote desktop (ideal for Bluetooth keyboard/mouse or pencil).
                FramebufferView(
                    framebuffer: framebuffer,
                    displayPreference: displayPreference,
                    pointerMode: pointerMode,
                    onPointerEvent: handlePointerEvent,
                    isInputDisabled: settings.viewOnly
                )
                if settings.viewOnly {
                    // View-only banner replaces input bar.
                    viewOnlyBanner
                }
            }
        }
    }

    /// Mode 3: iPhone Duo Outer Screen — trailing vertical control rail per Apple HIG.
    private func mode3Layout(geometry _: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            FramebufferView(
                framebuffer: framebuffer,
                displayPreference: displayPreference,
                pointerMode: pointerMode,
                onPointerEvent: handlePointerEvent,
                isInputDisabled: settings.viewOnly
            )

            // Trailing edge vertical rail placed within thumb reach and respecting safe areas.
            OuterScreenRailView(
                activeModifiers: $activeModifiers,
                onKeyPress: handleKeyPress,
                onSendShortcut: handleShortcut,
                onToggleDisplayPreference: toggleDisplayPreference,
                onDisconnect: onDismiss,
                isInputDisabled: settings.viewOnly
            )
            .padding(.trailing, 6)
        }
    }

    /// View-only indicator shown when input is disabled.
    private var viewOnlyBanner: some View {
        Label("View Only — Input Disabled", systemImage: "eye.fill")
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
    }

    private var topSessionBar: some View {
        HStack {
            Button(role: .destructive) {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text(profile.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            if connectionState == .connecting || connectionState == .authenticating {
                // Live session state drives progress; no state loss on rotation.
                ProgressView()
                    .tint(.white)
            }

            if settings.viewOnly {
                // Fail-closed indicator when input is disabled.
                Label("View Only", systemImage: "eye.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            // Mode 2 Tabletop Console Toggle
            if horizontalSizeClass == .regular, verticalSizeClass == .regular, !settings.viewOnly {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isTabletopConsoleEnabled.toggle()
                    }
                } label: {
                    Label(
                        isTabletopConsoleEnabled ? "Full Canvas" : "Tabletop Console",
                        systemImage: isTabletopConsoleEnabled ? "arrow.up.left.and.arrow.down.right" : "laptopcomputer"
                    )
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.2))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
            }

            // Pointer Mode Switcher
            Button {
                pointerMode = (pointerMode == .directTouch) ? .virtualTrackpad : .directTouch
            } label: {
                Image(systemName: pointerMode == .directTouch ? "hand.point.up.fill" : "cursorarrow.rays")
                    .font(.body)
                    .foregroundStyle(.white)
            }
            .disabled(settings.viewOnly)
            .opacity(settings.viewOnly ? 0.4 : 1.0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.85))
    }

    private func toggleDisplayPreference() {
        switch displayPreference {
        case .fit: displayPreference = .actualSize
        case .actualSize: displayPreference = .fill
        case .fill: displayPreference = .fit
        }
    }

    private func startSession() async {
        // Wire actor delegate to MainActor framebuffer; retains bridge for session lifetime.
        if sessionBridge == nil {
            let stateBinding = $connectionState
            let errorBinding = $errorMessage
            sessionBridge = SessionClientBridge(framebuffer: framebuffer) { newState in
                stateBinding.wrappedValue = newState
                if case let .failed(message) = newState {
                    errorBinding.wrappedValue = message
                }
            }
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
        // Fail closed when view-only is enabled.
        guard !settings.viewOnly else { return }
        Task { await client.sendPointerEvent(posX: posX, posY: posY, buttonMask: buttonMask) }
    }

    private func handlePointerDelta(deltaX: CGFloat, deltaY: CGFloat, buttonMask: UInt8) {
        // Fail closed when view-only is enabled.
        guard !settings.viewOnly else { return }
        let newX = max(0, min(Int(CGFloat(framebuffer.width) / 2.0 + deltaX), framebuffer.width - 1))
        let newY = max(0, min(Int(CGFloat(framebuffer.height) / 2.0 + deltaY), framebuffer.height - 1))
        Task { await client.sendPointerEvent(posX: newX, posY: newY, buttonMask: buttonMask) }
    }

    private func waitBriefly() async {
        do {
            try await Task.sleep(nanoseconds: 50_000_000)
        } catch is CancellationError {
            // Task was cancelled; honor cooperative cancellation
        } catch {
            Logger(subsystem: "com.volcrypt.ScreenVNC", category: "InSessionView")
                .debug("waitBriefly interrupted: \(error.localizedDescription)")
        }
    }

    private func handlePointerClick(buttonMask: UInt8) {
        // Fail closed when view-only is enabled.
        guard !settings.viewOnly else { return }
        let midX = framebuffer.width / 2
        let midY = framebuffer.height / 2
        Task {
            await client.sendPointerEvent(posX: midX, posY: midY, buttonMask: buttonMask)
            await waitBriefly()
            await client.sendPointerEvent(posX: midX, posY: midY, buttonMask: 0)
        }
    }

    private func handleKeyPress(key: UInt32, down: Bool) {
        // Fail closed when view-only is enabled.
        guard !settings.viewOnly else { return }
        Task { await client.sendKeyEvent(key: key, down: down) }
    }

    private func handleShortcut(_ name: String) {
        // Fail closed when view-only is enabled.
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
                await client.sendKeyEvent(key: 0x0020, down: true) // Space
                await waitBriefly()
                await client.sendKeyEvent(key: 0x0020, down: false)
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: false)
            case "lock_mac":
                await client.sendKeyEvent(key: MacKey.control.rawValue, down: true)
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: true)
                await client.sendKeyEvent(key: 0x0071, down: true) // 'q'
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
                await client.sendKeyEvent(key: 0x0077, down: true) // 'w'
                await waitBriefly()
                await client.sendKeyEvent(key: 0x0077, down: false)
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: false)
            case "quit_app":
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: true)
                await client.sendKeyEvent(key: 0x0071, down: true) // 'q'
                await waitBriefly()
                await client.sendKeyEvent(key: 0x0071, down: false)
                await client.sendKeyEvent(key: MacKey.command.rawValue, down: false)
            default:
                break
            }
        }
    }
}
