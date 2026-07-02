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
}
