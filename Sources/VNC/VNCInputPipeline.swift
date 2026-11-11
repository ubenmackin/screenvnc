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

private struct PendingScrollState: Sendable {
    var posX: Int
    var posY: Int
    var stepsX: Int
    var stepsY: Int
    var activeButtons: UInt8
}

@MainActor
public final class VNCInputPipeline {
    private var continuation: AsyncStream<VNCInputCommand>.Continuation?
    private var latestMove: BufferedPointerMove?
    private var lastMoveDispatchedAt: ContinuousClock.Instant?
    private var pendingScroll: PendingScrollState?
    private var pendingScrollTask: Task<Void, Never>?
    private var isProcessing = false
    private let logger = Logger(subsystem: "com.volcrypt.ScreenVNC", category: "VNCInputPipeline")
    private let moveMinInterval: Duration = .milliseconds(16)

    public init() {}

    /// Enqueues a pointer, scroll, or key command synchronously in strict FIFO order.
    public func enqueue(_ command: VNCInputCommand) {
        if case let .scroll(posX, posY, stepsX, stepsY, activeButtons) = command {
            // Debounce flings at one anchor; an anchor change emits the prior
            // pulse so differing positions never merge into one command.
            if var pending = pendingScroll,
               pending.posX == posX, pending.posY == posY, pending.activeButtons == activeButtons
            {
                // Flush saturated 12-step pulses now and carry the remainder
                // so rapid pulses never drop overflow notches.
                var sumX = pending.stepsX + stepsX
                var sumY = pending.stepsY + stepsY
                while abs(sumX) > 12 || abs(sumY) > 12 {
                    let chunkX = min(max(sumX, -12), 12)
                    let chunkY = min(max(sumY, -12), 12)
                    yieldScroll(posX: posX, posY: posY, stepsX: chunkX, stepsY: chunkY, activeButtons: activeButtons)
                    sumX -= chunkX
                    sumY -= chunkY
                }
                pending.stepsX = sumX
                pending.stepsY = sumY
                pendingScroll = pending
            } else {
                if let prior = pendingScroll {
                    yieldScroll(prior)
                }
                pendingScroll = PendingScrollState(posX: posX, posY: posY, stepsX: stepsX, stepsY: stepsY, activeButtons: activeButtons)
            }
            pendingScrollTask?.cancel()
            pendingScrollTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.flushPendingScroll()
            }
            return
        }

        // Discrete input jumps the debounce queue so mixed input preserves FIFO.
        if let pending = pendingScroll {
            pendingScroll = nil
            pendingScrollTask?.cancel()
            pendingScrollTask = nil
            yieldScroll(pending)
        }

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

    /// Emits the debounced scroll pulse unless it netted to zero steps.
    public func flushPendingScroll() {
        guard let pending = pendingScroll else { return }
        pendingScroll = nil
        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        yieldScroll(pending)
    }

    private func yieldScroll(_ state: PendingScrollState) {
        yieldScroll(
            posX: state.posX,
            posY: state.posY,
            stepsX: state.stepsX,
            stepsY: state.stepsY,
            activeButtons: state.activeButtons
        )
    }

    private func yieldScroll(posX: Int, posY: Int, stepsX: Int, stepsY: Int, activeButtons: UInt8) {
        // Split saturated pulses so full swipes never drop overflow notches.
        var remainingX = stepsX
        var remainingY = stepsY
        guard remainingX != 0 || remainingY != 0 else { return }
        while remainingX != 0 || remainingY != 0 {
            let chunkX = min(max(remainingX, -12), 12)
            let chunkY = min(max(remainingY, -12), 12)
            continuation?.yield(.scroll(
                posX: posX,
                posY: posY,
                stepsX: chunkX,
                stepsY: chunkY,
                activeButtons: activeButtons
            ))
            remainingX -= chunkX
            remainingY -= chunkY
        }
    }

    /// Consumes queued input commands sequentially for the lifetime of an active session.
    public func run(client: VNCClient) async {
        guard !isProcessing else { return }
        isProcessing = true
        let (stream, cont) = AsyncStream<VNCInputCommand>.makeStream()
        continuation = cont
        defer {
            finishSession(cont: cont)
        }

        var lastPosition: (x: Int, y: Int) = (0, 0)
        var heldButtons: UInt8 = 0

        for await command in stream {
            if Task.isCancelled {
                break
            }
            await dispatch(command, client: client, lastPosition: &lastPosition, heldButtons: &heldButtons)
        }

        await drainTrailingScroll(client: client)

        if heldButtons != 0 {
            await client.sendPointerEvent(posX: lastPosition.x, posY: lastPosition.y, buttonMask: 0)
        }
    }

    private func finishSession(cont: AsyncStream<VNCInputCommand>.Continuation) {
        // Flush the last debounced pulse so session end never drops it.
        if let pending = pendingScroll {
            yieldScroll(pending)
        }
        cont.finish()
        continuation = nil
        latestMove = nil
        pendingScroll = nil
        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        isProcessing = false
    }

    private func dispatch(
        _ command: VNCInputCommand,
        client: VNCClient,
        lastPosition: inout (x: Int, y: Int),
        heldButtons: inout UInt8
    ) async {
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
            await sendChord(keys, client: client)
        }
    }

    private func sendChord(_ keys: [UInt32], client: VNCClient) async {
        for key in keys {
            await client.sendKeyEvent(key: key, down: true)
        }
        await sleep(milliseconds: 45)
        for key in keys.reversed() {
            await client.sendKeyEvent(key: key, down: false)
        }
    }

    private func drainTrailingScroll(client: VNCClient) async {
        // Deliver the last debounced pulse directly; the stream consumer
        // already exited so yielding would never reach the client.
        guard let pending = pendingScroll, pending.stepsX != 0 || pending.stepsY != 0 else { return }
        pendingScroll = nil
        pendingScrollTask?.cancel()
        pendingScrollTask = nil
        var remainingX = pending.stepsX
        var remainingY = pending.stepsY
        while remainingX != 0 || remainingY != 0 {
            let chunkX = min(max(remainingX, -12), 12)
            let chunkY = min(max(remainingY, -12), 12)
            await client.sendScrollEvent(
                posX: pending.posX,
                posY: pending.posY,
                deltaStepsX: chunkX,
                deltaStepsY: chunkY,
                activeButtons: pending.activeButtons
            )
            remainingX -= chunkX
            remainingY -= chunkY
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
