// Enriched capacity rejections (routing v2, Phase 2): capacity-shaped
// live-gate failures get rejection_reason + available_token_budget +
// capacity_seq stamped from the published snapshot — plus, for the transient
// token_budget shape, the busy-wait feasible_after_ms forecast from the quote
// engine's estimator; everything else keeps its legacy frame untouched.

import Foundation
import Testing
@testable import ProviderCore

private func published(seq: UInt64 = 5, decodeTps: Double = 0) -> BackendCapacity {
    BackendCapacity(
        slots: [
            BackendSlotCapacity(
                model: "org/model-a",
                state: "running",
                numRunning: 2,
                numWaiting: 0,
                activeTokens: 0,
                maxTokensPotential: 0,
                observedDecodeTps: decodeTps,
                activeTokenBudgetUsed: 3000,
                activeTokenBudgetMax: 9000,
                queuedTokenBudget: 1000)
        ],
        gpuMemoryActiveGb: 1,
        gpuMemoryPeakGb: 1,
        gpuMemoryCacheGb: 0,
        totalMemoryGb: 64,
        capacitySeq: seq)
}

@Test func bareCapacity503GainsFallbackReasonBudgetAndSeq() {
    let enriched = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 503),
        modelId: "org/model-a",
        published: published(),
        fallbackReason: .slotState)
    #expect(enriched.rejectionReason == .slotState)
    // 9000 − 3000 − 1000
    #expect(enriched.availableTokenBudget == 5000)
    #expect(enriched.capacitySeq == 5)
    // The pre-existing fields are untouched.
    #expect(enriched.code == .capacity)
    #expect(enriched.statusCode == 503)
    #expect(enriched.feasibleAfterMs == nil)
}

@Test func errorReasonMapsToBoundedRejectionReasonOverFallback() {
    let cases: [(InferenceErrorReason, CapacityRejectionReason)] = [
        (.tokenBudgetExhausted, .tokenBudget),
        (.requestExceedsBatchTokenBudget, .tokenBudget),
        (.queueFull, .tokenBudget),
        (.capacityBusy, .tokenBudget),
        (.capacityTimeout, .tokenBudget),
        (.requestExceedsContext, .kvHeadroom),
        (.requestExceedsNode, .kvHeadroom),
        (.requestExceedsNodeBudget, .kvHeadroom),
        (.modelLoad, .memoryCap),
        (.deadlineUnreachable, .deadline),
    ]
    for (errorReason, expected) in cases {
        let enriched = CapacityRejectionEnrichment.enrich(
            InferenceFailure(code: .capacity, statusCode: 503, errorReason: errorReason),
            modelId: "org/model-a",
            published: published(),
            fallbackReason: .slotState)
        #expect(enriched.rejectionReason == expected, "\(errorReason)")
    }
    // Non-capacity diagnostic reasons fall back to the caller's gate name.
    let cancelled = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 503, errorReason: .cancelled),
        modelId: nil,
        published: published(),
        fallbackReason: .memoryCap)
    #expect(cancelled.rejectionReason == .memoryCap)
}

@Test func nonCapacityStatusesPassThroughUntouched() {
    for status in [UInt16(400), 404, 499, 500, 502] {
        let failure = InferenceFailure(code: .invalidRequest, statusCode: status)
        let out = CapacityRejectionEnrichment.enrich(
            failure,
            modelId: "org/model-a",
            published: published(),
            fallbackReason: .slotState)
        #expect(out == failure, "status \(status)")
    }
}

@Test func queueFull429IsCapacityShapedAndEnriched() {
    let enriched = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 429, errorReason: .queueFull),
        modelId: "org/model-a",
        published: published(),
        fallbackReason: .tokenBudget)
    #expect(enriched.rejectionReason == .tokenBudget)
    #expect(enriched.availableTokenBudget == 5000)
    #expect(enriched.capacitySeq == 5)
}

