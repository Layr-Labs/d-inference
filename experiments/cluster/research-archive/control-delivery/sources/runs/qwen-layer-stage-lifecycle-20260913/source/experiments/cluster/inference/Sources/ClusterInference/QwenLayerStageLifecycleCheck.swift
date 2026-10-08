import Foundation

struct QwenLayerStageLifecycleResult: Encodable {
    let kind = "qwen_layer_stage_lifecycle_check"
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let failedStageFrontiers: [Int]
    let faultInjectedAfterFirstStageCommit: Bool
    let bothRequestsFailedAndRetired: Bool
    let retiredRequestReuseRejected: Int
    let recoveryOnSameResidentModels: QwenLayerStageParityResult
}

/// Exercise failure with an advanced first stage and an untouched second stage,
/// then compare a fresh request on those same (now fused) model objects.
func checkQwenLayerStageLifecycle(fixture: QwenLayerStageFixture,
    proof: QwenLayerStageLoaderCheck, options: Options, check: () throws -> Void
) throws -> QwenLayerStageLifecycleResult {
    let prompt = try promptTokens(options: options, vocabularySize: fixture.baseline.vocabularySize)
    let request = try QwenLayerStageRequestSpec(requestID: UUID(), promptCount: prompt.count,
        chunkSize: options.chunkSize, outputCount: options.decodeCount)
    let first = try QwenLayerStageSession(stage: proof.stages[0], plan: fixture.plan, request: request)
    defer { if !first.isClosed { try? first.cancel() } }
    let second = try QwenLayerStageSession(stage: proof.stages[1], plan: fixture.plan, request: request)
    defer { if !second.isClosed { try? second.cancel() } }
    let pair = try QwenSequentialStagePair(first: first, second: second)
    let chunk = Array(prompt.prefix(options.chunkSize)), final = chunk.count == prompt.count
    let marker = "injected-stage-check-fault-after-first-commit"
    var injected = false
    do {
        _ = try pair.prefillChunk(chunk, final: final) {
            try check()
            if first.committedTokens > 0 {
                injected = true
                throw ProbeError(marker)
            }
        }
    } catch {
        guard String(describing: error) == marker, injected else {
            throw ProbeError("Stage lifecycle failed before the intended committed-state fault: \(error)")
        }
    }
    guard injected, first.committedTokens == chunk.count, second.committedTokens == 0,
        first.isClosed, second.isClosed, first.isFailed, second.isFailed else {
        throw ProbeError("Stage pair failed to retire both advanced/fresh states after injected failure")
    }
    var rejected = 0
    for stage in [first, second] {
        do { _ = try stage.prefillChunk(chunk, offset: 0, final: final, check: check) }
        catch {
            guard String(describing: error).contains("closed"), stage.isClosed, stage.isFailed else {
                throw ProbeError("Retired stage reuse failed for an unexpected reason: \(error)")
            }
            rejected += 1
        }
    }
    guard rejected == 2 else { throw ProbeError("A retired stage request accepted reuse") }
    // New owners/caches, same frozen weights. The full-model reference also
    // starts a fresh independent request. Every remapped state/logit byte is
    // compared again, detecting leaked frontier or recurrent state from failure.
    let recovery = try checkQwenLayerStageParity(fixture: fixture, proof: proof,
        options: options, check: check)
    return .init(failedStageFrontiers: [first.committedTokens, second.committedTokens],
        faultInjectedAfterFirstStageCommit: true, bothRequestsFailedAndRetired: true,
        retiredRequestReuseRejected: rejected, recoveryOnSameResidentModels: recovery)
}
