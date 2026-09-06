import Foundation

/// One coherent process ledger observation. C and M overlap: admission uses
/// active + cache + (charged - materialized), subject to cap/reserve/OS limits.
/// This reports ownership; it never grants capacity or authorizes cache reuse.
public struct ProcessMemoryTelemetry: Codable, Sendable, Equatable {
    public var generation: UInt64 = 0
    public var sampleSeq: UInt64 = 0
    public var sampleAgeMs: UInt64 = 0
    public var policyEpoch: UInt64 = 0
    public var capBytes: UInt64 = 0
    public var activationReserveBytes: UInt64 = 0
    public var activeBytes: UInt64 = 0
    public var cacheBytes: UInt64 = 0
    public var chargedBytes: UInt64 = 0
    public var materializedBytes: UInt64 = 0
    public var unmaterializedBytes: UInt64 = 0
    public var remainingBytes: UInt64 = 0
    public var commitmentDebtBytes: UInt64 = 0
    public var ownerCount: UInt64 = 0
    public var closingOwnerCount: UInt64 = 0
    public var systemAvailableBytes: UInt64?
    // Native clock is local-only. Heartbeat stamping ages the captured value
    // without resampling the ledger or treating another send as new evidence.
    var capturedUptimeNanoseconds: UInt64?

    enum CodingKeys: String, CodingKey {
        case generation = "generation"
        case sampleSeq = "sample_seq"
        case sampleAgeMs = "sample_age_ms"
        case policyEpoch = "policy_epoch"
        case capBytes = "cap_bytes"
        case activationReserveBytes = "activation_reserve_bytes"
        case activeBytes = "active_bytes"
        case cacheBytes = "cache_bytes"
        case chargedBytes = "charged_bytes"
        case materializedBytes = "materialized_bytes"
        case unmaterializedBytes = "unmaterialized_bytes"
        case remainingBytes = "remaining_bytes"
        case commitmentDebtBytes = "commitment_debt_bytes"
        case ownerCount = "owner_count"
        case closingOwnerCount = "closing_owner_count"
        case systemAvailableBytes = "system_available_bytes"
    }

    func agedForHeartbeat(now: UInt64) -> Self? {
        guard let capturedUptimeNanoseconds else { return self }
        guard now >= capturedUptimeNanoseconds else { return nil }
        var result = self
        result.sampleAgeMs = max(sampleAgeMs,
            min((now - capturedUptimeNanoseconds) / 1_000_000, (1 << 53) - 1))
        return result
    }
}
