// CoordinatorClient shared state: atomic provider stats + provider state, and
// the small Sendable concurrency primitives (unfair lock, pong tracker, atomic).

import Foundation
import Network
#if canImport(os)
import os
#endif

// MARK: - Shared State

public final class AtomicProviderStats: Sendable {
    private let _requestsServed = ManagedAtomic<UInt64>(0)
    private let _tokensGenerated = ManagedAtomic<UInt64>(0)
    private let _cancellationsReceived = ManagedAtomic<UInt64>(0)
    private let _cancellationsBeforeOutput = ManagedAtomic<UInt64>(0)
    private let _cancellationsPartialComplete = ManagedAtomic<UInt64>(0)
    private let _generationErrorsAfterOutput = ManagedAtomic<UInt64>(0)
    private let _chunkEncryptionErrors = ManagedAtomic<UInt64>(0)
    private let _streamClosedWithoutTerminal = ManagedAtomic<UInt64>(0)
    private let _cancelDuringModelLoad = ManagedAtomic<UInt64>(0)
    // Count of completed requests whose usage chunk was missing/zero. Surfaced
    // in the daemon state file so `doctor` can flag a billing under-count.
    private let _usageGaps = ManagedAtomic<UInt64>(0)
    // Profiler cancel-stage counters (slice 2). Bumped at the cancel sites
    // from the request's `RequestProfileBuilder`; reported on the heartbeat
    // as cumulative, delta-merged by the coordinator.
    private let _cancelStagePreAcceptTotal = ManagedAtomic<UInt64>(0)
    private let _cancelStagePreEngineTotal = ManagedAtomic<UInt64>(0)
    private let _cancelStagePrefillTotal = ManagedAtomic<UInt64>(0)
    private let _cancelStageDecodeTotal = ManagedAtomic<UInt64>(0)
    private let _cancelStagePostTerminalTotal = ManagedAtomic<UInt64>(0)
    private let _tokensAfterCancelTotal = ManagedAtomic<UInt64>(0)
    private let _cancelAbortNsSum = ManagedAtomic<UInt64>(0)

    public init() {}

    public var cancelStagePreAcceptTotal: UInt64 { _cancelStagePreAcceptTotal.load() }
    public var cancelStagePreEngineTotal: UInt64 { _cancelStagePreEngineTotal.load() }
    public var cancelStagePrefillTotal: UInt64 { _cancelStagePrefillTotal.load() }
    public var cancelStageDecodeTotal: UInt64 { _cancelStageDecodeTotal.load() }
    public var cancelStagePostTerminalTotal: UInt64 { _cancelStagePostTerminalTotal.load() }
    public var tokensAfterCancelTotal: UInt64 { _tokensAfterCancelTotal.load() }
    public var cancelAbortNsSum: UInt64 { _cancelAbortNsSum.load() }

    /// Bump the cumulative counter for the lifecycle stage a cancel landed in.
    public func incrementCancelStage(_ stage: CancelStage) {
        switch stage {
        case .preAccept: _cancelStagePreAcceptTotal.add(1)
        case .preEngine: _cancelStagePreEngineTotal.add(1)
        case .prefill: _cancelStagePrefillTotal.add(1)
        case .decode: _cancelStageDecodeTotal.add(1)
        case .postTerminal: _cancelStagePostTerminalTotal.add(1)
        case .none, .other: break
        }
    }

    public func addTokensAfterCancel(_ count: UInt64) {
        _tokensAfterCancelTotal.add(count)
    }

    public func addCancelAbortNs(_ ns: UInt64) {
        _cancelAbortNsSum.add(ns)
    }

    public var requestsServed: UInt64 {
        get { _requestsServed.load() }
        set { _requestsServed.store(newValue) }
    }

    public var tokensGenerated: UInt64 {
        get { _tokensGenerated.load() }
        set { _tokensGenerated.store(newValue) }
    }

    public var usageGaps: UInt64 {
        get { _usageGaps.load() }
        set { _usageGaps.store(newValue) }
    }

