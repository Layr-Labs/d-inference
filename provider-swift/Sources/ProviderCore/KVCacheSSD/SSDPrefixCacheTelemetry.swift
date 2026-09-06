// Copyright © 2026 Eigen Labs.

import Foundation

extension PrefixCacheTelemetry {
    init(attention s: SSDPrefixCacheStats) {
        self.init(kind: .attentionBlocks)
        entries = UInt64(clamping: s.entries)
        diskBytes = UInt64(clamping: s.bytesOnDisk)
        stagingBytes = UInt64(clamping: s.stagedBytesInUse)
        stagesTotal = UInt64(clamping: s.stages)
        filesWrittenTotal = UInt64(clamping: s.blocksWritten)
        writtenBytesTotal = UInt64(clamping: s.bytesWritten)
        donationDropsTotal = UInt64(clamping: s.donationsDropped)
        corruptDropsTotal = UInt64(clamping: s.corruptDropped)
        evictionsTotal = UInt64(clamping: s.evictions)
        ttlExpiredTotal = UInt64(clamping: s.ttlExpired)
    }

    init(complete s: SSDHybridCheckpointStats) {
        self.init(kind: .completeCheckpoint)
        entries = UInt64(clamping: s.entries)
        diskBytes = UInt64(clamping: s.bytesOnDisk)
        stagingBytes = UInt64(clamping: s.stagedBytesInUse)
        stagesTotal = UInt64(clamping: s.stages)
        filesWrittenTotal = UInt64(clamping: s.filesWritten)
        writtenBytesTotal = UInt64(clamping: s.bytesWritten)
        donationDropsTotal = UInt64(clamping: s.writesDropped)
        corruptDropsTotal = UInt64(clamping: s.corruptDropped)
        evictionsTotal = UInt64(clamping: s.evictions)
        io = PrefixCacheIOTelemetry(
            stagingPeakBytes: UInt64(clamping: s.peakStagingReservationBytes),
            filesReadTotal: UInt64(clamping: s.filesRead),
            readBytesTotal: UInt64(clamping: s.bytesRead),
            stageReadBytesTotal: UInt64(clamping: s.stageReadBytes),
            donationReadBytesTotal: UInt64(clamping: s.donationReadBytes),
            stageUsTotal: Self.microseconds(milliseconds: s.stageMilliseconds),
            writeUsTotal: Self.microseconds(milliseconds: s.writeMilliseconds))
    }

    private static func microseconds(milliseconds: Double) -> UInt64 {
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        // Keep Double -> integer conversion bounded even on a pathological clock.
        return UInt64(min(milliseconds * 1_000, Double(Int64.max / 2)))
    }
}

extension PrefixCacheMaintenanceTelemetry {
    init(_ s: SSDWholeRootMaintainer.Stats) {
        self.init(ttlExpiredTotal: UInt64(clamping: s.ttlExpired),
                  budgetEvictedTotal: UInt64(clamping: s.budgetEvicted),
                  tempRemovedTotal: UInt64(clamping: s.tempFilesRemoved))
    }
}

/// The stats task publishes infrequently; each heartbeat adds a monotonic age.
/// This box owns only scalars and never retains a cache store or request data.
final class SSDPrefixCacheTelemetryBox: @unchecked Sendable {
    private final class Generations: @unchecked Sendable {
        static let shared = Generations()
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 { lock.withLock { value += 1; return value } }
    }
    private let generation = Generations.shared.next()
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var sample: PrefixCacheTelemetry?
    private var sampledAt: ContinuousClock.Instant?
    private var closed = false

    func publish(_ value: PrefixCacheTelemetry, now: ContinuousClock.Instant = .now) {
        lock.withLock {
            guard !closed else { return }
            sequence += 1
            var value = value
            value.generation = generation
            value.sampleSeq = sequence
            value.sampleAgeMs = 0
            sample = value
            sampledAt = now
        }
    }

    func snapshot(now: ContinuousClock.Instant = .now) -> PrefixCacheTelemetry? {
        lock.withLock {
            guard var value = sample, let sampledAt else { return nil }
            let duration = sampledAt.duration(to: now).components
            let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
            value.sampleAgeMs = UInt64(max(0, min(milliseconds, Double(Int64.max / 2))))
            return value
        }
    }

    func close() { lock.withLock { closed = true; sample = nil; sampledAt = nil } }
}
