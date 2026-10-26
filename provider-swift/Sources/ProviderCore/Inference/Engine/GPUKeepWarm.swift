// Copyright © 2026 Eigen Labs.
//
// Opt-in GPU keep-warm for time to first token. Both modes are off by default.
//
// An idle Apple GPU powers down within a second or two, and the first command
// buffer afterwards waits for it to wake. The keep-warm submits one trivial
// command buffer (a 4-byte blit fill) on its own Metal queue, never on MLX's
// streams, so it neither touches MLX state nor references model memory:
//   - wake-on-accept: an accepted coordinator request that finds the Mac idle
//     submits one at once, overlapping the wake with prompt rendering and
//     tokenization. Nothing runs while the Mac is idle.
//   - idle heartbeat: while a model is loaded and the Mac has been idle for
//     `heartbeatIdleThreshold`, one every `heartbeatInterval`, for at most
//     `heartbeatMaxIdle` after the last accepted request.
// "Idle" is the shared `WholeMacServiceBudget`: no request charge (prefill or
// decode) and no device activity (loads, cache transfers). Neither mode
// reports device activity, so idle calibration and the idle cache sweep see
// the same idleness as without it.

import Foundation
#if canImport(Metal)
import Metal
#endif

/// Submits one trivial GPU command buffer. The seam lets CPU-only tests drive
/// `GPUKeepWarm` without a GPU.
protocol GPUWakeSubmitting: Sendable {
    /// Returns false when nothing was submitted. Otherwise `completed` runs
    /// once the GPU has finished the command buffer.
    func submit(completed: @escaping @Sendable () -> Void) -> Bool
}

final class GPUKeepWarm: @unchecked Sendable {
    struct Policy: Equatable, Sendable {
        var wakeOnAccept = false
        var idleHeartbeat = false

        static let wakeOnAcceptEnvironmentKey = "DARKBLOOM_TTFT_GPU_WAKE_ON_ACCEPT"
        static let idleHeartbeatEnvironmentKey = "DARKBLOOM_TTFT_GPU_IDLE_HEARTBEAT"

        var isEnabled: Bool { wakeOnAccept || idleHeartbeat }

        init(wakeOnAccept: Bool = false, idleHeartbeat: Bool = false) {
            self.wakeOnAccept = wakeOnAccept
            self.idleHeartbeat = idleHeartbeat
        }

        /// Opt-in only: trimmed, case-insensitive `1`, `true`, `yes` or `on`
        /// enables a mode; unset or any other value leaves it off.
        init(environment: [String: String]) {
            wakeOnAccept = Self.enables(environment[Self.wakeOnAcceptEnvironmentKey])
            idleHeartbeat = Self.enables(environment[Self.idleHeartbeatEnvironmentKey])
        }

        private static func enables(_ raw: String?) -> Bool {
            guard let raw else { return false }
            return ["1", "true", "yes", "on"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    /// Mac-wide inputs, read at each opportunity.
    struct Signals: Sendable {
        /// True while any request charge or device activity holds the Mac.
        let busy: @Sendable () -> Bool
        /// True once the Mac has had no request charge or device activity for
        /// at least the duration.
        let idleFor: @Sendable (Duration) -> Bool
        let modelLoaded: @Sendable () -> Bool
    }

    /// One keep-warm opportunity's result.
    enum Outcome: Equatable, Sendable {
        case submitted
        case disabled
        case noModelLoaded
        case busy
        case notIdleLongEnough
        case tooSoon
        /// The previous keep-warm command buffer has not completed.
        case inFlight
        case idleBoundReached
        case submitFailed
    }

    static let heartbeatInterval: Duration = .milliseconds(1_500)
    static let heartbeatIdleThreshold: Duration = .seconds(2)
    /// Bounds the idle power cost of a Mac that gets no traffic.
    static let heartbeatMaxIdle: Duration = .seconds(600)
    /// Coalesces a burst of accepted requests into one wake.
    static let wakeSpacing: Duration = .milliseconds(250)

    let policy: Policy
    private let signals: Signals
    private let submitter: any GPUWakeSubmitting
    private let now: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private var lastSubmitAt: ContinuousClock.Instant?
    private var lastAcceptAt: ContinuousClock.Instant
    private var inFlight = false

    init(policy: Policy, signals: Signals, submitter: any GPUWakeSubmitting,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.policy = policy
        self.signals = signals
        self.submitter = submitter
        self.now = now
        self.lastAcceptAt = now()
    }

    /// Re-arms the heartbeat's idle bound and, with wake-on-accept, wakes an
    /// idle GPU. Called right after `inference_accepted` is sent; never blocks.
    @discardableResult
    func requestAccepted() -> Outcome {
        lock.withLock { lastAcceptAt = now() }
        guard policy.wakeOnAccept else { return .disabled }
        // Another request's prefill or decode already keeps the GPU awake.
        guard !signals.busy() else { return .busy }
        return submitIfDue(spacing: Self.wakeSpacing)
    }

    /// One heartbeat opportunity.
    @discardableResult
    func heartbeatTick() -> Outcome {
        guard policy.idleHeartbeat else { return .disabled }
        guard signals.modelLoaded() else { return .noModelLoaded }
        guard lock.withLock({ now() - lastAcceptAt < Self.heartbeatMaxIdle }) else { return .idleBoundReached }
        guard !signals.busy() else { return .busy }
        guard signals.idleFor(Self.heartbeatIdleThreshold) else { return .notIdleLongEnough }
        return submitIfDue(spacing: Self.heartbeatInterval)
    }

    /// Runs heartbeat opportunities until the task is cancelled.
    func runHeartbeat(sleep: @Sendable (Duration) async throws -> Void = { try await taskSleep($0) }) async {
        guard policy.idleHeartbeat else { return }
        while !Task.isCancelled {
            do { try await sleep(Self.heartbeatInterval) } catch { return }
            heartbeatTick()
        }
    }

    /// At most one keep-warm command buffer is ever in flight.
    private func submitIfDue(spacing: Duration) -> Outcome {
        let reserved = lock.withLock { () -> Outcome? in
            guard !inFlight else { return .inFlight }
            let at = now()
            if let lastSubmitAt, at - lastSubmitAt < spacing { return .tooSoon }
            inFlight = true
            lastSubmitAt = at
            return nil
        }
        if let reserved { return reserved }
        let submitted = submitter.submit { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.inFlight = false }
        }
        guard submitted else {
            lock.withLock { inFlight = false }
            return .submitFailed
        }
        return .submitted
    }
}

#if canImport(Metal)
/// The production seam: a 4-byte blit fill on a dedicated queue. Metal has no
/// public GPU priority for a queue; the command is the smallest unit of work
/// the GPU accepts, and `GPUKeepWarm` submits it only while the Mac is idle.
final class MetalGPUWakeSubmitter: GPUWakeSubmitting, @unchecked Sendable {
    private let queue: MTLCommandQueue
    private let buffer: MTLBuffer

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(maxCommandBufferCount: 2),
            let buffer = device.makeBuffer(length: 4, options: .storageModeShared)
        else { return nil }
        queue.label = "darkbloom.gpu-keep-warm"
        self.queue = queue
        self.buffer = buffer
    }

    func submit(completed: @escaping @Sendable () -> Void) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { return false }
        blit.fill(buffer: buffer, range: 0..<4, value: 0)
        blit.endEncoding()
        commandBuffer.addCompletedHandler { _ in completed() }
        commandBuffer.commit()
        return true
    }
}
#endif
