import Foundation
import Testing

@testable import ProviderCore

// MARK: - Test doubles

/// Records every status emission so tests can assert the lifecycle.
final class RecordingSink: PrefetchStatusSink, @unchecked Sendable {
    struct Event: Equatable {
        let modelId: String
        let status: ProviderMessage.PrefetchModelStatus.Status
        let bytesDone: Int64
        let bytesTotal: Int64
        let error: String?
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    private let terminalSignal = AsyncTestLatch()

    func emit(
        modelId: String,
        status: ProviderMessage.PrefetchModelStatus.Status,
        bytesDone: Int64,
        bytesTotal: Int64,
        error: String?
    ) {
        let event = Event(
            modelId: modelId,
            status: status,
            bytesDone: bytesDone,
            bytesTotal: bytesTotal,
            error: error)
        lock.lock()
        _events.append(event)
        lock.unlock()
        if status == .verified || status == .failed {
            terminalSignal.signal()
        }
    }

    var events: [Event] { lock.lock(); defer { lock.unlock() }; return _events }
    var statuses: [ProviderMessage.PrefetchModelStatus.Status] { events.map(\.status) }
    func terminal() -> Event? { events.last(where: { $0.status == .verified || $0.status == .failed }) }
    func waitForTerminal() async -> Event {
        if let terminal = terminal() { return terminal }
        await terminalSignal.wait()
        return terminal()!
    }
}

enum FakePrefetchError: Error, LocalizedError {
    case hashMismatch
    var errorDescription: String? { "aggregate hash mismatch (fake)" }
}

/// Configurable fake `ModelPrefetcher`. Counts invocations (for coalescing
/// assertions), can emit byte progress, can fail, and can block on a gate so a
/// test can cancel mid-flight.
final class FakePrefetcher: ModelPrefetcher, @unchecked Sendable {
    enum Behavior {
        case success(total: Int64, steps: Int)
        case failHashMismatch
        case blockUntilCancelled
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var _callCount = 0
    /// Signalled when a blocking prefetch has actually started (so a test can
    /// cancel only after the download body is running).
    let started = AsyncTestLatch()
    private let suspension = CancellableTestSuspension()

    init(_ behavior: Behavior) { self.behavior = behavior }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { _callCount += 1 }
        switch behavior {
        case .success(let total, let steps):
            for i in 1...max(1, steps) {
                try Task.checkCancellation()
                let done = Int64(Double(total) * Double(i) / Double(max(1, steps)))
                onByteProgress(done, total)
                await Task.yield()
            }
        case .failHashMismatch:
            onByteProgress(50, 100)
            throw FakePrefetchError.hashMismatch
        case .blockUntilCancelled:
            started.signal()
            try await suspension.wait()
        }
    }
}

/// Prefetcher that records the ORDER in which each model's download body begins
/// and blocks each one on a per-model gate the test releases explicitly. Lets a
/// priority-ordering test assert which queued request the scheduler dispatches
/// next when an in-flight slot frees.
final class GatedPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _startOrder: [String] = []
    /// One-shot gate per model: a download body parks here until released.
    private var gates: [String: AsyncTestLatch] = [:]
    /// Signalled each time a NEW download body starts (so the test can wait for
    /// the in-flight one to actually be running before enqueuing the rest).
    let bodyStarted = AsyncTestLatch()

    var startOrder: [String] { lock.lock(); defer { lock.unlock() }; return _startOrder }

    /// Release the (single) in-flight model so its download completes, freeing
    /// the slot for the scheduler to dispatch the next queued waiter.
    func release(_ modelId: String) {
        let gate: AsyncTestLatch = lock.withLock {
            if let g = gates[modelId] { return g }
            let g = AsyncTestLatch()
            gates[modelId] = g
            return g
        }
        gate.signal()
    }

    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        let gate: AsyncTestLatch = lock.withLock {
            _startOrder.append(modelID)
            if let g = gates[modelID] { return g }
            let g = AsyncTestLatch()
            gates[modelID] = g
            return g
        }
        bodyStarted.signal()
        await gate.wait()
        try Task.checkCancellation()
    }
}

/// A cancellation-aware suspension used by fakes that must remain in flight
/// until their owning task is cancelled.
final class CancellableTestSuspension: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    func wait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if install(continuation) {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.withLock {
            guard !cancelled else { return true }
            self.continuation = continuation
            return false
        }
    }

    private func cancel() {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            cancelled = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}

/// Manually advanced sleep seam for timeout/backoff tests.
final class ControlledTestSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [AsyncTestLatch] = []
    private let requested = AsyncTestLatch()

    func sleep(_ duration: Duration) async throws {
        _ = duration
        let gate = AsyncTestLatch()
        lock.withLock { gates.append(gate) }
        requested.signal()
        await gate.wait()
        try Task.checkCancellation()
    }

    func waitForRequest() async {
        await requested.wait()
    }

    func resumeNext() {
        lock.lock()
        let gate = gates.removeFirst()
        lock.unlock()
        gate.signal()
    }
}

