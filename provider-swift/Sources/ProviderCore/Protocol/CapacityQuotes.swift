// Copyright © 2026 Eigen Labs.
//
// Shared vocabulary for the routing-v2 capacity probe/quote protocol and the
// enriched capacity rejections (mirrors coordinator/protocol/capacity.go —
// same change, symmetry-tested).
//
// Production evidence (coordinator/registry/budget_clamp.go): 11,581
// capacity-shaped provider 503s in 6h from boxes whose heartbeats looked ~1.4%
// utilized. The reasons below turn each of those rejections — and each
// negative quote — into a machine-classified state sample the coordinator can
// feed its ledger, clamp, and failure taxonomy, instead of a bare 503.

import Foundation

/// Bounded, closed rejection vocabulary shared by capacity quotes and the
/// enriched inference-error fields. Closed by construction: callers can only
/// place one of these on the wire, never request-derived text.
public enum CapacityRejectionReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// The live continuous-batch token budget cannot admit the request NOW
    /// (transient: frees as running sequences retire).
    case tokenBudget = "token_budget"
    /// The request can NEVER fit this slot's KV byte budget, even empty
    /// (prompt bucket + max output exceeds the whole grant).
    case kvHeadroom = "kv_headroom"
    /// UnifiedMemoryCap-derived pressure: the model is not resident and the
    /// box cannot load it right now (weights + load headroom exceed free
    /// unified memory), or vision-tower admission is impossible on this GPU.
    case memoryCap = "memory_cap"
    /// The slot is not in a serveable state: crashed, reloading, draining
    /// for update, shutting down, or the model is simply not resident with
    /// no capacity report yet.
    case slotState = "slot_state"
    /// The model's chat template failed its render self-check
    /// (`ModelInfo.templateRenderOK == false`); requests would fail at render.
    case template
    /// The provider cannot serve this request shape at all: model not
    /// advertised, or vision input probed against a text-only build.
    case capability
    /// The earliest feasible start (queue estimate) already exceeds the
    /// request's remaining first-content deadline — admitting would only
    /// burn the client's clock.
    case deadline
}

/// Confidence of a quote's TTFT estimate. `high` means the quantiles come
/// from enough completed real requests in the matching bucket; `low` marks
/// aggregate/floor fallbacks the coordinator should trust less than its own
/// calibration.
public enum CapacityQuoteConfidence: String, Codable, Sendable, Equatable, CaseIterable {
    case high
    case low
}

extension CapacityRejectionReason {
    /// Map the existing bounded diagnostic vocabulary onto the shared quote
    /// rejection enum, for enriching capacity-shaped inference errors. Returns
    /// nil for reasons that are not capacity-shaped (client errors, jinja
    /// diagnostics ride the `template` class only via render-check state).
    public init?(errorReason: InferenceErrorReason) {
        switch errorReason {
        case .tokenBudgetExhausted, .requestExceedsBatchTokenBudget,
            .queueFull, .capacityBusy, .capacityTimeout:
            self = .tokenBudget
        case .requestExceedsContext, .requestExceedsNode, .requestExceedsNodeBudget:
            self = .kvHeadroom
        case .modelLoad:
            self = .memoryCap
        case .draining:
            self = .slotState
        case .deadlineUnreachable:
            self = .deadline
        case .jinjaChannelTags, .jinjaNullBridge, .jinjaTemplate:
            self = .template
        case .cancelled, .clientError, .toolNoncompliance:
            return nil
        }
    }
}
