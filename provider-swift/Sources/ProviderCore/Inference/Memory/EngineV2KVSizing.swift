// Copyright © 2026 Eigen Labs.
//
// Per-token KV byte-cost resolution for the ContinuousBatchingV2 bridge.
//
// The v2 engine builds UNQUANTIZED native-float `CBv2LayerCache`s: KV
// quantization was removed from the product in v0.8.0, so there is exactly
// one per-token cost. The sizing snapshot is an all-fp16 baseline; slot
// assembly adds GPT-OSS's fp32 owning-full-row delta before
// heartbeat/shared-budget publication.

import Foundation

enum EngineV2KVSizing {
    /// Conservative residual KV capacity for one engine, sized against the
    /// whole process. New engines receive runtime-resizable grants from
    /// `resliceGrants`; this helper remains the heartbeat safety clamp and a
    /// pure policy seam for tests. It derives capacity from the same
    /// `UnifiedMemoryCap` policy as the load gate:
    ///
    ///     ceiling = kvBudgetBytes(Σ all resident weights, incl. the new
    ///               model) − Σ(existing v2 engines' admission ceilings)
    ///
    /// so the reported residual cannot exceed cap − weights − other grants.
    ///
    /// `configReserveBytes` is the operator's `memory_reserve_gb` (round-3
    /// PR#499 P2): the shared `GlobalKVCacheBudget` and load/free-for-load
    /// paths hold back `max(configReserve, physical − cap)`, so the static v2
    /// ceiling must derive from the SAME effective cap — otherwise a bridge on
    /// a 16/32 GiB box (where the default 4 GiB reserve exceeds the
    /// cap-implied reserve) advertises and privately admits a budget the
    /// shared gate then rejects post-acceptance.
    ///
    /// Pure policy (no MLX globals) so it is unit-testable; `physicalBytes`
    /// defaults to the machine's real memory in production.
    static func engineKVBytesCapacity(
        newModelWeightBytes: Int,
        coResidentWeightBytes: UInt64,
        existingEngineKVCapacities: [Int],
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let totalWeights = saturatingAdd(
            UInt64(max(0, newModelWeightBytes)), coResidentWeightBytes)
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physicalBytes, residentWeightBytes: totalWeights,
            activationReserveBytes: activationReserveBytes,
            configReserveBytes: configReserveBytes)
        let granted = existingEngineKVCapacities.reduce(UInt64(0)) {
            saturatingAdd($0, UInt64(max(0, $1)))
        }
        let remaining = fleetBudget > granted ? fleetBudget - granted : 0
        return Int(min(remaining, UInt64(Int.max)))
    }

    /// CURRENT KV byte budget for an EXISTING v2 engine — the HEARTBEAT
    /// figure, not an engine resize (round-3 PR#499 P2).
    ///
    /// Runtime re-slicing normally keeps grants current. This heartbeat clamp
    /// recomputes the residual from current fleet residency and reports the
    /// smaller of the engine's current grant and that residual, so transient
    /// drift cannot advertise capacity the process-wide gate would reject.
    static func liveEngineKVBytesBudget(
        grantedKVBytesCapacity: Int,
        totalResidentWeightBytes: UInt64,
        otherEngineKVCapacities: [Int],
        activationReserveBytes: UInt64? = nil,
        configReserveBytes: UInt64 = 0,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let current = engineKVBytesCapacity(
            newModelWeightBytes: 0,
            coResidentWeightBytes: totalResidentWeightBytes,
            existingEngineKVCapacities: otherEngineKVCapacities,
            activationReserveBytes: activationReserveBytes,
            configReserveBytes: configReserveBytes,
            physicalBytes: physicalBytes)
        return min(max(0, grantedKVBytesCapacity), current)
    }

    private static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }
}
