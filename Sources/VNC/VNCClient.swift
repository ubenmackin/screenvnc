// VNC — Actor-isolated RFB protocol client for macOS Screen Sharing.
import Foundation
import Network

public enum VNCConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case failed(String)
}

@MainActor
public protocol VNCClientDelegate: AnyObject, Sendable {
    func vncClient(_ client: VNCClient, didUpdateState state: VNCConnectionState)
    func vncClient(_ client: VNCClient, didResizeDesktopWidth width: Int, height: Int)
    func vncClient(_ client: VNCClient, didReceiveRawRect rect: DecodedRect)
    func vncClient(_ client: VNCClient, didReceiveCopyRect dest: DecodedRect, srcX: Int, srcY: Int)
    func vncClient(_ client: VNCClient, didReceiveUpdateBatch ops: [FramebufferUpdateOp])
    func vncClient(_ client: VNCClient, didUpdateCursor cursor: DecodedCursor?)
    func vncClient(_ client: VNCClient, didReceiveCutText text: String)
}

public extension VNCClientDelegate {
    func vncClient(_ client: VNCClient, didReceiveUpdateBatch ops: [FramebufferUpdateOp]) {
        for op in ops {
            switch op {
            case let .raw(rect):
                vncClient(client, didReceiveRawRect: rect)
            case let .copy(dest, srcX, srcY):
                vncClient(client, didReceiveCopyRect: dest, srcX: srcX, srcY: srcY)
            }
        }
    }

    func vncClient(_: VNCClient, didUpdateCursor _: DecodedCursor?) {}
}

