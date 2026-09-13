// Quote computation (routing v2, Phase 2): every feasibility path of
// `CapacityQuoteEngine` pinned against synthetic snapshots — pure values, no
// engine, no GPU. Gates are the EXISTING implementations' published outputs;
// these tests pin how the engine consults them and which bounded reason each
// failure maps to, including the deadline and vision rejects.

import Foundation
import Testing
@testable import ProviderCore

private func probe(
    model: String = "org/model-a",
    promptBucket: Int = 512,
    maxOutput: Int = 512,
    requiresVision: Bool = false,
    visionImages: Int = 0,
    deadlineMs: Int64 = 9000
) -> CoordinatorMessage.CapacityProbe {
    CoordinatorMessage.CapacityProbe(
        quoteId: "q-test",
        model: model,
        promptTokensBucket: promptBucket,
        maxOutputTokens: maxOutput,
        requiresVision: requiresVision,
        visionImageCount: visionImages,
        deadlineRemainingMs: deadlineMs)
}

private func slot(
    model: String = "org/model-a",
    state: String = "running",
    numRunning: UInt32 = 1,
    maxConcurrency: UInt32 = 4,
    decodeTps: Double = 50,
    prefillTps: Double = 1000,
    used: Int64 = 1000,
    max: Int64 = 9000,
    queued: Int64 = 0
) -> BackendSlotCapacity {
    BackendSlotCapacity(
        model: model,
        state: state,
        numRunning: numRunning,
        numWaiting: 0,
        activeTokens: 0,
        maxTokensPotential: 0,
        maxConcurrency: maxConcurrency,
        observedDecodeTps: decodeTps,
        observedPrefillTps: prefillTps,
        activeTokenBudgetUsed: used,
        activeTokenBudgetMax: max,
        queuedTokenBudget: queued)
}

private func capacity(
    _ slots: [BackendSlotCapacity],
    seq: UInt64 = 7,
    freeForLoadGb: Double = 40
) -> BackendCapacity {
    BackendCapacity(
        slots: slots,
        gpuMemoryActiveGb: 1,
        gpuMemoryPeakGb: 1,
        gpuMemoryCacheGb: 0,
        totalMemoryGb: 64,
        freeForLoadGb: freeForLoadGb,
        capacitySeq: seq)
}

private func model(
    id: String = "org/model-a",
    weightsGb: Double = 8,
    isVision: Bool? = nil,
    templateRenderOK: Bool? = nil
) -> ModelInfo {
    ModelInfo(
        id: id,
        sizeBytes: UInt64(weightsGb * 1_073_741_824),
        estimatedMemoryGb: weightsGb,
        isVision: isVision,
        templateRenderOK: templateRenderOK)
}

private let permissiveVision = VisionTowerBudget.Limits(
    maxBufferBytes: 38 << 30,
    attentionElementBytes: 2,
    headFactor: 1)

private func quote(
    probe p: CoordinatorMessage.CapacityProbe = probe(),
    capacity c: BackendCapacity?,
    model m: ModelInfo?,
    ttft: TTFTQuantileTracker.Estimate? = nil,
    visionLimits: VisionTowerBudget.Limits = permissiveVision,
    refusingNewWork: Bool = false
) -> ProviderMessage.CapacityQuote {
    CapacityQuoteEngine.quote(CapacityQuoteEngine.Inputs(
        probe: p,
        capacity: c,
        model: m,
        ttft: ttft,
        visionLimits: visionLimits,
        refusingNewWork: refusingNewWork))
}

// MARK: - Admissible paths

@Test func warmIdleSlotIsAdmissibleWithSnapshotSeqAndBudget() {
    let q = quote(capacity: capacity([slot()]), model: model())
    #expect(q.admissibleNow)
    #expect(q.rejectionReason == nil)
    #expect(q.capacitySeq == 7)
    #expect(q.queueEstMs == 0)
    // available = 9000 − 1000 − 0
    #expect(q.availableTokenBudget == 8000)
    #expect(q.quoteId == "q-test")
}

@Test func advertisedButUnloadedModelIsAdmissibleOnlyWhenColdLoadFits() {
    // freeForLoadGb (40) ≥ the padded weights (8): cold-admissible.
    let fits = quote(capacity: capacity([], freeForLoadGb: 40), model: model(weightsGb: 8))
    #expect(fits.admissibleNow)
    #expect(fits.availableTokenBudget == 0)

    // freeForLoadGb below the weights: memory_cap (the published answer of
    // ModelLoadAdmission.maxLoadableWeightGb says the load gate would refuse).
    let tooBig = quote(capacity: capacity([], freeForLoadGb: 2), model: model(weightsGb: 8))
    #expect(!tooBig.admissibleNow)
    #expect(tooBig.rejectionReason == .memoryCap)
}

