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
    func vncClient(_ client: VNCClient, didReceiveCutText text: String)
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

    /// Updates view-only mode; when true, pointer and key sends are dropped.
    public func setViewOnly(_ value: Bool) {
        isViewOnly = value
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
        requestFramebufferUpdate(incremental: false)

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
        guard !isViewOnly, state == .connected, let connection else { return }
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
                    break
                }
            } catch {
                if isRunning {
                    await updateState(.failed(error.localizedDescription))
                }
                break
            }
        }
    }

    private func handleFramebufferUpdate() async throws {
        let header = try await readExact(3)
        let numRects = Int((UInt16(header[1]) << 8) | UInt16(header[2]))
        // Bound rect batch before looping; fail closed on excess.
        guard numRects <= 10000 else {
            throw VNCAuthError.authenticationRejected("Framebuffer update has too many rects: \(numRects).")
        }

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

            // LastRect carries no payload; it only terminates the batch.
            if encTypeRaw == RFBConstants.Encoding.lastRect.rawValue {
                continue
            }

            // Bound rect extents before allocating pixel buffers.
            guard rectWidth > 0, rectHeight > 0, rectWidth <= 8192, rectHeight <= 8192 else {
                throw VNCAuthError.authenticationRejected("Framebuffer rect out of range.")
            }
            if encTypeRaw == RFBConstants.Encoding.desktopSize.rawValue {
                desktopWidth = rectWidth
                desktopHeight = rectHeight
                let capturedDelegate = delegate
                let capturedSelf = self
                // Hop resize to MainActor; session state stays actor-isolated.
                await MainActor.run {
                    capturedDelegate?.vncClient(capturedSelf, didResizeDesktopWidth: rectWidth, height: rectHeight)
                }
                continue
            }

            if encTypeRaw == RFBConstants.Encoding.copyRect.rawValue {
                let copyData = try await readExact(4)
                if let (srcX, srcY) = RFBEncodings.decodeCopyRect(
                    data: copyData,
                    destX: rectX,
                    destY: rectY,
                    width: rectWidth,
                    height: rectHeight
                ) {
                    let destRect = DecodedRect(
                        originX: rectX,
                        originY: rectY,
                        width: rectWidth,
                        height: rectHeight
                    )
                    let capturedDelegate = delegate
                    let capturedSelf = self
                    // Hop blit to MainActor; session state stays actor-isolated.
                    await MainActor.run {
                        capturedDelegate?.vncClient(capturedSelf, didReceiveCopyRect: destRect, srcX: srcX, srcY: srcY)
                    }
                }
                continue
            }

            // Reject unadvertised types; guessing payload size would desync stream.
            guard encTypeRaw == RFBConstants.Encoding.raw.rawValue else {
                throw VNCAuthError.authenticationRejected("Unsupported encoding.")
            }
            let pixelBytes = rectWidth * rectHeight * 4
            // Cap Raw payload by desktop area and absolute ceiling.
            guard pixelBytes <= 33_554_432, pixelBytes <= desktopWidth * desktopHeight * 4 else {
                throw VNCAuthError.authenticationRejected("Framebuffer rect payload too large.")
            }
            let data = try await readExact(pixelBytes)
            let rect = RFBEncodings.decodeRaw(
                data: data,
                originX: rectX,
                originY: rectY,
                width: rectWidth,
                height: rectHeight
            )
            let capturedDelegate = delegate
            let capturedSelf = self
            // Hop pixels to MainActor; session state stays actor-isolated.
            await MainActor.run {
                capturedDelegate?.vncClient(capturedSelf, didReceiveRawRect: rect)
            }
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
