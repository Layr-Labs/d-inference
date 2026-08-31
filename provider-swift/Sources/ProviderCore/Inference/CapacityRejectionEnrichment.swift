// Copyright © 2026 Eigen Labs.
//
// Enriched capacity rejections (routing v2, Phase 2).
//
// Every capacity-shaped (503) live-gate rejection the provider sends becomes
// a fresh, machine-readable state sample for the coordinator's ledger, budget
// clamp, and failure taxonomy: bounded reason + the live admittable token
// budget + the `capacity_seq` of the snapshot the verdict aligns with. This
// is what turns the budget clamp's reactive one-bounce-per-cycle discovery
// (coordinator/registry/budget_clamp.go) into push-based truth.
//
// Pure function: the ProviderLoop stamps failures at its rejection sites with
// values already computed elsewhere — nothing here re-derives a gate formula.
// The busy-slot forecast (`feasible_after_ms`) likewise reuses the quote
// engine's estimator (`CapacityQuoteEngine.busyWaitEstimateMs`) rather than
// inventing one.

import Foundation

enum CapacityRejectionEnrichment {
    /// Stamp a capacity-shaped failure with the published snapshot's view of
    /// the rejected model. Failures that are not capacity-shaped pass
    /// through untouched — the enriched fields are defined only for
    /// live-gate capacity rejections, and client-fault/provider-fault frames
    /// must keep their legacy shape.
    ///
    /// `fallbackReason` names the gate that rejected when the failure's own
    /// `errorReason` cannot be mapped (e.g. the bare drain/shutdown 503s,
    /// whose failure carries no reason at all).
    ///
    /// `neededTokens` is the request's admission token envelope (templated
    /// prompt + output reservation), evaluated lazily and only for the
    /// transient `token_budget` shape: it feeds the quote engine's busy-wait
    /// estimator so the 503 carries a real `feasible_after_ms` forecast.
    static func enrich(
        _ failure: InferenceFailure,
        modelId: String?,
        published: BackendCapacity?,
        fallbackReason: CapacityRejectionReason,
        neededTokens: @autoclosure () -> Int64? = nil
    ) -> InferenceFailure {
        // 503 (reroute) and 429 (queue full) are the two capacity-shaped
        // live-gate statuses; everything else keeps its legacy frame.
        guard failure.statusCode == 503 || failure.statusCode == 429 else { return failure }
        let slot = modelId.flatMap { id in
            published?.slots.first { $0.model == id }
        }
        let reason = failure.rejectionReason
            ?? failure.errorReason.flatMap(CapacityRejectionReason.init(errorReason:))
            ?? fallbackReason
        // Busy-slot forecast: only the transient token_budget shape has a
        // meaningful "after" (never-fits and health rejects do not free up by
        // waiting), and only a slot with a measured decode rate can estimate
        // one — running sequences retire budget at that rate. Positive
        // estimates only: 0 alongside a rejection reads as "no estimate", and
        // the wire omits zero anyway.
        let feasibleAfterMs: Int64? = failure.feasibleAfterMs ?? {
            guard reason == .tokenBudget, let slot, let needed = neededTokens(),
                let waitMs = CapacityQuoteEngine.busyWaitEstimateMs(
                    slot: slot, neededTokens: needed),
                waitMs > 0
            else { return nil }
            return Int64(waitMs.rounded(.up))
        }()
        return InferenceFailure(
            code: failure.code,
            statusCode: failure.statusCode,
            errorReason: failure.errorReason,
            terminalCause: failure.terminalCause,
            attemptUsage: failure.attemptUsage,
            rejectionReason: reason,
            availableTokenBudget: slot.map(CapacityHeartbeatMateriality.admittableTokens)
                ?? failure.availableTokenBudget,
            feasibleAfterMs: feasibleAfterMs,
            capacitySeq: (published?.capacitySeq).flatMap { $0 != 0 ? $0 : nil }
                ?? failure.capacitySeq)
    }
}
