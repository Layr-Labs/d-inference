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
import MLXLMCommon

enum EngineV2KVSizing {
    /// Bytes the CONTIGUOUS backend allocates up front for every request's
    /// sliding-window rings — one whole `window × kvHeads × headDim ×
    /// kvDTypeSize × 2 (K+V)` ring per non-KV-shared sliding layer, allocated
    /// at the layer's first write (`CBv2WindowedSequenceKV.allocateIfNeeded`)
    /// and charged identically by `CBv2ContiguousKVBackend.rowEstimates` and
    /// `AdmissionV2.allocatedBytes`. The per-token rate
    /// (`SlotSizingSnapshot.fp16KVBytesPerToken`) counts FULL layers only, so
    /// without this term the bridge's `fixedRequestBytes` — which feeds both
    /// the shared-gate reservation (`requestReservationBytes`) and the
    /// heartbeat's prospective-row overhead (`maximumRequestOverheadBytes`) —
    /// under-charges every gemma-4-26b request by 200 MiB (25 sliding layers
    /// × 8 MiB on the served artifacts: window 1024 × 8 KV heads × head_dim
    /// 256 × 2 B × 2). gpt-oss-20b rings are 3 MiB (12 × 128 × 8 × 64 × 2 ×
    /// 2); qwen3.6 has none. Paged rows never commit a ring
    /// (`PagedKVPool.pageDemand` charges pages), so the paged bridge keeps a
    /// zero term. `kvDTypeSize` is the backend's ACTUAL element width
    /// (`CBv2ContiguousBackendConfig.kvDType.size`), never an assumed 2.
    /// Pure; saturates instead of trapping on absurd geometry.
    static func contiguousRingBytes(layerKinds: [CBv2LayerKind], kvDTypeSize: Int) -> Int {
        guard kvDTypeSize > 0 else { return 0 }
        var total = 0
        for kind in layerKinds where kind.sharesKVWithLayer == nil {
            guard case .slidingWindow(let window) = kind.attention, window > 0 else { continue }
            let ring = [window, kind.kvHeads, kind.headDim, kvDTypeSize, 2].reduce(1) { acc, term in
                let (product, overflow) = acc.multipliedReportingOverflow(by: max(0, term))
                return overflow ? Int.max : product
            }
            let (sum, overflow) = total.addingReportingOverflow(ring)
            total = overflow ? Int.max : sum
        }
        return total
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
