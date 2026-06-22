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

    public init() {}

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
            usageGaps: usageGaps
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
}

// MARK: - os_unfair_lock wrapper (Sendable-safe)

private final class OSAllocatedUnfairLock: @unchecked Sendable {
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

/// Tracks the last pong time. Updated from URLSessionWebSocketTask's sendPing
/// completion handler (runs on an arbitrary queue) and read from the ping
/// task on the cooperative thread pool.
internal final class PongTracker: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var lastPong = CFAbsoluteTimeGetCurrent()

    func recordPong() {
        lock.withLock { lastPong = CFAbsoluteTimeGetCurrent() }
    }

    func elapsed() -> TimeInterval {
        lock.withLock { CFAbsoluteTimeGetCurrent() - lastPong }
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

