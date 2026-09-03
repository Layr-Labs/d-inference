// Copyright © 2026 Eigen Labs.
//
// Capacity-probe → capacity-quote computation (routing v2, Phase 2).
//
// The quote path answers "could this bucketed request shape start here right
// now, and how long to first token?" from the LOCK-FREE published capacity
// snapshot — one unfair-lock read, no hop to the inference-engine actor, no
// inference, no model load, no KV allocation, no prompt inspection. Probe
// storms therefore cannot starve admission or decode: quoting reads values
// the heartbeat path already produced.
//
// It deliberately re-derives NOTHING. Every feasibility figure it consults
// was computed by the existing gate implementations on the last capacity
// rebuild and rides the snapshot:
//   * slot state — the bridge's own truthful heartbeat state
//     (`EngineV2Bridge.backendSlotCapacity`: idle/running/crashed/reloading);
//   * continuous-batch room — the engine's `numRunning`/`maxConcurrency`;
//   * token/KV budget — `activeTokenBudgetMax` (already clamped through
//     `EngineV2KVSizing.liveEngineKVBytesBudget`, i.e. `UnifiedMemoryCap`
//     with the activation reserve) minus used and queued budget;
//   * cold-load room — `freeForLoadGb` (`ModelLoadAdmission
//     .maxLoadableWeightGb`, already net of the load headroom) against the
//     model's padded weight footprint;
//   * template/capability — the advertised `ModelInfo`'s
//     `templateRenderOK`/`isVision` self-check results;
//   * vision-tower admission — `VisionTowerBudget.maxAdmissiblePatches`.

import Foundation

enum CapacityQuoteEngine {
    /// Everything a quote needs, captured as plain values so the computation
    /// is pure and tests pin every path without actors, engines, or a GPU.
    struct Inputs {
        let probe: CoordinatorMessage.CapacityProbe
        /// The seq-stamped published snapshot (`ProviderState
        /// .publishedCapacity`); nil before the first heartbeat of the
        /// connection.
        let capacity: BackendCapacity?
        /// The advertised catalog entry for `probe.model`; nil when the model
        /// is not advertised at all.
        let model: ModelInfo?
        /// TTFT estimate for the matching bucket, resolved by the caller from
        /// `TTFTQuantileTracker`; nil falls back to the prefill-derived floor.
        let ttft: TTFTQuantileTracker.Estimate?
        /// Device vision-tower limits (`VisionTowerBudget.liveLimits` in
        /// production; synthetic in tests).
        let visionLimits: VisionTowerBudget.Limits
        /// True when the provider is draining for update or shutting down —
        /// the same conditions the live gate rejects with a bare 503 today.
        let refusingNewWork: Bool
    }

    /// Conservative floor for the cold-start no-data case: quoting 0 would
    /// claim instant first content, which no dispatch ever achieves. One
    /// second is well under any measured TTFT for a cold load, so it remains
    /// an honest LOWER bound (floors must under-promise capacity, never
    /// over-promise speed) while confidence stays `.low`.
    static let coldStartFloorMs = 1000.0

