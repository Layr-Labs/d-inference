import Foundation

/// Additive one-request admission; the existing comparison's native/source and
/// named-tensor bounds remain the authority. Reference bytes are retained once.
enum QwenLayerStageSoloPrefillCLIAdmission {
    struct Inputs {
        let comparison: QwenLayerStageComparisonAdmission.Inputs
        let request: QwenLayerStageRecordedRequest
        let reference: QwenLayerStageSoloPrefillReference
    }

    static func validateOptions(_ options: Options) throws {
        // Reject before the shared comparison adapter changes the mode.
        guard options.stageCut == nil else {
            throw ProbeError("--stage-cut is only admitted by qwen-layer-stage-compare or qwen-layer-stage-rank-check")
        }
        guard options.mode == .qwenLayerStageSoloPrefillCheck,
              options.decodeCount == 1, options.teacherTokensFile == nil,
              options.soloReferenceFile != nil,
              let filePin = options.soloReferenceSHA256, qwenStageWireIsSHA256(filePin),
              let evidencePin = options.soloBaselineEvidenceSHA256, qwenStageWireIsSHA256(evidencePin) else {
            throw ProbeError("Solo prefill requires one output, no teacher, and explicit reference file/evidence SHA256 pins")
        }
        try QwenLayerStageComparisonAdmission.validateOptions(comparisonOptions(options))
    }

    static func preflight(_ options: Options) throws -> Inputs {
        try validateOptions(options)
        let admitted = try QwenLayerStageComparisonAdmission.preflight(comparisonOptions(options))
        let request = try QwenLayerStageRecordedRequest(request: .init(requestID: UUID(),
            promptCount: admitted.prompt.count, chunkSize: options.chunkSize, outputCount: 1),
            vocabularySize: admitted.vocabularySize, prompt: admitted.prompt, teacher: [])
        let data = try BoundedProbeInput.data(options.soloReferenceFile!,
            maximumBytes: QwenLayerStageSoloPrefillReference.maximumEncodedBytes)
        let reference = try QwenLayerStageSoloPrefillReference.decode(data,
            expectedFileSHA256: options.soloReferenceSHA256!,
            expectedBaselineEvidenceFingerprint: options.soloBaselineEvidenceSHA256!,
            plan: admitted.plan, request: request)
        return .init(comparison: admitted, request: request, reference: reference)
    }

    private static func comparisonOptions(_ options: Options) -> Options {
        var value = options
        value.mode = .qwenLayerStageCompare
        value.soloReferenceFile = nil
        value.soloReferenceSHA256 = nil
        value.soloBaselineEvidenceSHA256 = nil
        return value
    }
}

func checkQwenLayerStageSoloPrefillCLIAdmission() throws {
    let basic = ["--mode", "qwen-layer-stage-solo-prefill-check", "--model-dir", "unused",
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--execution-path", "cbv2-contiguous", "--tokens-file", "unused", "--prompt-tokens", "65",
        "--chunk-size", "32", "--decode-tokens", "1", "--repeats", "1", "--warmups", "0",
        "--timeout-seconds", "180", "--solo-reference-file", "unused-reference",
        "--solo-reference-sha256", String(repeating: "b", count: 64),
        "--solo-baseline-evidence-sha256", String(repeating: "c", count: 64)]
    _ = try Options(arguments: basic)
    let invalid = [["--decode-tokens", "2"], ["--teacher-tokens-file", "unused"],
        ["--prompt-tokens", "129"], ["--chunk-size", "33"], ["--warmups", "1"], ["--repeats", "2"],
        ["--local-correctness"], ["--transport", "loopback-test"],
        ["--epoch", String(repeating: "d", count: 32)], ["--execution-path", "ordinary"],
        ["--stage-prefill-policy", "serial_v1"], ["--stage-logits-dtype", "bfloat16"],
        ["--solo-reference-sha256", "invalid"], ["--solo-baseline-evidence-sha256", "invalid"],
        ["--mode", "qwen-layer-stage-compare"], ["--mode", "qwen-layer-stage-prefill-check"]]
    for extra in invalid {
        do { _ = try Options(arguments: basic + extra) }
        catch { continue }
        throw ProbeError("Solo prefill accepted incompatible native/reference admission")
    }
    var rejected = invalid.count
    for option in ["--solo-reference-file", "--solo-reference-sha256", "--solo-baseline-evidence-sha256"] {
        let index = basic.firstIndex(of: option)!
        var missing = basic
        missing.removeSubrange(index...(index + 1))
        do { _ = try Options(arguments: missing) }
        catch { rejected += 1; continue }
        throw ProbeError("Solo prefill accepted a missing reference input pin")
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_solo_prefill_cli_admission", cpuOnly = true
        let acceptedFixtures = 1, rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: rejected))
}
