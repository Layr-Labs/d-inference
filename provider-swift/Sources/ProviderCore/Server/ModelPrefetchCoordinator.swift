/// ModelPrefetchCoordinator — background model-build prefetcher.
///
/// Owns the lifecycle of coordinator-driven `prefetch_model` requests:
///   - downloads + verifies a build ON DISK (no GPU load, no `modelSlots`)
///   - reports `.started` → throttled `.downloading` → terminal
///     `.verified`/`.failed` over the provider WebSocket
///   - coalesces duplicate prefetches for the same model id (one task, many
///     status subscribers — mirroring `ProviderLoop`'s preload coalescing)
///   - is fully cancellable (shutdown cancels every in-flight prefetch task)
///   - short-circuits to `.verified` when the build is already
///     loaded/on-disk-and-valid
///   - fires a re-advertise hook on `.verified` so the coordinator learns the
///     provider can now serve the build
///
/// Kept separate from `ProviderLoop` (and tested in isolation) so the
/// download/verify/coalesce/advertise logic does not depend on the GPU model
/// load path. `ProviderLoop` delegates `.prefetchModel` events here.

import Foundation

/// Status sink for prefetch progress/terminal messages. The real sink wraps the
/// coordinator `SendHandle`; tests inject a recording sink.
public protocol PrefetchStatusSink: Sendable {
    func emit(
        modelId: String,
        status: ProviderMessage.PrefetchModelStatus.Status,
        bytesDone: Int64,
        bytesTotal: Int64,
        error: String?
    )
}

/// Outcome of the "already available?" pre-check the coordinator runs before
/// starting a download. Lets `ProviderLoop` answer "already loaded into GPU" or
/// "already on disk + valid" so we can short-circuit to `.verified`.
public enum PrefetchPreCheck: Sendable {
    /// Build is already available (loaded or on-disk-and-verified) — emit
    /// `.verified` immediately, skip the download.
    case alreadyAvailable
    /// Build must be downloaded/verified.
    case needsFetch
}

