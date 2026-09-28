import Foundation

struct QwenLayerStageProfiledLifecycleResult: Encodable {
    let kind = "qwen_layer_stage_profiled_lifecycle_check"
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let request: QwenLayerStageProfiledPrefillRequestSpec
    let faultInjectedAfterFirstStageCommit: Bool
    let failedStageFrontiers: [Int]
    let bothRequestsFailedAndRetired: Bool
    let retiredRequestReuseRejected: Int
}

/// The first stage has committed a long chunk when failure occurs. Both owners
/// must retire before the caller constructs a fresh parity request on the same
/// resident models. This has no network or pending transport acknowledgement.
func checkQwenLayerStageProfiledLifecycle(fixture: QwenLayerStageFixture,
    proof: QwenLayerStageLoaderCheck, check: () throws -> Void
) throws -> QwenLayerStageProfiledLifecycleResult {
    let spec = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1,
        requestID: UUID(), batchSize: 1, promptCount: 1025, chunkSize: 512, outputCount: 1)
    return try withQwenLayerStageProfiledFixtureOwners(fixture: fixture, proof: proof,
        request: spec, includeBaseline: false) { _, pair in
        let first = pair.first, second = pair.second
        let chunk = (0..<512).map { 3 + (($0 * 17 + 7) % (fixture.baseline.vocabularySize - 3)) }
        let marker = "profiled-fixture-fault-after-first-512-token-commit"
        var injected = false
        do {
            _ = try pair.prefillChunk(chunk, final: false) {
                try check()
                if first.committedTokens == 512 { injected = true; throw ProbeError(marker) }
            }
        } catch {
            guard injected, String(describing: error) == marker else {
                throw ProbeError("Profiled fixture failed before the intended fault: \(error)")
            }
        }
        guard injected, first.committedTokens == 512, second.committedTokens == 0,
              first.isClosed, first.isFailed, second.isClosed, second.isFailed else {
            throw ProbeError("Profiled pair failed to retire the advanced and untouched states")
        }
        var rejected = 0
        for stage in [first, second] {
            do { _ = try stage.prefillChunk(chunk, offset: 0, final: false, check: check) }
            catch {
                guard String(describing: error).contains("CBv2 state is retired"), stage.isClosed, stage.isFailed else {
                    throw ProbeError("Retired profiled request failed for an unexpected reason: \(error)")
                }
                rejected += 1
            }
        }
        guard rejected == 2 else { throw ProbeError("A retired profiled request accepted new work") }
        return .init(request: spec, faultInjectedAfterFirstStageCommit: true,
            failedStageFrontiers: [first.committedTokens, second.committedTokens],
            bothRequestsFailedAndRetired: true, retiredRequestReuseRejected: rejected)
    }
}
