// Copyright © 2026 Eigen Labs.
//
// Per-token KV byte-cost resolution for the ContinuousBatchingV2 bridge.
//
// The v2 engine builds UNQUANTIZED (fp16) `CBv2LayerCache`s regardless of the
// provider's `kv_quant` setting — KV-quant is not composed with EngineV2
// (`EngineV2Factory.makeProductionEngine` always uses `CBv2LayerCache`). A
// stale or test sizing input can still carry a quantized `kvBytesPerToken`
// rate that is 2–4× smaller than fp16. Feeding that rate into the bridge would
// make heartbeat token budgets (`kvBytesCapacity / kvBytesPerToken`) and
// active-token counts (`kvBytesInUse / kvBytesPerToken`) OVERSTATE capacity by
// the same 2–4×, and would under-size the shared-budget KV reservation.
//
// `resolve` is retained as compatibility test math for the removed quantized
// input shape. Production v0.7.5 rejects kv_quant intent with a warning and
// takes the fp16 rate directly from SlotSizingSnapshot.

import Foundation

enum EngineV2KVSizing {
    /// Compatibility math for a historical quantized/fp16 input pair.
    ///
    /// - Parameters:
    ///   - quantizedRate: a candidate `kvBytesPerToken` input.
    ///   - fp16Rate: the unquantized cost the EngineV2 caches consume.
    /// - Returns: `rate` = fp16 cost to size the bridge with (falls back to
    ///   the quantized rate only when fp16 is unknown/0); `warnKVQuantUnsupported`
    ///   = true iff kv_quant engaged (quantized rate strictly below fp16).
    static func resolve(
        quantizedRate: Int, fp16Rate: Int
    ) -> (rate: Int, warnKVQuantUnsupported: Bool) {
        let rate = fp16Rate > 0 ? fp16Rate : quantizedRate
        let warn = fp16Rate > 0 && quantizedRate > 0 && quantizedRate < fp16Rate
        return (rate, warn)
    }

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
        configReserveBytes: UInt64 = 0,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let totalWeights = saturatingAdd(
            UInt64(max(0, newModelWeightBytes)), coResidentWeightBytes)
        let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
            physicalBytes: physicalBytes, residentWeightBytes: totalWeights,
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
        configReserveBytes: UInt64 = 0,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Int {
        let current = engineKVBytesCapacity(
            newModelWeightBytes: 0,
            coResidentWeightBytes: totalResidentWeightBytes,
            existingEngineKVCapacities: otherEngineKVCapacities,
            configReserveBytes: configReserveBytes,
            physicalBytes: physicalBytes)
        return min(max(0, grantedKVBytesCapacity), current)
    }

    private static func saturatingAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }
}
