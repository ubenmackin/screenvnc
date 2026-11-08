// VNC — Ordered, coalescing input pipeline bridging UI gestures to RFB events.
import Foundation
import os

public enum VNCInputCommand: Sendable {
    case pointerMove(posX: Int, posY: Int, buttonMask: UInt8)
    case pointerDown(posX: Int, posY: Int, buttonMask: UInt8)
    case pointerUp(posX: Int, posY: Int)
    case click(posX: Int, posY: Int, buttonMask: UInt8)
    case scroll(posX: Int, posY: Int, stepsX: Int, stepsY: Int, activeButtons: UInt8)
    case keyEvent(key: UInt32, down: Bool)
    case keyTap(key: UInt32)
    case keyChord(keys: [UInt32])
}

private struct BufferedPointerMove: Sendable {
    let posX: Int
    let posY: Int
    let buttonMask: UInt8

    var command: VNCInputCommand {
        .pointerMove(posX: posX, posY: posY, buttonMask: buttonMask)
    }
}

@MainActor
public final class VNCInputPipeline {
    private var continuation: AsyncStream<VNCInputCommand>.Continuation?
    private var latestMove: BufferedPointerMove?
    private var lastMoveDispatchedAt: ContinuousClock.Instant?
    private var isProcessing = false
    private let logger = Logger(subsystem: "com.volcrypt.ScreenVNC", category: "VNCInputPipeline")
    private let moveMinInterval: Duration = .milliseconds(16)

    public init() {}

    /// Enqueues a pointer, scroll, or key command synchronously in strict FIFO order.
    public func enqueue(_ command: VNCInputCommand) {
        if case let .pointerMove(posX, posY, buttonMask) = command {
            // Coalesce high-frequency hover/drag updates on MainActor to avoid flooding TCP.
            let buffered = BufferedPointerMove(posX: posX, posY: posY, buttonMask: buttonMask)
            latestMove = buffered
            let now = ContinuousClock.now
            if let last = lastMoveDispatchedAt, now - last < moveMinInterval {
                return
            }
            lastMoveDispatchedAt = now
            latestMove = nil
            continuation?.yield(buffered.command)
            return
        }

        // Flush any buffered move before discrete presses or releases so targets never lag.
        if let pending = latestMove {
            latestMove = nil
            lastMoveDispatchedAt = ContinuousClock.now
            continuation?.yield(pending.command)
        }
        continuation?.yield(command)
    }

    /// Flushes any pending throttled pointer move immediately (e.g., on gesture lift).
    public func flushPendingMove() {
        guard let pending = latestMove else { return }
        latestMove = nil
        lastMoveDispatchedAt = ContinuousClock.now
        continuation?.yield(pending.command)
    }

    /// Consumes queued input commands sequentially for the lifetime of an active session.
    public func run(client: VNCClient) async {
        guard !isProcessing else { return }
        isProcessing = true
        let (stream, cont) = AsyncStream<VNCInputCommand>.makeStream()
        continuation = cont
        defer {
            cont.finish()
            continuation = nil
            latestMove = nil
            isProcessing = false
        }

        var lastPosition: (x: Int, y: Int) = (0, 0)
        var heldButtons: UInt8 = 0

        for await command in stream {
            if Task.isCancelled {
                break
            }
            switch command {
            case let .pointerMove(posX, posY, buttonMask):
                lastPosition = (posX, posY)
                heldButtons = buttonMask
                await client.sendPointerEvent(posX: posX, posY: posY, buttonMask: buttonMask)
            case let .pointerDown(posX, posY, buttonMask):
                lastPosition = (posX, posY)
                heldButtons = buttonMask
                await client.sendPointerEvent(posX: posX, posY: posY, buttonMask: 0)
                await client.sendPointerEvent(posX: posX, posY: posY, buttonMask: buttonMask)
            case let .pointerUp(posX, posY):
                lastPosition = (posX, posY)
                heldButtons = 0
                await client.sendPointerEvent(posX: posX, posY: posY, buttonMask: 0)
            case let .click(posX, posY, buttonMask):
                lastPosition = (posX, posY)
                heldButtons = 0
                await client.sendPointerEvent(posX: posX, posY: posY, buttonMask: 0)
                await sleep(milliseconds: 12)
                await client.sendPointerEvent(posX: posX, posY: posY, buttonMask: buttonMask)
                await sleep(milliseconds: 35)
                await client.sendPointerEvent(posX: posX, posY: posY, buttonMask: 0)
            case let .scroll(posX, posY, stepsX, stepsY, activeButtons):
                lastPosition = (posX, posY)
                await client.sendScrollEvent(
                    posX: posX,
                    posY: posY,
                    deltaStepsX: stepsX,
                    deltaStepsY: stepsY,
                    activeButtons: activeButtons
                )
            case let .keyEvent(key, down):
                await client.sendKeyEvent(key: key, down: down)
            case let .keyTap(key):
                await client.sendKeyEvent(key: key, down: true)
                await sleep(milliseconds: 30)
                await client.sendKeyEvent(key: key, down: false)
            case let .keyChord(keys):
                for key in keys {
                    await client.sendKeyEvent(key: key, down: true)
                }
                await sleep(milliseconds: 45)
                for key in keys.reversed() {
                    await client.sendKeyEvent(key: key, down: false)
                }
            }
        }

        if heldButtons != 0 {
            await client.sendPointerEvent(posX: lastPosition.x, posY: lastPosition.y, buttonMask: 0)
        }
    }

    private func sleep(milliseconds: Int) async {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
        } catch is CancellationError {
            // Structured cancellation exits cleanly after caller loop stops.
        } catch {
            logger.debug("Input delay interrupted: \(error.localizedDescription)")
        }
    }
}