    static func quote(_ inputs: Inputs) -> ProviderMessage.CapacityQuote {
        let probe = inputs.probe
        let seq = inputs.capacity?.capacitySeq ?? 0
        let slot = inputs.capacity?.slots.first { $0.model == probe.model }
        let availableTokens = slot.map(CapacityHeartbeatMateriality.admittableTokens) ?? 0

        func reject(
            _ reason: CapacityRejectionReason,
            queueEstMs: Double = 0
        ) -> ProviderMessage.CapacityQuote {
            let ttft = resolvedTTFT(inputs, slot: slot)
            return ProviderMessage.CapacityQuote(
                quoteId: probe.quoteId,
                capacitySeq: seq,
                admissibleNow: false,
                rejectionReason: reason,
                ttftP50Ms: ttft.p50Ms,
                ttftP90Ms: ttft.p90Ms,
                queueEstMs: queueEstMs,
                availableTokenBudget: availableTokens,
                confidence: ttft.confidence)
        }

        // Ordering: permanent shape mismatches first (capability/template),
        // then health, then capacity, then timing — mirroring the coordinator's
        // existing classification precedence so one probe never masks a
        // stronger signal behind a transient one.
        guard let model = inputs.model else {
            return reject(.capability)
        }
        if (probe.requiresVision || probe.visionImageCount > 0), model.isVision != true {
            return reject(.capability)
        }
        if model.templateRenderOK == false {
            return reject(.template)
        }
        // Vision feasibility on a vision-capable model: the probe carries an
        // image COUNT, not patch grids, and per-image tower calls bound peak
        // memory by the largest single image — undecidable here without media
        // bytes (which must never ride a probe). The decidable case is a
        // device whose tower gate admits nothing at all.
        if probe.visionImageCount > 0,
            VisionTowerBudget.maxAdmissiblePatches(inputs.visionLimits) == 0
        {
            return reject(.memoryCap)
        }
        guard let capacity = inputs.capacity, seq != 0 else {
            // No published snapshot yet on this connection: the coordinator
            // cannot order a quote it cannot sequence, and we cannot consult
            // gates that have not reported. Fail closed as a health reject.
            return reject(.slotState)
        }
        if inputs.refusingNewWork {
            return reject(.slotState)
        }

        guard let slot else {
            // Model advertised but not resident: admissible only when the
            // cold-load gate's published answer says the weights fit now.
            // `freeForLoadGb` is `ModelLoadAdmission.maxLoadableWeightGb` —
            // already NET of the activation + min-serveable-KV load headroom
            // (and the unified cap / reserves), i.e. the maximum padded
            // WEIGHT footprint loadable right now. Compare the weights
            // directly: adding `requiredToLoadGb`'s headroom on top would
            // charge that headroom a second time and reject cold probes for
            // models the real load gate (weights + headroom ≤ raw free
            // memory) would admit.
            guard capacity.freeForLoadGb >= max(0, model.estimatedMemoryGb) else {
                return reject(.memoryCap)
            }
            if probe.deadlineRemainingMs <= 0 {
                return reject(.deadline)
            }
            return admissible(inputs, seq: seq, slot: nil, availableTokens: 0)
        }

        // Slot health: the bridge already folded wedge suspicion and recovery
        // reloads into the state string; trust it.
        guard slot.state == "idle" || slot.state == "running" else {
            return reject(.slotState)
        }

        let needed = Int64(max(0, probe.promptTokensBucket) + max(0, probe.maxOutputTokens))
        if slot.activeTokenBudgetMax > 0 {
            // Can never fit, even into an empty batch: the whole KV grant is
            // smaller than the request's token envelope.
            if needed > slot.activeTokenBudgetMax {
                return reject(.kvHeadroom)
            }
            if needed > availableTokens {
                return rejectBusy(
                    reject,
                    slot: slot,
                    deficitTokens: needed - availableTokens,
                    deadlineRemainingMs: probe.deadlineRemainingMs)
            }
        }
        // Continuous-batch admission room: all decode rows occupied.
        if slot.maxConcurrency > 0, slot.numRunning >= slot.maxConcurrency {
            return rejectBusy(
                reject,
                slot: slot,
                deficitTokens: max(1, needed),
                deadlineRemainingMs: probe.deadlineRemainingMs)
        }

        if probe.deadlineRemainingMs <= 0 {
            return reject(.deadline)
        }
        return admissible(inputs, seq: seq, slot: slot, availableTokens: availableTokens)
    }

    private static func admissible(
        _ inputs: Inputs,
        seq: UInt64,
        slot: BackendSlotCapacity?,
        availableTokens: Int64
    ) -> ProviderMessage.CapacityQuote {
        let ttft = resolvedTTFT(inputs, slot: slot)
        return ProviderMessage.CapacityQuote(
            quoteId: inputs.probe.quoteId,
            capacitySeq: seq,
            admissibleNow: true,
            ttftP50Ms: ttft.p50Ms,
            ttftP90Ms: ttft.p90Ms,
            queueEstMs: 0,
            availableTokenBudget: availableTokens,
            confidence: ttft.confidence)
    }