public actor ModelPrefetchCoordinator {
    private let prefetcher: any ModelPrefetcher
    /// Answers whether a build is already available without downloading.
    private let preCheck: @Sendable (String) async -> PrefetchPreCheck
    /// Fired on `.verified` so the host can add the build to the advertised set
    /// and re-register. Returns when the re-advertise has been applied.
    private let onVerified: @Sendable (String) async -> Void

    /// In-flight prefetch tasks keyed by model id (coalescing key). A second
    /// request for the same id attaches as a subscriber instead of starting a
    /// new download.
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    /// Ownership tokens so a stale task's deferred cleanup can't evict a newer
    /// task's entry (same pattern as `ProviderLoop.preloadTaskIds`).
    private var prefetchTaskIds: [String: UUID] = [:]
    /// Status sinks waiting on the terminal result of an in-flight prefetch.
    private var statusSubscribers: [String: [any PrefetchStatusSink]] = [:]

    private var isShuttingDown = false

    /// Progress throttle: emit a `.downloading` update at most once per this
    /// interval OR when cumulative progress advances by `progressStepFraction`.
    static let progressThrottle: Duration = .seconds(2)
    static let progressStepFraction: Double = 0.05

    /// Test hook: invoked with the model id once a prefetch task has begun its
    /// download body (after `.started`, past coalescing). Lets tests gate the
    /// fake downloader deterministically.
    private let onTaskStarted: (@Sendable (String) -> Void)?

    public init(
        prefetcher: any ModelPrefetcher,
        preCheck: @escaping @Sendable (String) async -> PrefetchPreCheck,
        onVerified: @escaping @Sendable (String) async -> Void,
        onTaskStarted: (@Sendable (String) -> Void)? = nil
    ) {
        self.prefetcher = prefetcher
        self.preCheck = preCheck
        self.onVerified = onVerified
        self.onTaskStarted = onTaskStarted
    }

    /// Number of in-flight prefetch tasks (test/diagnostics).
    public func inFlightCount() -> Int { prefetchTasks.count }

    /// Handle a coordinator `prefetch_model` request. Emits `.started`
    /// immediately, coalesces duplicates, and spawns a low-priority background
    /// task for new downloads.
    public func handlePrefetch(modelId: String, priority: Int, sink: any PrefetchStatusSink) {
        if isShuttingDown {
            sink.emit(modelId: modelId, status: .failed, bytesDone: 0, bytesTotal: 0, error: "provider is shutting down")
            return
        }

        // Coalesce: an in-flight prefetch for this id absorbs the duplicate.
        if prefetchTasks[modelId] != nil {
            statusSubscribers[modelId, default: []].append(sink)
            sink.emit(modelId: modelId, status: .started, bytesDone: 0, bytesTotal: 0, error: nil)
            return
        }

        statusSubscribers[modelId] = [sink]
        sink.emit(modelId: modelId, status: .started, bytesDone: 0, bytesTotal: 0, error: nil)

        let taskId = UUID()
        prefetchTaskIds[modelId] = taskId
        // Background priority so the download yields to inference work.
        prefetchTasks[modelId] = Task(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runPrefetch(modelId: modelId, taskId: taskId)
        }
    }

    /// Cancel every in-flight prefetch and wait briefly for them to unwind.
    /// Called from the host's shutdown path.
    ///
    /// The wait is bounded by `timeout` and MUST NOT block on a task that
    /// cancellation cannot stop: a prefetch parked in its verified→re-advertise
    /// hook can be awaiting an off-actor synchronous weight-hash (multi-GB,
    /// uninterruptible). We therefore resume on whichever of "drain completed"
    /// or "deadline elapsed" fires FIRST, using an unstructured drain task +
    /// timer (a structured `withTaskGroup` cannot return while a child is still
    /// blocked on `await task.value`, defeating the bound). A straggler that
    /// outlives the timeout finishes detached — it only touches disk/in-memory
    /// state and the references are dropped here.
    public func shutdown(timeout: Duration = .seconds(10)) async {
        isShuttingDown = true
        let tasks = Array(prefetchTasks.values)
        for task in tasks { task.cancel() }
        prefetchTasks.removeAll()
        prefetchTaskIds.removeAll()
        statusSubscribers.removeAll()

        guard !tasks.isEmpty else { return }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let oneShot = OneShotResumer(cont)
            // Drain task (unstructured): may block on a parked straggler, but it
            // is detached so it never holds up the continuation below.
            Task.detached {
                for task in tasks { await task.value }
                oneShot.resume()
            }
            // Timeout task (unstructured): guarantees the bound regardless of
            // the drain.
            Task.detached {
                try? await Task.sleep(for: timeout)
                oneShot.resume()
            }
        }
    }

    // MARK: - Internals

    private func runPrefetch(modelId: String, taskId: UUID) async {
        defer { Task { await self.removeTask(modelId: modelId, taskId: taskId) } }

        // Short-circuit if already available (loaded or on-disk-and-valid).
        let pre = await preCheck(modelId)
        if case .alreadyAvailable = pre {
            await onVerified(modelId)
            finish(modelId: modelId, taskId: taskId, status: .verified, bytesDone: 0, bytesTotal: 0, error: nil)
            return
        }

        if Task.isCancelled { return }
        onTaskStarted?(modelId)

        // Throttled progress emitter. Captures actor-isolated emit via a hop.
        let throttle = ProgressThrottle(
            interval: Self.progressThrottle,
            stepFraction: Self.progressStepFraction
        )
        let me = self
        let onByteProgress: @Sendable (Int64, Int64) -> Void = { done, total in
            guard throttle.shouldEmit(done: done, total: total) else { return }
            Task { await me.emitDownloading(modelId: modelId, bytesDone: done, bytesTotal: total) }
        }

        do {
            try await prefetcher.prefetchToDisk(modelID: modelId, onByteProgress: onByteProgress)
            try Task.checkCancellation()
            if isShuttingDown { return }
            // Build is on disk + aggregate-verified. Re-advertise, then report
            // terminal success.
            await onVerified(modelId)
            finish(modelId: modelId, taskId: taskId, status: .verified, bytesDone: 0, bytesTotal: 0, error: nil)
        } catch is CancellationError {
            // Cancelled (shutdown or explicit) — emit nothing terminal.
            return
        } catch {
            if isShuttingDown { return }
            finish(modelId: modelId, taskId: taskId, status: .failed, bytesDone: 0, bytesTotal: 0, error: error.localizedDescription)
        }
    }

    /// Emit a throttled `.downloading` update to every subscriber.
    private func emitDownloading(modelId: String, bytesDone: Int64, bytesTotal: Int64) {
        guard !isShuttingDown else { return }
        for sink in statusSubscribers[modelId] ?? [] {
            sink.emit(modelId: modelId, status: .downloading, bytesDone: bytesDone, bytesTotal: bytesTotal, error: nil)
        }
    }

    /// Emit a terminal status to all subscribers and clear coalescing state.
    private func finish(
        modelId: String,
        taskId: UUID,
        status: ProviderMessage.PrefetchModelStatus.Status,
        bytesDone: Int64,
        bytesTotal: Int64,
        error: String?
    ) {
        guard prefetchTaskIds[modelId] == taskId else { return }
        let subscribers = statusSubscribers.removeValue(forKey: modelId) ?? []
        prefetchTasks.removeValue(forKey: modelId)
        prefetchTaskIds.removeValue(forKey: modelId)
        for sink in subscribers {
            sink.emit(modelId: modelId, status: status, bytesDone: bytesDone, bytesTotal: bytesTotal, error: error)
        }
    }

    /// Deferred cleanup: only clears the entry if it still belongs to this task.
    private func removeTask(modelId: String, taskId: UUID) {
        if prefetchTaskIds[modelId] == taskId {
            prefetchTasks.removeValue(forKey: modelId)
            prefetchTaskIds.removeValue(forKey: modelId)
            statusSubscribers.removeValue(forKey: modelId)
        }
    }
}

// MARK: - One-shot resumer

/// Resumes a `CheckedContinuation` exactly once, ignoring later calls. Used by
/// `shutdown` to return on the FIRST of drain-complete / timeout without the
/// loser double-resuming (a fatal error).
private final class OneShotResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume()
    }
}

// MARK: - Progress throttle

/// Decides whether a `.downloading` update should be emitted, gating on BOTH a
/// minimum wall-clock interval and a minimum progress step so we neither flood
/// the WebSocket nor go silent on a long single-file download. Thread-safe so it
/// can be called from the downloader's progress callback on any executor.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: Duration
    private let stepFraction: Double
    private var lastEmit: ContinuousClock.Instant?
    private var lastFraction: Double = -1

    init(interval: Duration, stepFraction: Double) {
        self.interval = interval
        self.stepFraction = stepFraction
    }

    func shouldEmit(done: Int64, total: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ContinuousClock.now
        let fraction = total > 0 ? Double(done) / Double(total) : 0
        // Always emit the first update.
        guard let last = lastEmit else {
            lastEmit = now
            lastFraction = fraction
            return true
        }
        let elapsedOK = (now - last) >= interval
        let stepOK = (fraction - lastFraction) >= stepFraction
        // Always let the 100% completion update through.
        let completeOK = total > 0 && done >= total && lastFraction < 1.0
        guard elapsedOK || stepOK || completeOK else { return false }
        lastEmit = now
        lastFraction = fraction
        return true
    }
}