@Test func missingSnapshotOrModelLeavesOptionalFieldsHonest() {
    // No published snapshot at all (pre-first-heartbeat): reason still set,
    // numeric fields stay nil — never invented.
    let noSnapshot = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 503),
        modelId: "org/model-a",
        published: nil,
        fallbackReason: .memoryCap)
    #expect(noSnapshot.rejectionReason == .memoryCap)
    #expect(noSnapshot.availableTokenBudget == nil)
    #expect(noSnapshot.capacitySeq == nil)

    // Unknown model: seq is real, budget unknown.
    let unknownModel = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 503),
        modelId: "org/elsewhere",
        published: published(seq: 9),
        fallbackReason: .slotState)
    #expect(unknownModel.availableTokenBudget == nil)
    #expect(unknownModel.capacitySeq == 9)

    // A zero (unstamped) snapshot seq is never forwarded as if it were real.
    let unstamped = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 503),
        modelId: "org/model-a",
        published: published(seq: 0),
        fallbackReason: .slotState)
    #expect(unstamped.capacitySeq == nil)
}

@Test func existingEnrichmentAndFeasibleAfterArePreserved() {
    // A failure already carrying engine-computed values keeps them.
    let carried = InferenceFailure(
        code: .capacity,
        statusCode: 503,
        errorReason: .tokenBudgetExhausted,
        rejectionReason: .kvHeadroom,
        availableTokenBudget: 42,
        feasibleAfterMs: 777,
        capacitySeq: 3)
    let enriched = CapacityRejectionEnrichment.enrich(
        carried,
        modelId: "org/model-a",
        published: published(seq: 9),
        fallbackReason: .slotState)
    // Explicit reason wins over the errorReason mapping and the fallback.
    #expect(enriched.rejectionReason == .kvHeadroom)
    // feasible_after is engine knowledge; enrichment never overwrites it.
    #expect(enriched.feasibleAfterMs == 777)
    // Budget/seq refresh to the snapshot's live values when available.
    #expect(enriched.availableTokenBudget == 5000)
    #expect(enriched.capacitySeq == 9)
}

@Test func tokenBudgetRejectionCarriesBusyWaitForecast() {
    // Admittable = 9000 − 3000 − 1000 = 5000; envelope 7000 → deficit 2000.
    // Running sequences retire budget at 100 tok/s → 20_000ms, the same
    // figure CapacityQuoteEngine.queueEstimateMs would quote.
    let enriched = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 503, errorReason: .tokenBudgetExhausted),
        modelId: "org/model-a",
        published: published(decodeTps: 100),
        fallbackReason: .tokenBudget,
        neededTokens: 7000)
    #expect(enriched.rejectionReason == .tokenBudget)
    #expect(enriched.feasibleAfterMs == 20_000)
}

@Test func busyWaitForecastOmittedWhenInestimable() {
    // No decode-rate sample (slot never measured TPS): no honest estimate.
    let unmeasured = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 503, errorReason: .tokenBudgetExhausted),
        modelId: "org/model-a",
        published: published(),
        fallbackReason: .tokenBudget,
        neededTokens: 7000)
    #expect(unmeasured.feasibleAfterMs == nil)

    // No envelope (prompt recount failed): nothing to forecast from.
    let noEnvelope = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 503, errorReason: .tokenBudgetExhausted),
        modelId: "org/model-a",
        published: published(decodeTps: 100),
        fallbackReason: .tokenBudget)
    #expect(noEnvelope.feasibleAfterMs == nil)

    // Envelope already fits (stale-negative gate race): 0 wait is "no
    // estimate", never stamped.
    let fits = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 503, errorReason: .tokenBudgetExhausted),
        modelId: "org/model-a",
        published: published(decodeTps: 100),
        fallbackReason: .tokenBudget,
        neededTokens: 4000)
    #expect(fits.feasibleAfterMs == nil)

    // Non-transient shapes (never-fits) have no meaningful "after" even with
    // an envelope and a measured rate.
    let neverFits = CapacityRejectionEnrichment.enrich(
        InferenceFailure(code: .capacity, statusCode: 503, errorReason: .requestExceedsNode),
        modelId: "org/model-a",
        published: published(decodeTps: 100),
        fallbackReason: .tokenBudget,
        neededTokens: 20_000)
    #expect(neverFits.rejectionReason == .kvHeadroom)
    #expect(neverFits.feasibleAfterMs == nil)
}
