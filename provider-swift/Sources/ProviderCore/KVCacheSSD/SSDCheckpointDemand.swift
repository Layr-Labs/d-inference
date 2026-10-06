import Foundation
import MLXLMCommon

/// Bounded, volatile demand for opaque complete-checkpoint tags. It contains no
/// prompt text or tokens; tags already bind the model identity and cache scope.
/// A repeat is a write-priority hint, never authentication or a cache hit.
final class SSDCheckpointDemand: @unchecked Sendable {
    static let repeatReserveFraction = 0.1

    private let lock = NSLock()
    private let limit: Int
    private let ttlSeconds: Int64
    private var lastSeen: [Data: Int64] = [:]

    init(limit: Int = 4096, ttlSeconds: Int64) {
        self.limit = max(1, limit)
        self.ttlSeconds = max(1, ttlSeconds)
    }

    func observe(_ tag: Data, now: Int64) -> Bool {
        lock.withLock {
            let repeated: Bool
            if let previous = lastSeen[tag] {
                let (age, overflow) = now.subtractingReportingOverflow(previous)
                repeated = !overflow && age >= 0 && age < ttlSeconds
            } else {
                repeated = false
            }
            if lastSeen[tag] == nil, lastSeen.count >= limit,
                let oldest = lastSeen.min(by: { $0.value < $1.value })?.key {
                lastSeen.removeValue(forKey: oldest)
            }
            lastSeen[tag] = now
            return repeated
        }
    }

    var count: Int { lock.withLock { lastSeen.count } }
}

/// The coordinator's demand observation for one remote request: a fleet-wide
/// repeat forwarded as `cache_repeated_prefix_tokens`, or first sight forwarded
/// as `cache_first_sight_tokens`. Both are token counts only; they carry no
/// key, hash or content-derived value. First sight is a boundary position
/// derived from the prompt's length alone.
public struct SSDCheckpointDonationDemand: Sendable, Equatable {
    /// Deepest boundary another plan shared within the coordinator's routing
    /// TTL, among the multiples of 1,024 tokens and final boundaries the
    /// coordinator observes; 0 when none did.
    public let repeatedPrefixTokens: Int
    /// Depth of the prompt's own deepest 1,024-token boundary, sent only
    /// while no plan has repeated it; 0 otherwise. Nobody has asked for this
    /// prefix twice yet, so a checkpoint written for it is speculative.
    public let firstSightTokens: Int

    public init(repeatedPrefixTokens: Int, firstSightTokens: Int = 0) {
        self.repeatedPrefixTokens = max(0, repeatedPrefixTokens)
        self.firstSightTokens = max(0, firstSightTokens)
    }

    /// The depth the engine keeps as the donor's fork target. The coordinator
    /// sends at most one positive count, so this is whichever it sent.
    var checkpointTargetTokens: Int { max(repeatedPrefixTokens, firstSightTokens) }
}

extension SSDCheckpointDemand {
    /// Complete-checkpoint write admission. Every completed prompt is offered
    /// for donation, but the same prefix is novel on each of the hundreds of
    /// providers load spreading sends it to, so provider-local history alone
    /// cannot see fleet-wide repeats and novel writes drained the daily budget.
    ///
    /// Rule, per request; nil skips the write of a checkpoint that is not yet
    /// durable (`skipped_novel`):
    /// - this provider's own tag history has seen the tag before (within the
    ///   cache TTL): `repeated`;
    /// - no hint (older coordinator, standalone/local serving): the legacy
    ///   behaviour is kept, a `novel` write;
    /// - the observed repeated prefix reaches the store's effective-token
    ///   floor: `novel`;
    /// - only first sight reaches the floor: `speculative`, unless the request
    ///   `restored` a checkpoint from this store, which proves the prefix was
    ///   written here for an earlier request and makes the write `novel`;
    /// - otherwise skip.
    ///
    /// A durable duplicate is not skipped; it revalidates and settles
    /// `already_durable` as before.
    static func writeClass(
        demand: SSDCheckpointDonationDemand?, localRepeat: Bool, restored: Bool, minEffectiveTokens: Int
    ) -> SSDWriteClass? {
        if localRepeat { return .repeated }
        guard let demand else { return .novel }
        let floor = max(1, minEffectiveTokens)
        if demand.repeatedPrefixTokens >= floor { return .novel }
        guard demand.firstSightTokens >= floor else { return nil }
        return restored ? .novel : .speculative
    }
}

/// Per-request demand hints keyed by the prefix-cache receipt ID the engine
/// passes back through `CBv2CompletePrefixCache.donate`. Bounded and volatile:
/// the bridge registers a hint at submit and discards it when staging
/// completes, is abandoned, or the receipt is dropped. Holding only a small
/// integer per in-flight request, it stores no prompt data.
final class SSDCheckpointDemandHints: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var hints: [CBv2RequestID: SSDCheckpointDonationDemand] = [:]
    private var order: [CBv2RequestID] = []

    init(limit: Int = 1024) {
        self.limit = max(1, limit)
    }

    func register(_ demand: SSDCheckpointDonationDemand, requestID: CBv2RequestID) {
        lock.withLock {
            if hints.updateValue(demand, forKey: requestID) == nil {
                order.append(requestID)
                // Terminal cleanup normally keeps this far below the bound. An
                // evicted or leaked hint fails OPEN: `demand(for:)` returns nil
                // and `writeClass` falls back to the legacy `novel` write. A
                // checkpoint is never lost that way, but a fleet-novel request
                // then writes and a first-sight request leaves the
                // speculative class.
                while order.count > limit, let oldest = order.first {
                    order.removeFirst()
                    hints.removeValue(forKey: oldest)
                }
            }
        }
    }

    func demand(for requestID: CBv2RequestID?) -> SSDCheckpointDonationDemand? {
        guard let requestID else { return nil }
        return lock.withLock { hints[requestID] }
    }

    func discard(_ requestID: CBv2RequestID) {
        lock.withLock {
            guard hints.removeValue(forKey: requestID) != nil else { return }
            order.removeAll { $0 == requestID }
        }
    }

    func removeAll() {
        lock.withLock {
            hints.removeAll()
            order.removeAll()
        }
    }

    var count: Int { lock.withLock { hints.count } }
}
