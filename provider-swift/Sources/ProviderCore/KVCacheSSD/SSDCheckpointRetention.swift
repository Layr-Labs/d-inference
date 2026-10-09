import Foundation
import MLXLMCommon

/// Least measured benefit per stored byte is evicted first; evidence-free
/// entries preserve deterministic LRU order. No score extends sliding TTL.
struct SSDEvictionPriority: Comparable, Sendable {
    var probationary = false
    let savedMillisPerByte: Double
    let lastAccess: Int64
    let tieBreak: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.probationary != rhs.probationary { return !lhs.probationary }
        if lhs.savedMillisPerByte != rhs.savedMillisPerByte {
            return lhs.savedMillisPerByte < rhs.savedMillisPerByte
        }
        if lhs.lastAccess != rhs.lastAccess { return lhs.lastAccess < rhs.lastAccess }
        return lhs.tieBreak < rhs.tieBreak
    }
}

/// Decayed sum of successful adoption benefit, not a claimed hit probability.
/// One small scalar record lives inside each existing index entry. Restarts,
/// removals and replacements discard the record; nothing goes on disk/wire.
struct SSDCheckpointRetentionValue: Sendable {
    static let halfLifeSeconds: Double = 300
    static let probationSeconds: Int64 = 30
    private var savedMillis = 0.0
    private var observedAt: Int64?

    func value(now: Int64) -> Double {
        guard let observedAt, now >= observedAt else { return 0 }
        let (age, overflow) = now.subtractingReportingOverflow(observedAt)
        guard !overflow else { return 0 }
        return savedMillis * exp2(-Double(age) / Self.halfLifeSeconds)
    }

    func isProbationary(writtenAt: Int64, now: Int64) -> Bool {
        let (age, overflow) = now.subtractingReportingOverflow(writtenAt)
        return observedAt == nil && !overflow && age >= 0 && age < Self.probationSeconds
    }

    mutating func observe(savedMillis benefit: Double, now: Int64) {
        guard benefit.isFinite, benefit > 0 else { return }
        savedMillis = min(1_000_000_000, value(now: now) + min(600_000, benefit))
        observedAt = now
    }
}

/// One submitted request's authenticated stage. Numeric accounting runs on the
/// engine callback without file I/O, MLX arrays, or an actor suspension.
final class SSDCheckpointRetentionReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let record: @Sendable (CBv2Usage) -> Void

    init(record: @escaping @Sendable (CBv2Usage) -> Void) { self.record = record }

    func complete(_ usage: CBv2Usage) {
        let first = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if first { record(usage) }
    }
}

extension SSDHybridCheckpointStore {
    func makeRetentionReceipt(requestID: CBv2RequestID, stageMillis: Double,
                              prefillTokensPerSecond: Double) -> SSDCheckpointRetentionReceipt? {
        guard config.utilityRetentionEnabled, stageMillis.isFinite, stageMillis >= 0,
            prefillTokensPerSecond.isFinite, prefillTokensPerSecond > 0 else { return nil }
        return lock.withLock {
            guard !closed, let proof = authenticatedReceipts[requestID], epochMatches(proof.epoch),
                let stage = stages[requestID], proof.files.count == 1,
                let tag = proof.files.keys.first,
                index.retentionGeneration(tag16: tag) == proof.generation else { return nil }
            let epoch = proof.epoch
            let retentionID = proof.retentionID
            let generation = proof.generation
            let position = stage.manifest.position
            return SSDCheckpointRetentionReceipt { [weak self] usage in
                guard let self else { return }
                self.lock.withLock {
                    guard !self.closed, self.epochMatches(epoch),
                        self.authenticatedReceipts[requestID]?.retentionID == retentionID,
                        usage.prefixCacheOutcome == .hit, usage.prefixCacheTier == .snapshot,
                        usage.prefixCachePrefillTokensSaved == position, position > 0,
                        position <= usage.promptTokens else { return }
                    let benefit = Double(position) * 1000 / prefillTokensPerSecond - stageMillis
                    guard benefit.isFinite, benefit > 0 else { return }
                    let creditedMillis = min(600_000, benefit)
                    guard self.index.creditRetention(tag16: tag, generation: generation,
                        savedMillis: creditedMillis, now: self.config.nowSeconds()) else { return }
                    self.statsBox.update {
                        $0.retentionAdoptions += 1
                        $0.retentionSavedMillis = min(1_000_000_000_000, $0.retentionSavedMillis + creditedMillis)
                    }
                }
            }
        }
    }
}