    public var cancellationsReceived: UInt64 {
        get { _cancellationsReceived.load() }
        set { _cancellationsReceived.store(newValue) }
    }

    public var cancellationsBeforeOutput: UInt64 {
        get { _cancellationsBeforeOutput.load() }
        set { _cancellationsBeforeOutput.store(newValue) }
    }

    public var cancellationsPartialComplete: UInt64 {
        get { _cancellationsPartialComplete.load() }
        set { _cancellationsPartialComplete.store(newValue) }
    }

    public var generationErrorsAfterOutput: UInt64 {
        get { _generationErrorsAfterOutput.load() }
        set { _generationErrorsAfterOutput.store(newValue) }
    }

    public var chunkEncryptionErrors: UInt64 {
        get { _chunkEncryptionErrors.load() }
        set { _chunkEncryptionErrors.store(newValue) }
    }

    public var streamClosedWithoutTerminal: UInt64 {
        get { _streamClosedWithoutTerminal.load() }
        set { _streamClosedWithoutTerminal.store(newValue) }
    }

    public var cancelDuringModelLoad: UInt64 {
        get { _cancelDuringModelLoad.load() }
        set { _cancelDuringModelLoad.store(newValue) }
    }

    public func incrementRequestsServed() {
        _requestsServed.add(1)
    }

    public func addTokensGenerated(_ count: UInt64) {
        _tokensGenerated.add(count)
    }

    public func incrementUsageGaps() {
        _usageGaps.add(1)
    }

    public func incrementCancellationsReceived() {
        _cancellationsReceived.add(1)
    }

    public func incrementCancellationsBeforeOutput() {
        _cancellationsBeforeOutput.add(1)
    }

    public func incrementCancellationsPartialComplete() {
        _cancellationsPartialComplete.add(1)
    }

    public func incrementGenerationErrorsAfterOutput() {
        _generationErrorsAfterOutput.add(1)
    }

    public func incrementChunkEncryptionErrors() {
        _chunkEncryptionErrors.add(1)
    }

    public func incrementStreamClosedWithoutTerminal() {
        _streamClosedWithoutTerminal.add(1)
    }

    public func incrementCancelDuringModelLoad() {
        _cancelDuringModelLoad.add(1)
    }

    public func snapshot() -> ProviderStats {
        ProviderStats(
            requestsServed: requestsServed,
            tokensGenerated: tokensGenerated,
            cancellationsReceived: cancellationsReceived,
            cancellationsBeforeOutput: cancellationsBeforeOutput,
            cancellationsPartialComplete: cancellationsPartialComplete,
            generationErrorsAfterOutput: generationErrorsAfterOutput,
            chunkEncryptionErrors: chunkEncryptionErrors,
            streamClosedWithoutTerminal: streamClosedWithoutTerminal,
            cancelDuringModelLoad: cancelDuringModelLoad,
            usageGaps: usageGaps,
            cancelStagePreAcceptTotal: cancelStagePreAcceptTotal,
            cancelStagePreEngineTotal: cancelStagePreEngineTotal,
            cancelStagePrefillTotal: cancelStagePrefillTotal,
            cancelStageDecodeTotal: cancelStageDecodeTotal,
            cancelStagePostTerminalTotal: cancelStagePostTerminalTotal,
            tokensAfterCancelTotal: tokensAfterCancelTotal,
            cancelAbortNsSum: cancelAbortNsSum
        )
    }
}