func makeCoordinator(
    prefetcher: any ModelPrefetcher,
    preCheck: @escaping @Sendable (String) async -> PrefetchPreCheck = { _ in .needsFetch },
    onVerified: @escaping @Sendable (String) async -> Void = { _ in }
) -> ModelPrefetchCoordinator {
    ModelPrefetchCoordinator(prefetcher: prefetcher, preCheck: preCheck, onVerified: onVerified)
}

// MARK: - Tests

final class AdvertisedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    private let recorded = AsyncTestLatch()

    func record(_ id: String) {
        lock.lock()
        _ids.append(id)
        lock.unlock()
        recorded.signal()
    }

    var ids: [String] { lock.lock(); defer { lock.unlock() }; return _ids }

    func waitUntilRecorded(_ id: String) async {
        while !ids.contains(id) { await recorded.wait() }
    }
}

/// Thread-safe recorder for outbound messages flowing through a `SendHandle`,
/// so tests can assert which `models_update` payloads were emitted. Each entry
/// in `modelsUpdates()` is the `models` array from one emitted update.
final class PrefetchOutboundRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [OutboundMessage] = []
    private var terminalModels = Set<String>()
    private let changed = AsyncTestLatch()

    func record(_ message: OutboundMessage) {
        lock.lock()
        _messages.append(message)
        if case .prefetchModelStatus(let modelId, let status, _, _, _) = message,
           status == .verified || status == .failed
        {
            terminalModels.insert(modelId)
        }
        lock.unlock()
        changed.signal()
    }

    func modelsUpdates() -> [[ModelInfo]] {
        lock.lock(); defer { lock.unlock() }
        return _messages.compactMap { message in
            if case .modelsUpdate(let models) = message { return models }
            return nil
        }
    }

    func waitForTerminal(modelID: String) async {
        while true {
            let done = lock.withLock { terminalModels.contains(modelID) }
            if done { return }
            await changed.wait()
        }
    }

    func waitForModelsUpdate(after count: Int) async {
        while modelsUpdates().count <= count { await changed.wait() }
    }
}

/// Fake prefetcher that succeeds without touching the network — used by the
/// ProviderLoop-level integration test where a valid snapshot is pre-seeded on
/// disk so `applyVerifiedPrefetch`'s scan + weight-hash succeed.
final class NoopSuccessPrefetcher: ModelPrefetcher, @unchecked Sendable {
    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        onByteProgress(10, 10)
    }
}

// MARK: - ProviderLoop integration (real actor, real disk, no GPU/network)

/// Prefetcher that always fails, counting attempts per model id — drives the
/// desired-build retry policy tests.
final class FailingCountingPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private let called = AsyncTestLatch()
    func count(for modelID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[modelID] ?? 0
    }
    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { counts[modelID, default: 0] += 1 }
        called.signal()
        throw ModelCatalogError.downloadFailed("simulated transient network failure")
    }

    func waitForCall() async { await called.wait() }
}

/// Prefetcher that records whether it was actually invoked (asserts the
/// short-circuit path never calls it).
final class TrackingPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { _count += 1 }
    }
}

/// Prefetcher that records every model id whose download body STARTED and then
/// blocks forever (until task cancellation). Lets a reconcile test assert which
/// build a `desired_models` entry actually triggered a fetch for, without racing
/// a completion.
final class RecordingBlockingPrefetcher: ModelPrefetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var _startedIDs: [String] = []
    private let started = AsyncTestLatch()

    var startedIDs: [String] { lock.lock(); defer { lock.unlock() }; return _startedIDs }

    func prefetchToDisk(
        modelID: String,
        onByteProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        let suspension = CancellableTestSuspension()
        lock.withLock { _startedIDs.append(modelID) }
        started.signal()
        try await suspension.wait()
    }

    func waitUntilStarted(_ modelID: String) async {
        while !startedIDs.contains(modelID) { await started.wait() }
    }
}

/// Minimal sink for the short-circuit test.
final class RecordingPrefetchSink: PrefetchStatusSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [(ProviderMessage.PrefetchModelStatus.Status, String?)] = []
    private let terminalSignal = AsyncTestLatch()
    func emit(modelId: String, status: ProviderMessage.PrefetchModelStatus.Status, bytesDone: Int64, bytesTotal: Int64, error: String?) {
        lock.withLock { _events.append((status, error)) }
        if status == .verified || status == .failed { terminalSignal.signal() }
    }
    func terminal() -> (status: ProviderMessage.PrefetchModelStatus.Status, error: String?)? {
        lock.withLock { _events.last(where: { $0.0 == .verified || $0.0 == .failed }) }
    }
    func waitForTerminal() async -> (status: ProviderMessage.PrefetchModelStatus.Status, error: String?) {
        if let terminal = terminal() { return terminal }
        await terminalSignal.wait()
        return terminal()!
    }
}
