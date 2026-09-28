import Foundation
import MLX

struct QwenLayerStageProfiledParityResult: Encodable {
    let kind = "qwen_layer_stage_profiled_parity_check"
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let interprocessTransportUsed = false
    let syntheticDType: String
    let sourceConfigurationSHA256: String
    let artifactAggregateSHA256: String
    let planSHA256: String
    let request: QwenLayerStageProfiledPrefillRecordedRequest
    let frames: [QwenLayerStageFrameCheck]
    let baselineSelectedToken: Int
    let stageSelectedToken: Int
    let allRequestsRetired: Bool
    let sourceFilesDeletedBeforeForward = true
    let nativeBoundaryBytesCopied = true
}

/// A fresh full model request and two full-width stage requests use the same
/// explicit profile and chunk timeline. This is a tiny local correctness check,
/// with complete state and logit bytes observed after each committed frame.
func checkQwenLayerStageProfiledParity(fixture: QwenLayerStageFixture,
    proof: QwenLayerStageLoaderCheck, promptCount: Int, check: () throws -> Void
) throws -> QwenLayerStageProfiledParityResult {
    guard proof.loaderProofCompleted, proof.stages.count == 2,
          [1025, 8192].contains(promptCount),
          !FileManager.default.fileExists(atPath: fixture.directory.path) else {
        throw ProbeError("Profiled parity requires the completed tiny loader proof and fixed long workload")
    }
    let spec = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1,
        requestID: UUID(), batchSize: 1, promptCount: promptCount, chunkSize: 512, outputCount: 1)
    let vocabulary = fixture.baseline.vocabularySize
    let prompt = (0..<promptCount).map { 3 + (($0 * 17 + 7) % (vocabulary - 3)) }
    let request = try QwenLayerStageProfiledPrefillRecordedRequest(request: spec,
        vocabularySize: vocabulary, prompt: prompt, teacher: [])
    return try withQwenLayerStageProfiledFixtureOwners(fixture: fixture, proof: proof,
        request: spec, includeBaseline: true) { baseline, pair in
        guard let baseline else { throw ProbeError("Profiled parity is missing its independent baseline owner") }
        let first = pair.first, second = pair.second
        var frames: [QwenLayerStageFrameCheck] = []
        var selection: (Int, Int)?
        for step in request.steps {
            let frame = try autoreleasepool {
                let reference = try baseline.prefillChunk(step.tokenIDs, final: step.frame.finalPromptChunk, check: check)
                let output = try pair.prefillChunk(step.tokenIDs, final: step.frame.finalPromptChunk, check: check)
                let candidate: MLXArray
                switch output {
                case .logits(let array) where step.frame.finalPromptChunk: candidate = array
                case .evaluationHandle(let array) where !step.frame.finalPromptChunk: candidate = array
                default: throw ProbeError("Profiled pair returned an unexpected narrowed output")
                }
                guard reference.shape == candidate.shape, reference.dtype == candidate.dtype,
                      baseline.committedTokens == step.committedTokens,
                      first.committedTokens == step.committedTokens, second.committedTokens == step.committedTokens else {
                    throw ProbeError("Profiled stages lost the exact full-model output geometry or frontier")
                }
                let original = try baseline.snapshot(includeBytes: true, check: check)
                let parts = try [first.snapshot(includeBytes: true, check: check),
                                 second.snapshot(includeBytes: true, check: check)]
                let comparedBytes = try compareProfiledTinyState(original, parts: parts)
                let logits: GDNProjectionValues?
                if step.frame.finalPromptChunk {
                    guard selection == nil, reference.shape == [1, vocabulary],
                          reference.asData(access: .copy).data == candidate.asData(access: .copy).data else {
                        throw ProbeError("Profiled full native vocabulary bytes differ from the same-chunk baseline")
                    }
                    let originalToken = argMax(reference), stageToken = argMax(candidate)
                    let originalFinite = all(isFinite(reference)), stageFinite = all(isFinite(candidate))
                    eval(originalToken, stageToken, originalFinite, stageFinite); try check()
                    guard originalFinite.item(Bool.self), stageFinite.item(Bool.self),
                          originalToken.dtype == .uint32, stageToken.dtype == .uint32,
                          originalToken.size == 1, stageToken.size == 1 else {
                        throw ProbeError("Profiled native finite argmax did not return the expected scalars")
                    }
                    let a = originalToken.item(Int.self), b = stageToken.item(Int.self); try check()
                    guard a == b, (0..<vocabulary).contains(a) else {
                        throw ProbeError("Profiled full/staged first-token selection differs")
                    }
                    selection = (a, b)
                    logits = try GDNProjectionValues(candidate, maximumValues: 512, check: check)
                } else { logits = nil }
                return QwenLayerStageFrameCheck(phase: "prefill", committedTokens: original.committedTokens,
                    stateEntriesCompared: original.entries.count, stateBytesCompared: comparedBytes,
                    fullStateSHA256: original.fingerprint, stateShapesDTypesAndBytesExact: true,
                    logits: logits, logitsBytesExact: step.frame.finalPromptChunk ? true : nil)
            }
            frames.append(frame)
        }
        guard let selection, frames.count == spec.prefillFrameCount else {
            throw ProbeError("Profiled parity omitted a frame or final token")
        }
        try baseline.close(); try pair.close(); try check()
        guard baseline.isClosed, !baseline.isFailed, first.isClosed, !first.isFailed,
              second.isClosed, !second.isFailed else { throw ProbeError("Profiled requests did not retire cleanly") }
        return .init(syntheticDType: fixture.syntheticDType, sourceConfigurationSHA256: fixture.baseline.configHash,
            artifactAggregateSHA256: fixture.fixture.aggregateSHA256, planSHA256: fixture.plan.fingerprint,
            request: request, frames: frames, baselineSelectedToken: selection.0,
            stageSelectedToken: selection.1, allRequestsRetired: true)
    }
}

private func compareProfiledTinyState(_ original: CBv2OwnedStateSnapshot,
    parts: [CBv2OwnedStateSnapshot]
) throws -> Int {
    let entries = parts.flatMap(\.entries).sorted {
        ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component)
    }
    guard original.entries.count == 18, entries.count == original.entries.count,
          parts.count == 2, parts.allSatisfy({ $0.committedTokens == original.committedTokens }),
          Set(entries.map { "\($0.globalLayerIndex)|\($0.component)" }).count == entries.count else {
        throw ProbeError("Profiled tiny state does not cover all global components exactly once")
    }
    var comparedBytes = 0
    for (a, b) in zip(original.entries, entries) {
        guard a.globalLayerIndex == b.globalLayerIndex, a.component == b.component,
              a.shape == b.shape, a.dtype == b.dtype, a.byteCount == b.byteCount,
              let originalBytes = a.bytes, let stageBytes = b.bytes,
              originalBytes.count == a.byteCount, stageBytes.count == b.byteCount,
              originalBytes == stageBytes, a.sha256 == b.sha256 else {
            throw ProbeError("Profiled state differs at layer \(a.globalLayerIndex), \(a.component), frontier \(original.committedTokens)")
        }
        comparedBytes += a.byteCount
    }
    return comparedBytes
}
