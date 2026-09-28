import Foundation
import MLX

struct QwenLayerStageFrameCheck: Encodable {
    let phase: String
    let committedTokens: Int
    let stateEntriesCompared: Int
    let stateBytesCompared: Int
    let fullStateSHA256: String
    let stateShapesDTypesAndBytesExact: Bool
    let logits: GDNProjectionValues?
    let logitsBytesExact: Bool?
}

struct QwenLayerStageParityResult: Encodable {
    let kind = "qwen_layer_stage_parity_check"
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let syntheticDType: String
    let wrapped: Bool
    let fp16LayerMetadata: Bool
    let sourceConfigurationSHA256: String
    let artifactAggregateSHA256: String
    let planSHA256: String
    let promptTokenIDs: [Int]
    let teacherTokenIDs: [Int]
    let frames: [QwenLayerStageFrameCheck]
    let missingResidualRejectedAndRetired: Bool
    let allRequestsRetired: Bool
    let sourceFilesDeletedBeforeForward = true
    let sequentialOneProcessOnly = true
    let nativeBoundaryBytesCopied = true
}

/// Independent full-model state owner remains unchanged apart from a snapshot
/// hook. Compare complete remapped state bytes after every prompt/decode frame.
func checkQwenLayerStageParity(fixture: QwenLayerStageFixture,
    proof: QwenLayerStageLoaderCheck, options: Options, check: () throws -> Void
) throws -> QwenLayerStageParityResult {
    guard proof.loaderProofCompleted, proof.stages.count == 2,
        !FileManager.default.fileExists(atPath: fixture.directory.path) else {
        throw ProbeError("Stage parity must follow completed loader/source-deletion proof")
    }
    let prompt = try promptTokens(options: options, vocabularySize: fixture.baseline.vocabularySize)
    let teacher = (0..<(options.decodeCount - 1)).map { 3 + (($0 * 13 + 9) % (fixture.baseline.vocabularySize - 3)) }
    let request = try QwenLayerStageRequestSpec(requestID: UUID(), promptCount: prompt.count,
        chunkSize: options.chunkSize, outputCount: options.decodeCount)

    // Wrong ingress must throw before an inactive embedding can be invoked.
    let rejected = try QwenLayerStageSession(stage: proof.stages[1], plan: fixture.plan, request: request)
    var missingResidualRejected = false
    do {
        _ = try rejected.prefillChunk(Array(prompt.prefix(request.chunkSize)), offset: 0,
            final: prompt.count <= request.chunkSize, check: check)
    } catch {
        guard String(describing: error).contains("boundary"), rejected.isClosed, rejected.isFailed else {
            throw ProbeError("Missing stage residual failed without the expected ingress rejection/retirement: \(error)")
        }
        missingResidualRejected = true
    }
    guard missingResidualRejected else { throw ProbeError("Stage one accepted missing residual input") }

    let baseline = try CBv2RequestSession(loaded: fixture.baseline,
        promptCount: prompt.count, outputCount: options.decodeCount)
    defer { try? baseline.close() }
    let first = try QwenLayerStageSession(stage: proof.stages[0], plan: fixture.plan, request: request)
    defer { if !first.isClosed { try? first.cancel() } }
    let second = try QwenLayerStageSession(stage: proof.stages[1], plan: fixture.plan, request: request)
    defer { if !second.isClosed { try? second.cancel() } }
    let pair = try QwenSequentialStagePair(first: first, second: second)
    var frames: [QwenLayerStageFrameCheck] = []

    func compareFrame(phase: String, reference: MLXArray,
        output: QwenLayerStageOutput, expectsLogits: Bool) throws -> QwenLayerStageFrameCheck {
        let candidate: MLXArray
        switch output {
        case .logits(let array) where expectsLogits: candidate = array
        case .evaluationHandle(let array) where !expectsLogits: candidate = array
        default: throw ProbeError("Stage pair returned the wrong frame output kind")
        }
        guard reference.shape == candidate.shape, reference.dtype == candidate.dtype,
            baseline.committedTokens == first.committedTokens,
            first.committedTokens == second.committedTokens else {
            throw ProbeError("Stage pair output geometry/dtype or token frontier differs from full model")
        }
        let original = try baseline.snapshot(includeBytes: true, check: check)
        let parts = try [first.snapshot(includeBytes: true, check: check),
                         second.snapshot(includeBytes: true, check: check)]
        let entries = parts.flatMap(\.entries).sorted {
            ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component)
        }
        guard original.entries.count == 18, entries.count == original.entries.count,
            parts.allSatisfy({ $0.committedTokens == original.committedTokens }),
            Set(entries.map { "\($0.globalLayerIndex)|\($0.component)" }).count == entries.count else {
            throw ProbeError("Stage pair failed complete, disjoint global state coverage")
        }
        var comparedBytes = 0
        for (a, b) in zip(original.entries, entries) {
            guard a.globalLayerIndex == b.globalLayerIndex, a.component == b.component,
                a.shape == b.shape, a.dtype == b.dtype, a.byteCount == b.byteCount,
                let originalBytes = a.bytes, let stageBytes = b.bytes,
                originalBytes.count == a.byteCount, stageBytes.count == b.byteCount,
                originalBytes == stageBytes, a.sha256 == b.sha256 else {
                throw ProbeError("Stage state differs at global layer \(a.globalLayerIndex), \(a.component), frontier \(original.committedTokens)")
            }
            comparedBytes += a.byteCount
        }
        let logits: GDNProjectionValues?
        if expectsLogits {
            guard reference.shape == [1, fixture.baseline.vocabularySize],
                reference.asData().data == candidate.asData().data else {
                throw ProbeError("Stage logits differ from full model at frontier \(original.committedTokens)")
            }
            try check()
            logits = try GDNProjectionValues(candidate, maximumValues: 512, check: check)
        } else { logits = nil }
        return .init(phase: phase, committedTokens: original.committedTokens,
            stateEntriesCompared: entries.count, stateBytesCompared: comparedBytes,
            fullStateSHA256: original.fingerprint, stateShapesDTypesAndBytesExact: true,
            logits: logits, logitsBytesExact: expectsLogits ? true : nil)
    }

    for offset in stride(from: 0, to: prompt.count, by: options.chunkSize) {
        let end = min(prompt.count, offset + options.chunkSize)
        let tokens = Array(prompt[offset..<end]), final = end == prompt.count
        let reference = try baseline.prefillChunk(tokens, final: final, check: check)
        let output = try pair.prefillChunk(tokens, final: final, check: check)
        frames.append(try compareFrame(phase: "prefill", reference: reference,
            output: output, expectsLogits: final))
    }
    for token in teacher {
        let reference = try baseline.decode(token, check: check)
        let output = try pair.decode(token, check: check)
        frames.append(try compareFrame(phase: "decode", reference: reference,
            output: output, expectsLogits: true))
    }
    try baseline.close(); try pair.close(); try check()
    guard baseline.isClosed, first.isClosed, second.isClosed,
        !baseline.isFailed, !first.isFailed, !second.isFailed else {
        throw ProbeError("Successful full/staged requests did not retire cleanly")
    }
    return .init(syntheticDType: fixture.syntheticDType, wrapped: fixture.wrapped,
        fp16LayerMetadata: fixture.fp16FFNMetadata,
        sourceConfigurationSHA256: fixture.baseline.configHash,
        artifactAggregateSHA256: fixture.fixture.aggregateSHA256, planSHA256: fixture.plan.fingerprint,
        promptTokenIDs: prompt, teacherTokenIDs: teacher, frames: frames,
        missingResidualRejectedAndRetired: missingResidualRejected, allRequestsRetired: true)
}