/// Lock-free atomic wrapper using os_unfair_lock for shared mutable state
/// accessed from both the heartbeat tick and the main event loop.
public final class ProviderState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var _inferenceActive: Bool = false
    private var _currentModel: String? = nil
    private var _warmModels: [String] = []
    private var _currentModelHash: String? = nil
    private var _backendCapacity: BackendCapacity? = nil
    private var _prefixCacheV2Sources: [String: SSDPrefixCache] = [:]
    private var _prefixCacheStatuses: [PrefixCacheModelStatus] = []
    private var _prefixCacheRuntimeIdentityAvailable = true
    private var _publishedCapacity: BackendCapacity? = nil
    private var _capacitySeq: UInt64 = 0
    private var _refusingNewWork = false

    /// Bounded per-(model, warm/cold, prompt-bucket, batch-bucket) end-to-end
    /// TTFT statistics from completed real requests, fed by the ProviderLoop's
    /// streaming path and read lock-free-ish by the quote path. Lives here
    /// because ProviderState is the one object both the loop actor and the
    /// CoordinatorClient actor already share without an actor hop.
    public let ttftTracker = TTFTQuantileTracker()

    public init() {}

    public var inferenceActive: Bool {
        get { lock.withLock { _inferenceActive } }
        set { lock.withLock { _inferenceActive = newValue } }
    }

    public var currentModel: String? {
        get { lock.withLock { _currentModel } }
        set { lock.withLock { _currentModel = newValue } }
    }

    public var warmModels: [String] {
        get { lock.withLock { _warmModels } }
        set { lock.withLock { _warmModels = newValue } }
    }

    public var currentModelHash: String? {
        get { lock.withLock { _currentModelHash } }
        set { lock.withLock { _currentModelHash = newValue } }
    }

    public var backendCapacity: BackendCapacity? {
        get { lock.withLock { _backendCapacity } }
        set { lock.withLock { _backendCapacity = newValue } }
    }

    /// Mirror of the ProviderLoop's "refuse new work" windows (update drain,
    /// shutdown) for the quote path, which runs on the CoordinatorClient and
    /// must not hop to the loop actor to learn what the live gate would do.
    /// The loop writes it at the same transitions that flip its own gates, so
    /// quotes and admissions refuse in the same windows.
    public var refusingNewWork: Bool {
        get { lock.withLock { _refusingNewWork } }
        set { lock.withLock { _refusingNewWork = newValue } }
    }

    /// The capacity payload of the LAST heartbeat actually sent on the
    /// current connection, seq-stamped (routing v2). This is the lock-free
    /// published snapshot the capacity-quote path reads: quotes must be
    /// computed from state the coordinator can order by `capacity_seq`, never
    /// from a rebuild it has not seen — and reading it here costs one unfair
    /// lock, no hop to the inference engine actor, no blocking of
    /// admission/decode.
    public var publishedCapacity: BackendCapacity? {
        lock.withLock { _publishedCapacity }
    }

    /// Stamp the given heartbeat capacity payload with the next per-connection
    /// `capacity_seq` (starting at 1) and publish it as the quote snapshot,
    /// atomically. Called for EVERY outbound heartbeat — 5s baseline and
    /// event-triggered alike — so seq is dense and strictly monotonic within a
    /// connection. A nil payload (capacity not yet rebuilt after startup) is
    /// passed through without burning a seq: `capacity_seq` only ever rides an
    /// actual `backend_capacity` object.
    public func stampAndPublishHeartbeatCapacity(
        _ capacity: BackendCapacity?
    ) -> BackendCapacity? {
        guard var capacity else { return nil }
        return lock.withLock {
            _capacitySeq &+= 1
            capacity.capacitySeq = _capacitySeq
            _publishedCapacity = capacity
            return capacity
        }
    }

    /// Reset the capacity-seq session on a fresh coordinator connection: the
    /// contract is per-connection monotonicity starting at 1, and the stale
    /// published snapshot must not answer quotes for a connection whose
    /// coordinator never saw it.
    public func resetCapacitySession() {
        lock.withLock {
            _capacitySeq = 0
            _publishedCapacity = nil
        }
    }

    func setPrefixCacheSnapshot(
        sources: [String: SSDPrefixCache],
        statuses: [PrefixCacheModelStatus],
        runtimeIdentityAvailable: Bool
    ) {
        lock.withLock {
            _prefixCacheV2Sources = sources
            _prefixCacheStatuses = statuses
            _prefixCacheRuntimeIdentityAvailable = runtimeIdentityAvailable
        }
    }

    func prefixCacheV2Advertisement() -> (
        protocolVersion: Int,
        models: [PrefixCacheV2Capability],
        statuses: [PrefixCacheModelStatus],
        donationOutcomes: [PrefixCacheDonationOutcomeCount]
    ) {
        let snapshot = lock.withLock {
            (
                sources: _prefixCacheV2Sources,
                statuses: _prefixCacheStatuses,
                runtimeIdentityAvailable: _prefixCacheRuntimeIdentityAvailable
            )
        }
        let sources = snapshot.sources
        var models: [PrefixCacheV2Capability] = []
        var statuses = snapshot.statuses.map { status in
            let current: PrefixCacheModelStatus
            if let source = sources[status.modelId] {
                let advertisement = source.prefixCacheAdvertisement(base: status)
                if let capability = advertisement.capability {
                    models.append(capability)
                }
                current = advertisement.status
            } else {
                current = status
            }
            return snapshot.runtimeIdentityAvailable
                ? current : current.withoutRuntimeIdentity()
        }.sorted { $0.modelId < $1.modelId }
        if !snapshot.runtimeIdentityAvailable {
            models.removeAll(keepingCapacity: true)
        }
        let capableModels = Set(models.map(\.modelId))
        statuses = statuses.filter { status in
            status.state != .ready ||
                (status.isConcreteReady && capableModels.contains(status.modelId))
        }
        let readyModels = Set(
            statuses.lazy.filter(\.isConcreteReady).map(\.modelId))
        models.removeAll { !readyModels.contains($0.modelId) }
        models.sort { $0.modelId < $1.modelId }
        return (
            models.isEmpty || !snapshot.runtimeIdentityAvailable ? 1 : 2,
            models,
            statuses,
            PrefixCacheDonationTelemetry.shared.snapshot()
        )
    }
}