@Test func coldQuoteNeverDoubleChargesTheLoadHeadroom() {
    // freeForLoadGb rides the heartbeat as ModelLoadAdmission
    // .maxLoadableWeightGb — ALREADY net of the activation + min-KV load
    // headroom. A provider whose published figure barely covers the padded
    // weights must quote admissible: re-adding requiredToLoadGb's headroom
    // on top would charge it twice and reject exactly the near-capacity
    // providers the real load gate admits.
    let weightsGb = 8.0
    let epsilon = 0.001
    let q = quote(
        capacity: capacity([], freeForLoadGb: weightsGb + epsilon),
        model: model(weightsGb: weightsGb))
    #expect(q.admissibleNow)
    #expect(q.rejectionReason == nil)

    // ...and the real load gate agrees, by the same arithmetic: with no
    // unreclaimable MLX usage, maxLoadableWeightGb == freeForLoadGb − h, so
    // "weights ≤ published freeForLoadGb" ⟺ canLoad's
    // "weights + h ≤ raw free". Pin the equivalence on synthetic bytes.
    let gb = 1024.0 * 1024.0 * 1024.0
    let headroomGb = 3.0
    let totalBytes = UInt64(64.0 * gb)
    let reserveBytes = UInt64(4.0 * gb)
    // Choose OS-available so the published loadable-weight figure is
    // weights + epsilon, exactly the quote scenario above.
    let availableBytes = UInt64((weightsGb + epsilon + headroomGb) * gb) + reserveBytes
    let published = ModelLoadAdmission.maxLoadableWeightGb(
        totalBytes: totalBytes,
        systemAvailableBytes: availableBytes,
        mlxUsedBytes: 0,
        reserveBytes: reserveBytes,
        headroomGb: headroomGb)
    #expect(abs(published - (weightsGb + epsilon)) < 0.0001)
    #expect(published >= weightsGb)
    #expect(ModelLoadAdmission.canLoad(
        weightsGb: weightsGb,
        headroomGb: headroomGb,
        totalBytes: totalBytes,
        systemAvailableBytes: availableBytes,
        gpuActiveBytes: 0,
        gpuCacheBytes: 0,
        reserveBytes: reserveBytes))
}

@Test func measuredTTFTQuantilesRideTheQuoteWithConfidence() {
    let ttft = TTFTQuantileTracker.Estimate(p50Ms: 812, p90Ms: 1650, confidence: .high)
    let q = quote(capacity: capacity([slot()]), model: model(), ttft: ttft)
    #expect(q.ttftP50Ms == 812)
    #expect(q.ttftP90Ms == 1650)
    #expect(q.confidence == .high)

    // No samples anywhere: prefill-derived floor at confidence low.
    // 512 tokens / 1000 tps = 512ms.
    let floored = quote(capacity: capacity([slot()]), model: model())
    #expect(floored.confidence == .low)
    #expect(floored.ttftP50Ms == 512)
    #expect(floored.ttftP90Ms == 512)
}

// MARK: - Capability / template rejects

@Test func unknownModelRejectsCapability() {
    let q = quote(capacity: capacity([slot()]), model: nil)
    #expect(!q.admissibleNow)
    #expect(q.rejectionReason == .capability)
}

@Test func visionProbeAgainstTextOnlyModelRejectsCapability() {
    // requires_vision flag.
    let flagged = quote(
        probe: probe(requiresVision: true),
        capacity: capacity([slot()]),
        model: model(isVision: nil))
    #expect(flagged.rejectionReason == .capability)
    // Image count alone also marks a vision request.
    let counted = quote(
        probe: probe(visionImages: 2),
        capacity: capacity([slot()]),
        model: model(isVision: nil))
    #expect(counted.rejectionReason == .capability)
    // A vision build passes this gate.
    let vlm = quote(
        probe: probe(requiresVision: true, visionImages: 2),
        capacity: capacity([slot()]),
        model: model(isVision: true))
    #expect(vlm.admissibleNow)
}

@Test func brokenTemplateSelfCheckRejectsTemplate() {
    let q = quote(capacity: capacity([slot()]), model: model(templateRenderOK: false))
    #expect(q.rejectionReason == .template)
    // Unknown (nil) is not the broken signal.
    #expect(quote(capacity: capacity([slot()]), model: model(templateRenderOK: nil)).admissibleNow)
}

