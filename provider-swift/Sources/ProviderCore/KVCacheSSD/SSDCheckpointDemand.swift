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

/// The coordinator's fleet-wide repeat observation for one remote request,
/// forwarded as `cache_repeated_prefix_tokens`. It is a token count only; it
/// carries no key, hash, boundary or prompt-derived identifier.
public struct SSDCheckpointDonationDemand: Sendable, Equatable {
    /// Longest geometric block boundary another plan shared within the
    /// coordinator's routing TTL; 0 when none did.
    public let repeatedPrefixTokens: Int

    public init(repeatedPrefixTokens: Int) {
        self.repeatedPrefixTokens = max(0, repeatedPrefixTokens)
    }
}

extension SSDCheckpointDemand {
    /// Complete-checkpoint write admission. Every completed prompt is offered
    /// for donation, but the same prefix is novel on each of the hundreds of
    /// providers load spreading sends it to, so provider-local history alone
    /// cannot see fleet-wide repeats and novel writes drained the daily budget.
    ///
    /// Rule: with a coordinator demand hint, write only when the observed
    /// repeated prefix reaches the store's effective-token floor OR this
    /// provider's own tag history has seen the tag before (within the cache
    /// TTL). Without a hint (older coordinator, standalone/local serving) the
    /// legacy behaviour is kept: write. Durable duplicates never reach this
    /// gate; they revalidate and settle `already_durable` as before.
    static func admitsWrite(
        demand: SSDCheckpointDonationDemand?, localRepeat: Bool, minEffectiveTokens: Int
    ) -> Bool {
        guard let demand else { return true }
        return localRepeat || demand.repeatedPrefixTokens >= max(1, minEffectiveTokens)
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
                // and `admitsWrite` falls back to the legacy write, so the cost
                // is one extra checkpoint write, never a lost one.
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
