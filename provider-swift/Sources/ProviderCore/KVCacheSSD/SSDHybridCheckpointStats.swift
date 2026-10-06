import Foundation

public struct SSDHybridCheckpointStats: Sendable {
    public var stageConsumptions = 0
    public var misses = 0
    public var consumedPrefixTokens = 0
    public var stages = 0
    public var stagedBytesInUse = 0
    public var peakStagingReservationBytes = 0
    /// Shared-process mode owns provider Data/crypto buffers separately from
    /// native packing scratch. Includes queued envelopes until actual close.
    public var writeHostBytesInUse = 0
    public var peakWriteHostBytes = 0
    public var writeHostCapacityRefusals = 0
    public var maximumSegmentBytes = 0
    public var filesRead = 0
    public var bytesRead = 0
    public var stageReadBytes = 0
    public var donationReadBytes = 0
    public var filesWritten = 0
    public var bytesWritten = 0
    public var writesDropped = 0
    /// Speculative writes that gave their disk room back after I/O began:
    /// revoked for a proven write, or refused at publish or commit because
    /// the room was gone. Their bytes are not on disk; the write budget
    /// they were charged is not refunded.
    public var speculativeWritesYielded = 0
    public var corruptDropped = 0
    /// Successful removals by the active-store disk-budget enforcer.
    /// Whole-root sweep removals are reported separately, process-wide.
    public var evictions = 0
    /// Recurrent donors whose capture stopped because one of their prompt
    /// ranges ran in a packed prefill cohort (`CBv2RecurrentCheckpointGeometry
    /// .DisarmReason.packed`), once per request. Counts requests, including
    /// prompts below the store's effective-token floor that could never have
    /// written a file; geometry (non-contiguous, overrun), preemption and
    /// media disarms are not counted.
    public var recurrentCaptureDisarmedPacked = 0
    public var entries = 0
    public var bytesOnDisk = 0
    /// Cumulative wall time in write jobs, including authentication/maintenance.
    public var writeMilliseconds = 0.0
    /// Cumulative pre-submit stage wall time, including refused attempts.
    public var stageMilliseconds = 0.0
}

final class SSDHybridCheckpointStatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = SSDHybridCheckpointStats()
    func update(_ body: (inout SSDHybridCheckpointStats) -> Void) { lock.withLock { body(&value) } }
    func snapshot() -> SSDHybridCheckpointStats { lock.withLock { value } }
}

/// Finite work ownership for teardown, including actor-based budget refunds.
final class SSDCheckpointActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func begin() { lock.withLock { pending += 1 } }
    func end() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            precondition(pending > 0)
            pending -= 1
            guard pending == 0 else { return [] }
            defer { waiters.removeAll() }
            return waiters
        }
        ready.forEach { $0.resume() }
    }
    func waitUntilDrained() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock {
                if pending == 0 { return true }
                waiters.append(continuation)
                return false
            }
            if immediate { continuation.resume() }
        }
    }
}