    /// Shared busy-slot rejection: `deadline` when the wait estimate already
    /// exceeds the request's remaining first-content budget (admitting would
    /// only burn the client's clock), otherwise `token_budget` with the wait
    /// as `queue_est_ms`. An unmeasurable wait (no decode-TPS sample yet)
    /// stays `token_budget` with `queue_est_ms = 0` — zero alongside
    /// `admissible_now = false` reads as "no estimate", and inventing a wait
    /// here would misclassify busy slots as deadline-infeasible.
    private static func rejectBusy(
        _ reject: (CapacityRejectionReason, Double) -> ProviderMessage.CapacityQuote,
        slot: BackendSlotCapacity,
        deficitTokens: Int64,
        deadlineRemainingMs: Int64
    ) -> ProviderMessage.CapacityQuote {
        guard let waitMs = queueEstimateMs(slot: slot, deficitTokens: deficitTokens) else {
            return reject(.tokenBudget, 0)
        }
        if waitMs > Double(deadlineRemainingMs) {
            return reject(.deadline, waitMs)
        }
        return reject(.tokenBudget, waitMs)
    }

    /// TTFT with the plan's fallback chain. The tracker already walked
    /// bucket → (model, warm) → model aggregates; the final fallback is a
    /// measurement-derived floor: prompt-bucket prefill time at the slot's
    /// observed prefill TPS (the same EWMA the coordinator's TTFT estimation
    /// consumes), or ``coldStartFloorMs`` when nothing has ever been measured.
    /// Always `confidence = .low` on the floor. Durations only.
    static func resolvedTTFT(
        _ inputs: Inputs,
        slot: BackendSlotCapacity?
    ) -> TTFTQuantileTracker.Estimate {
        if let ttft = inputs.ttft { return ttft }
        if let slot, slot.observedPrefillTps > 0 {
            let promptTokens = Double(max(
                inputs.probe.promptTokensBucket,
                CoordinatorMessage.CapacityProbe.promptBucketTokens))
            let floorMs = promptTokens / slot.observedPrefillTps * 1000.0
            return TTFTQuantileTracker.Estimate(
                p50Ms: floorMs, p90Ms: floorMs, confidence: .low)
        }
        return TTFTQuantileTracker.Estimate(
            p50Ms: coldStartFloorMs, p90Ms: coldStartFloorMs, confidence: .low)
    }

    /// Wait estimate until `deficitTokens` of budget frees: running sequences
    /// retire budget at the slot's observed decode rate. Durations only; nil
    /// when the slot has never measured decode TPS (no honest estimate
    /// exists).
    static func queueEstimateMs(
        slot: BackendSlotCapacity,
        deficitTokens: Int64
    ) -> Double? {
        guard deficitTokens > 0 else { return 0 }
        guard slot.observedDecodeTps > 0 else { return nil }
        return Double(deficitTokens) / slot.observedDecodeTps * 1000.0
    }

    /// Busy-slot wait forecast for the enriched capacity rejections: how long
    /// until `neededTokens` becomes admittable on `slot`, via the same
    /// deficit → ``queueEstimateMs`` path the quote's `rejectBusy` takes
    /// against the same published budget view (`CapacityHeartbeatMateriality
    /// .admittableTokens`). 0 when the tokens already fit; nil when the slot
    /// has never measured decode TPS (no honest estimate exists).
    static func busyWaitEstimateMs(
        slot: BackendSlotCapacity,
        neededTokens: Int64
    ) -> Double? {
        queueEstimateMs(
            slot: slot,
            deficitTokens: neededTokens - CapacityHeartbeatMateriality.admittableTokens(slot))
    }
}