@Test func degenerateVisionTowerRejectsMemoryCap() {
    // maxAdmissiblePatches == 0: the tower gate can admit nothing.
    let zeroTower = VisionTowerBudget.Limits(
        maxBufferBytes: 1,
        attentionElementBytes: 2,
        headFactor: 16)
    let q = quote(
        probe: probe(visionImages: 1),
        capacity: capacity([slot()]),
        model: model(isVision: true),
        visionLimits: zeroTower)
    #expect(q.rejectionReason == .memoryCap)
}

// MARK: - Slot state rejects

@Test func missingSnapshotOrZeroSeqRejectsSlotState() {
    #expect(quote(capacity: nil, model: model()).rejectionReason == .slotState)
    #expect(quote(capacity: nil, model: model()).capacitySeq == 0)
    #expect(
        quote(capacity: capacity([slot()], seq: 0), model: model())
            .rejectionReason == .slotState)
}

@Test func crashedReloadingAndDrainingRejectSlotState() {
    #expect(
        quote(capacity: capacity([slot(state: "crashed")]), model: model())
            .rejectionReason == .slotState)
    #expect(
        quote(capacity: capacity([slot(state: "reloading")]), model: model())
            .rejectionReason == .slotState)
    #expect(
        quote(capacity: capacity([slot()]), model: model(), refusingNewWork: true)
            .rejectionReason == .slotState)
}

// MARK: - Token budget / KV headroom rejects

@Test func requestExceedingWholeGrantRejectsKVHeadroom() {
    // needed = 8000 + 2000 > max 9000: never fits, even empty.
    let q = quote(
        probe: probe(promptBucket: 8000, maxOutput: 2000),
        capacity: capacity([slot(used: 0, max: 9000)]),
        model: model())
    #expect(q.rejectionReason == .kvHeadroom)
}

@Test func busySlotRejectsTokenBudgetWithQueueEstimate() {
    // needed = 1024; available = 9000 − 8500 = 500; deficit 524 @ 50 tps
    // = 10,480ms wait, within the 60s deadline → token_budget.
    let q = quote(
        probe: probe(promptBucket: 512, maxOutput: 512, deadlineMs: 60_000),
        capacity: capacity([slot(decodeTps: 50, used: 8500, max: 9000)]),
        model: model())
    #expect(q.rejectionReason == .tokenBudget)
    #expect(abs(q.queueEstMs - 524.0 / 50.0 * 1000.0) < 0.001)
    #expect(q.availableTokenBudget == 500)
}

@Test func concurrencyFullRejectsTokenBudgetNotSlotState() {
    // Misclassifying a full batch as health would let the coordinator eject
    // a healthy provider; it must stay a capacity signal.
    let q = quote(
        probe: probe(deadlineMs: 60_000),
        capacity: capacity([slot(numRunning: 4, maxConcurrency: 4)]),
        model: model())
    #expect(q.rejectionReason == .tokenBudget)
}

@Test func unmeasuredDecodeRateRejectsTokenBudgetWithoutInventedEstimate() {
    let q = quote(
        probe: probe(deadlineMs: 100),
        capacity: capacity([slot(decodeTps: 0, used: 8900, max: 9000)]),
        model: model())
    #expect(q.rejectionReason == .tokenBudget)
    #expect(q.queueEstMs == 0)
}

// MARK: - Deadline rejects

@Test func waitBeyondDeadlineRejectsDeadline() {
    // deficit 524 @ 50 tps ≈ 10.5s wait against a 2s deadline.
    let q = quote(
        probe: probe(promptBucket: 512, maxOutput: 512, deadlineMs: 2000),
        capacity: capacity([slot(decodeTps: 50, used: 8500, max: 9000)]),
        model: model())
    #expect(q.rejectionReason == .deadline)
    #expect(q.queueEstMs > 2000)
}

@Test func expiredDeadlineRejectsDeadlineEvenWhenIdle() {
    let q = quote(
        probe: probe(deadlineMs: 0),
        capacity: capacity([slot(numRunning: 0)]),
        model: model())
    #expect(q.rejectionReason == .deadline)

    // Cold-load path honors the deadline too.
    let cold = quote(
        probe: probe(deadlineMs: 0),
        capacity: capacity([], freeForLoadGb: 40),
        model: model(weightsGb: 8))
    #expect(cold.rejectionReason == .deadline)
}
