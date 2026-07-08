// Copyright © 2026 Eigen Labs.
//
// Per-token KV byte-cost resolution for the ContinuousBatchingV2 bridge.
//
// The v2 engine builds UNQUANTIZED (fp16) `CBv2LayerCache`s regardless of the
// provider's `kv_quant` setting — KV-quant is not yet composed with engine_v2
// (`EngineV2Factory.makeProductionEngine` always uses `CBv2LayerCache`, never a
// quantized cache). But the loaded `BatchScheduler` reports its
// `kvBytesPerToken` at the QUANTIZED rate when `kv_quant = true`, which is
// 2–4× smaller than fp16. Feeding that quantized rate into the bridge would
// make heartbeat token budgets (`kvBytesCapacity / kvBytesPerToken`) and
// active-token counts (`kvBytesInUse / kvBytesPerToken`) OVERSTATE capacity by
// the same 2–4×, and would under-size the shared-budget KV reservation.
//
// This helper picks the fp16 rate for v2 sizing and reports whether a
// "kv_quant unsupported by engine_v2" WARN should fire (only when kv_quant
// actually engaged for this model, i.e. the quantized rate is below fp16).

import Foundation

enum EngineV2KVSizing {
    /// The per-token KV cost the v2 bridge must use, plus whether to WARN that
    /// `kv_quant` is unsupported by engine_v2 (falls back to fp16 caches).
    ///
    /// - Parameters:
    ///   - quantizedRate: the loaded scheduler's live `kvBytesPerToken`
    ///     (quantized when `kv_quant` engaged, else already fp16).
    ///   - fp16Rate: the scheduler's `fp16KVBytesPerToken` — the un-quantized
    ///     cost, which is what the v2 caches actually consume.
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

    /// KV admission ceiling (bytes) for a NEW v2 engine, sized against the
    /// WHOLE process — round-2 PR#499 P2.
    ///
    /// A v2 engine's `kvBytesCapacity` is fixed at construction and its
    /// private admission ledger (`AdmissionV2`) admits up to it. Sizing each
    /// slot's ceiling as if only ITS weights were resident lets Σ(ceilings)
    /// on a default multi-slot provider exceed the unified-memory cap. This
    /// helper derives the ceiling from the same `UnifiedMemoryCap` policy the
    /// load gate uses, with the FULL fleet residency subtracted:
    ///
    ///     ceiling = kvBudgetBytes(Σ all resident weights, incl. the new
    ///               model) − Σ(existing v2 engines' admission ceilings)
    ///
    /// so at all times Σ(v2 ceilings) ≤ cap − Σweights − activations. An
    /// existing engine's ceiling cannot be shrunk after the fact (the
    /// backend's byte capacity is construction-fixed), so later loads are
    /// CAPPED by what earlier engines were granted; when nothing is left the
    /// caller gets 0 and `makeProductionEngine` throws `noKVHeadroom` → the
    /// slot serves via the legacy scheduler (whose shared live-KV gate needs
    /// no static ceiling). Legacy co-resident slots contribute their weights
    /// here and gate their KV per-request through `GlobalKVCacheBudget` — as
    /// v2 requests now also do — so the runtime double-gate stays consistent
    /// with these static ceilings.
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
    /// RETAINED after the re-slice rewrite (slot-lifecycle deviation #5):
    /// grants are now assigned by `resliceGrants`, so nothing SIZES from
    /// this anymore — but the heartbeat safety net
    /// (`liveEngineKVBytesBudget` below, consumed by
    /// `EngineV2Runtime.capacitySummary`) still recomputes each bridge's
    /// live budget from CURRENT fleet residency through this exact
    /// derivation. Refactoring the clamp onto raw current-grant inputs
    /// would duplicate this arithmetic without deleting it; it goes when
    /// the clamp does.
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
    /// A v2 engine's admission ceiling is construction-fixed (the backend's
    /// byte capacity cannot shrink after the fact), so when ANOTHER model
    /// loads later — especially a legacy/non-allowlisted slot, whose load
    /// subtracts nothing from existing v2 ceilings — the engine's private cap
    /// goes stale against fleet reality: the coordinator keeps routing
    /// requests that fit the stale budget and the provider's shared KV gate
    /// rejects them after `inference_accepted`. The fix is a CLAMP on the
    /// REPORTED max: re-ask the same sizing function with the CURRENT
    /// resident set (this engine's own weights are inside
    /// `totalResidentWeightBytes`; co-resident v2 engines' construction
    /// grants come off the top exactly as at sizing time) and report
    /// `min(construction grant, current answer)`. The engine's private
    /// ledger keeps its original grant — only the coordinator-visible budget
    /// shrinks, so routing converges on what the shared gate will actually
    /// admit. Σ(reported) never exceeds the current fleet budget.
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