public actor VNCClient {
    public private(set) var state: VNCConnectionState = .disconnected
    public internal(set) var desktopWidth: Int = 1920
    public internal(set) var desktopHeight: Int = 1080
    public internal(set) var desktopName: String = "macOS"

    var connection: NWConnection?
    weak var delegate: VNCClientDelegate?
    private var isRunning: Bool = false
    /// View-only blocks outbound input; set per session from viewer prefs.
    public var isViewOnly: Bool = false

    public init(delegate: VNCClientDelegate? = nil) {
        self.delegate = delegate
    }

    public func setDelegate(_ delegate: VNCClientDelegate?) {
        self.delegate = delegate
    }

    /// Updates view-only mode; when true, presses and key sends drop while releases pass.
    public func setViewOnly(_ value: Bool) {
        isViewOnly = value
    }

    /// Ceiling for server-supplied failure text admitted into display or logs.
    static let maxWireReasonLength = 256

    /// Bounds server-supplied failure text and keeps only single-scalar printable
    /// ASCII, so hostile control bytes or oversized payloads never reach UI or logs.
    static func sanitizedWireReason(from data: Data) -> String {
        // Failable decode drops invalid UTF-8 entirely rather than lossy-substituting;
        // hostile binary payloads fail closed to the fallback reason.
        guard let bounded = String(data: data.prefix(maxWireReasonLength), encoding: .utf8) else {
            return "Unreadable server failure reason."
        }
        let printable = bounded.filter { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
            return (0x20 ... 0x7E).contains(scalar.value)
        }
        return printable.isEmpty ? "Unreadable server failure reason." : printable
    }

    /// Applies the wire-reason bound to any error body before it enters user-visible state.
    static func sanitizedFailureMessage(for error: Error) -> String {
        guard let authError = error as? VNCAuthError,
              case let .authenticationRejected(reason) = authError
        else {
            return error.localizedDescription
        }
        return sanitizedWireReason(from: Data(reason.utf8))
    }

    /// Connects to a remote host and executes the RFB protocol handshake.
    public func connect(profile: ConnectionProfile, password: String?) async throws {
        try profile.validate()
        await updateState(.connecting)

        let host = NWEndpoint.Host(profile.host)
        guard let port = NWEndpoint.Port(rawValue: UInt16(profile.port)) else {
            let errorMsg = "Invalid port \(profile.port)"
            await updateState(.failed(errorMsg))
            throw ProfileValidationError.invalidPort(profile.port)
        }

        let tcpParams = NWParameters.tcp
        let conn = NWConnection(host: host, port: port, using: tcpParams)
        connection = conn

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                conn.stateUpdateHandler = { newState in
                    switch newState {
                    case .ready:
                        conn.stateUpdateHandler = nil
                        continuation.resume()
                    case let .failed(error):
                        conn.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        conn.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                conn.start(queue: .global())
            }
        } onCancel: {
            conn.cancel()
        }

        try await executeHandshake(profile: profile, password: password)
        isRunning = true
        await updateState(.connected)

        Task {
            await self.startReceiveLoop()
        }
    }

    public func disconnect() async {
        isRunning = false
        connection?.cancel()
        connection = nil
        await updateState(.disconnected)
    }

    /// Sends mouse pointer coordinates and button state (RFC 6143 Section 7.5.5).
    public func sendPointerEvent(posX: Int, posY: Int, buttonMask: UInt8) {
        // View-only drops presses but passes releases so a mid-drag toggle cannot latch buttons.
        if buttonMask != 0 {
            guard !isViewOnly else { return }
        }
        guard state == .connected, let connection else { return }
        // Clamp to desktop bounds; prevents negative wrap through UInt8 truncation.
        let clampedX = min(max(posX, 0), max(desktopWidth - 1, 0))
        let clampedY = min(max(posY, 0), max(desktopHeight - 1, 0))
        let packet = Data([
            RFBConstants.ClientMessage.pointerEvent.rawValue,
            buttonMask,
            UInt8((clampedX >> 8) & 0xFF),
            UInt8(clampedX & 0xFF),
            UInt8((clampedY >> 8) & 0xFF),
            UInt8(clampedY & 0xFF)
        ])

        connection.send(content: packet, completion: .contentProcessed { _ in })
        if buttonMask != 0 {
            requestFramebufferUpdate(incremental: true)
        }
    }

    /// Emits vertical (4/5) and horizontal (6/7) scroll wheel pulses (positive = up/left).
    public func sendScrollEvent(
        posX: Int,
        posY: Int,
        deltaStepsX: Int,
        deltaStepsY: Int,
        activeButtons: UInt8 = 0
    ) {
        guard !isViewOnly, state == .connected, let connection else { return }
        let clampedX = min(max(posX, 0), max(desktopWidth - 1, 0))
        let clampedY = min(max(posY, 0), max(desktopHeight - 1, 0))
        let clampedStepsY = min(max(deltaStepsY, -12), 12)
        let clampedStepsX = min(max(deltaStepsX, -12), 12)
        guard clampedStepsX != 0 || clampedStepsY != 0 else { return }

        let highX = UInt8((clampedX >> 8) & 0xFF)
        let lowX = UInt8(clampedX & 0xFF)
        let highY = UInt8((clampedY >> 8) & 0xFF)
        let lowY = UInt8(clampedY & 0xFF)

        var packets = Data()
        let verticalButton: UInt8 = clampedStepsY > 0
            ? RFBConstants.PointerButton.scrollUp.rawValue
            : RFBConstants.PointerButton.scrollDown.rawValue
        for _ in 0 ..< abs(clampedStepsY) {
            packets.append(contentsOf: [
                RFBConstants.ClientMessage.pointerEvent.rawValue,
                activeButtons | verticalButton,
                highX, lowX, highY, lowY
            ])
            packets.append(contentsOf: [
                RFBConstants.ClientMessage.pointerEvent.rawValue,
                activeButtons,
                highX, lowX, highY, lowY
            ])
        }

        let horizontalButton: UInt8 = clampedStepsX > 0
            ? RFBConstants.PointerButton.scrollLeft.rawValue
            : RFBConstants.PointerButton.scrollRight.rawValue
        for _ in 0 ..< abs(clampedStepsX) {
            packets.append(contentsOf: [
                RFBConstants.ClientMessage.pointerEvent.rawValue,
                activeButtons | horizontalButton,
                highX, lowX, highY, lowY
            ])
            packets.append(contentsOf: [
                RFBConstants.ClientMessage.pointerEvent.rawValue,
                activeButtons,
                highX, lowX, highY, lowY
            ])
        }

        connection.send(content: packets, completion: .contentProcessed { _ in })
        requestFramebufferUpdate(incremental: true)
    }

    /// Sends keyboard key press or release event (RFC 6143 Section 7.5.4).
    public func sendKeyEvent(key: UInt32, down: Bool) {
        guard !isViewOnly, state == .connected, let connection else { return }
        let packet = Data([
            RFBConstants.ClientMessage.keyEvent.rawValue,
            down ? 1 : 0,
            0,
            0,
            UInt8((key >> 24) & 0xFF),
            UInt8((key >> 16) & 0xFF),
            UInt8((key >> 8) & 0xFF),
            UInt8(key & 0xFF)
        ])

        connection.send(content: packet, completion: .contentProcessed { _ in })
        requestFramebufferUpdate(incremental: true)
    }

    /// Requests an incremental or full framebuffer update from the remote server.
    public func requestFramebufferUpdate(
        incremental: Bool = true,
        originX: Int = 0,
        originY: Int = 0,
        width: Int? = nil,
        height: Int? = nil
    ) {
        guard state == .connected, let connection else { return }
        let reqWidth = width ?? desktopWidth
        let reqHeight = height ?? desktopHeight

        let packet = Data([
            RFBConstants.ClientMessage.framebufferUpdateRequest.rawValue,
            incremental ? 1 : 0,
            UInt8((originX >> 8) & 0xFF),
            UInt8(originX & 0xFF),
            UInt8((originY >> 8) & 0xFF),
            UInt8(originY & 0xFF),
            UInt8((reqWidth >> 8) & 0xFF),
            UInt8(reqWidth & 0xFF),
            UInt8((reqHeight >> 8) & 0xFF),
            UInt8(reqHeight & 0xFF)
        ])

        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func startReceiveLoop() async {
        // Guarantee full-frame request at receive loop onset
        requestFramebufferUpdate(incremental: false)

        // Heartbeat watchdog: re-issues incremental request if connection is idle
        let watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    break
                }
                guard let self, await self.isRunning else { break }
                await self.requestFramebufferUpdate(incremental: true)
            }
        }
        defer {
            watchdogTask.cancel()
        }

        while isRunning {
            do {
                let msgTypeData = try await readExact(1)
                guard let firstByte = msgTypeData.first,
                      let msgType = RFBConstants.ServerMessage(rawValue: firstByte) else { continue }
                switch msgType {
                case .framebufferUpdate:
                    try await handleFramebufferUpdate()
                    requestFramebufferUpdate(incremental: true)
                case .bell:
                    break
                case .serverCutText:
                    let header = try await readExact(7)
                    let byte0 = UInt32(header[3]) << 24
                    let byte1 = UInt32(header[4]) << 16
                    let byte2 = UInt32(header[5]) << 8
                    let byte3 = UInt32(header[6])
                    let textLen = Int(byte0 | byte1 | byte2 | byte3)
                    // Bound clipboard text before allocating; fail closed on excess.
                    guard textLen <= 1_048_576 else {
                        throw VNCAuthError.authenticationRejected("Server cut text too large.")
                    }
                    let textData = try await readExact(textLen)
                    if let text = String(data: textData, encoding: .isoLatin1) {
                        let capturedDelegate = delegate
                        let capturedSelf = self
                        // Hop text to MainActor; session state stays actor-isolated.
                        await MainActor.run {
                            capturedDelegate?.vncClient(capturedSelf, didReceiveCutText: text)
                        }
                    }
                case .setColourMapEntries:
                    // Consume the full payload so the stream never desyncs; truecolor
                    // sessions never use colour maps, but bytes must still be read.
                    let colourHeader = try await readExact(5)
                    let entryCount = Int((UInt16(colourHeader[3]) << 8) | UInt16(colourHeader[4]))
                    // Bound before skipping; classic maps hold 256 entries, more is hostile.
                    guard entryCount <= 256 else {
                        throw VNCAuthError.authenticationRejected("Colour map entry count out of range.")
                    }
                    _ = try await readExact(entryCount * 6)
                }
            } catch {
                if isRunning {
                    // Sanitize before both display and state; error bodies stay private in logs.
                    await updateState(.failed(VNCClient.sanitizedFailureMessage(for: error)))
                }
                break
            }
        }
    }

    private func handleFramebufferUpdate() async throws {
        let header = try await readExact(3)
        let numRects = Int((UInt16(header[1]) << 8) | UInt16(header[2]))
        if numRects == 0 {
            do {
                try await Task.sleep(nanoseconds: 30_000_000)
            } catch {
                return
            }
            return
        }
        // Bound rect batch before looping; fail closed on excess.
        guard numRects <= 10000 else {
            throw VNCAuthError.authenticationRejected("Framebuffer update has too many rects: \(numRects).")
        }

        var pendingBatch: [FramebufferUpdateOp] = []
        pendingBatch.reserveCapacity(min(numRects, 64))

        for _ in 0 ..< numRects {
            let rectHeader = try await readExact(12)
            // readExact guarantees length; desync fails closed instead of skipping.
            guard rectHeader.count >= 12, let originXHigh = rectHeader.first else {
                throw VNCAuthError.authenticationRejected("Incomplete framebuffer rect header.")
            }
            let rectBytes = Array(rectHeader)
            let rectX = Int((UInt16(originXHigh) << 8) | UInt16(rectBytes[1]))
            let rectY = Int((UInt16(rectBytes[2]) << 8) | UInt16(rectBytes[3]))
            let rectWidth = Int((UInt16(rectBytes[4]) << 8) | UInt16(rectBytes[5]))
            let rectHeight = Int((UInt16(rectBytes[6]) << 8) | UInt16(rectBytes[7]))
            let encWord = (UInt32(rectBytes[8]) << 24) | (UInt32(rectBytes[9]) << 16) |
                (UInt32(rectBytes[10]) << 8) | UInt32(rectBytes[11])
            let encTypeRaw = Int32(bitPattern: encWord)

            // LastRect terminates the current FramebufferUpdate batch per RFC 6143.
            if encTypeRaw == RFBConstants.Encoding.lastRect.rawValue {
                break
            }

            // Cursor pseudo-encoding allows 0x0 dimensions to represent a hidden cursor.
            if encTypeRaw == RFBConstants.Encoding.cursor.rawValue {
                try await handleCursorRect(hotspotX: rectX, hotspotY: rectY, width: rectWidth, height: rectHeight)
                continue
            }

            // Bound rect extents before allocating pixel buffers.
            guard rectWidth > 0, rectHeight > 0, rectWidth <= 8192, rectHeight <= 8192 else {
                throw VNCAuthError.authenticationRejected("Framebuffer rect out of range.")
            }
            if encTypeRaw == RFBConstants.Encoding.desktopSize.rawValue {
                await flushUpdateBatch(&pendingBatch)
                await handleDesktopResizeRect(width: rectWidth, height: rectHeight)
                continue
            }

            if encTypeRaw == RFBConstants.Encoding.copyRect.rawValue {
                if let op = try await readCopyRectOp(rectX: rectX, rectY: rectY, width: rectWidth, height: rectHeight) {
                    await appendUpdateOp(op, to: &pendingBatch)
                }
                continue
            }

            // Reject unadvertised types; guessing payload size would desync stream.
            guard encTypeRaw == RFBConstants.Encoding.raw.rawValue else {
                throw VNCAuthError.authenticationRejected("Unsupported encoding.")
            }
            let rawOp = try await readRawRectOp(rectX: rectX, rectY: rectY, width: rectWidth, height: rectHeight)
            await appendUpdateOp(rawOp, to: &pendingBatch)
        }

        await flushUpdateBatch(&pendingBatch)
    }

    private func handleCursorRect(hotspotX: Int, hotspotY: Int, width: Int, height: Int) async throws {
        guard width >= 0, height >= 0, width <= 512, height <= 512 else {
            throw VNCAuthError.authenticationRejected("Cursor rect out of range.")
        }
        let decodedCursor: DecodedCursor?
        if width == 0 || height == 0 {
            decodedCursor = nil
        } else {
            let pixelBytes = width * height * 4
            let maskBytes = ((width + 7) / 8) * height
            let cursorData = try await readExact(pixelBytes + maskBytes)
            decodedCursor = RFBEncodings.decodeCursor(
                data: cursorData,
                cursorX: hotspotX,
                cursorY: hotspotY,
                width: width,
                height: height
            )
        }
        let capturedDelegate = delegate
        let capturedSelf = self
        await MainActor.run {
            capturedDelegate?.vncClient(capturedSelf, didUpdateCursor: decodedCursor)
        }
    }

    private func handleDesktopResizeRect(width: Int, height: Int) async {
        desktopWidth = width
        desktopHeight = height
        let capturedDelegate = delegate
        let capturedSelf = self
        // Hop resize to MainActor; session state stays actor-isolated.
        await MainActor.run {
            capturedDelegate?.vncClient(capturedSelf, didResizeDesktopWidth: width, height: height)
        }
    }

    private func readCopyRectOp(rectX: Int, rectY: Int, width: Int, height: Int) async throws -> FramebufferUpdateOp? {
        let copyData = try await readExact(4)
        guard let (srcX, srcY) = RFBEncodings.decodeCopyRect(
            data: copyData,
            destX: rectX,
            destY: rectY,
            width: width,
            height: height
        ) else {
            return nil
        }
        let destRect = DecodedRect(originX: rectX, originY: rectY, width: width, height: height)
        return .copy(dest: destRect, srcX: srcX, srcY: srcY)
    }

    private func readRawRectOp(rectX: Int, rectY: Int, width: Int, height: Int) async throws -> FramebufferUpdateOp {
        let pixelBytes = width * height * 4
        // Cap Raw payload by desktop area and absolute ceiling.
        guard pixelBytes <= 33_554_432, pixelBytes <= desktopWidth * desktopHeight * 4 else {
            throw VNCAuthError.authenticationRejected("Framebuffer rect payload too large.")
        }
        let data = try await readExact(pixelBytes)
        let rect = RFBEncodings.decodeRaw(data: data, originX: rectX, originY: rectY, width: width, height: height)
        return .raw(rect)
    }

    private func appendUpdateOp(_ op: FramebufferUpdateOp, to batch: inout [FramebufferUpdateOp]) async {
        batch.append(op)
        if batch.count >= 64 {
            await flushUpdateBatch(&batch)
        }
    }

    private func flushUpdateBatch(_ batch: inout [FramebufferUpdateOp]) async {
        guard !batch.isEmpty else { return }
        let ops = batch
        batch.removeAll(keepingCapacity: true)
        let capturedDelegate = delegate
        let capturedSelf = self
        await MainActor.run {
            capturedDelegate?.vncClient(capturedSelf, didReceiveUpdateBatch: ops)
        }
    }

    func readExact(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = Data()
        buffer.reserveCapacity(count)

        while buffer.count < count {
            let needed = count - buffer.count
            let chunkSize = min(needed, 65536)
            let chunk = try await readChunk(minBytes: 1, maxBytes: chunkSize)
            guard !chunk.isEmpty else {
                throw CancellationError()
            }
            buffer.append(chunk)
        }
        return buffer
    }

    private func readChunk(minBytes: Int, maxBytes: Int) async throws -> Data {
        guard let connection else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: minBytes, maximumLength: maxBytes) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func sendExact(_ data: Data) async throws {
        guard let connection else { throw CancellationError() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func updateState(_ newState: VNCConnectionState) async {
        state = newState
        let capturedDelegate = delegate
        let capturedSelf = self
        await MainActor.run {
            capturedDelegate?.vncClient(capturedSelf, didUpdateState: newState)
        }
    }
}