// MARK: - os_unfair_lock wrapper (Sendable-safe)

internal final class OSAllocatedUnfairLock: @unchecked Sendable {
    private let _lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        _lock = .allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }

    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }

    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return body()
    }
}

// MARK: - PongTracker (thread-safe timestamp for ping/pong timeout)

/// Tracks the last pong time. Updated when a pong frame arrives over the
/// NWConnection (NWProtocolWebSocket surfaces the pong on the connection's
/// receive queue, an arbitrary queue) and read from the ping task on the
/// cooperative thread pool.
///
/// Monotonic (`ContinuousClock`, mach_continuous_time), not wall clock: a
/// forward wall-clock step > 30 s (NTP, a manual clock change) used to read
/// as a pong timeout on a live socket — tearing the session down and 502-ing
/// every in-flight request — and a backward step hid a real timeout.
/// ContinuousClock still advances across sleep on Darwin, so the post-wake
/// detection this feeds is unchanged. `now` is injectable for tests.
internal final class PongTracker: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let now: @Sendable () -> ContinuousClock.Instant
    private var lastPong: ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
        self.lastPong = now()
    }

    func recordPong() {
        let at = now()
        lock.withLock { lastPong = at }
    }

    func elapsed() -> Duration {
        let at = now()
        return lock.withLock { at - lastPong }
    }
}

// MARK: - ShutdownFlag

/// Thread-safe shutdown state shared between the CoordinatorClient actor and
/// its connection child tasks. A lock-backed Bool is enough here and avoids a
/// per-frame actor hop in the outbound WebSocket writer.
internal final class ShutdownFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var requested = false

    var isRequested: Bool {
        lock.withLock { requested }
    }

    func request() {
        lock.withLock { requested = true }
    }
}

// MARK: - ManagedAtomic

private final class ManagedAtomic<Value: FixedWidthInteger>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    init(_ initial: Value) {
        self.value = initial
    }

    func load() -> Value {
        lock.withLock { value }
    }

    func store(_ value: Value) {
        lock.withLock { self.value = value }
    }

    func add(_ delta: Value) {
        lock.withLock { value &+= delta }
    }
}
