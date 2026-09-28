import Foundation

enum QwenLayerStagePrefillRankAdmission {
    static func validateOptions(_ options: Options) throws {
        // This foreign mode must reject before cloning into the serialized rank admission.
        guard options.stageCut == nil else {
            throw ProbeError("--stage-cut is only admitted by explicit short compare/rank or long reference/pair/rank modes")
        }
        guard options.mode == .qwenLayerStagePrefillRankCheck,
              options.decodeCount == 1, options.teacherTokensFile == nil,
              options.stagePrefillPolicy != nil,
              let logitsDType = options.stageLogitsDType,
              ["float16", "bfloat16", "float32"].contains(logitsDType) else {
            throw ProbeError("Prefill rank check requires output one, no teacher, explicit stage-prefill-policy and independently qualified stage-logits-dtype")
        }
        try QwenLayerStageRankAdmission.validateOptions(serializedOptions(options))
    }

    static func preflight(_ options: Options) throws -> QwenLayerStageComparisonAdmission.Inputs {
        try validateOptions(options)
        return try QwenLayerStageRankAdmission.preflight(serializedOptions(options))
    }

    private static func serializedOptions(_ options: Options) -> Options {
        var result = options
        result.mode = .qwenLayerStageRankCheck
        result.stagePrefillPolicy = nil; result.stageLogitsDType = nil
        return result
    }
}

func checkQwenLayerStagePrefillRankAdmission() throws {
    let common = ["--mode", "qwen-layer-stage-prefill-rank-check", "--model-dir", "unused",
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--transport", "loopback-test", "--epoch", String(repeating: "b", count: 32),
        "--execution-path", "cbv2-contiguous", "--tokens-file", "unused", "--prompt-tokens", "65",
        "--chunk-size", "32", "--decode-tokens", "1", "--repeats", "1", "--warmups", "0", "--timeout-seconds", "180"]
    var accepted = 0, rejected = 0
    for policy in QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy.allCases {
        for dtype in ["float16", "bfloat16", "float32"] {
            _ = try Options(arguments: common + ["--stage-prefill-policy", policy.rawValue, "--stage-logits-dtype", dtype])
            accepted += 1
        }
    }
    let basic = common + ["--stage-prefill-policy", "serial_v1", "--stage-logits-dtype", "bfloat16"]
    func reject(_ arguments: [String]) throws {
        do { _ = try Options(arguments: arguments) } catch { rejected += 1; return }
        throw ProbeError("Prefill rank admission accepted an incompatible or unspecified measurement policy")
    }
    for extra in [["--decode-tokens", "2"], ["--teacher-tokens-file", "unused"], ["--stage-prefill-policy", "unknown"],
        ["--stage-logits-dtype", "uint32"], ["--transport", "jaccl"], ["--epoch", "bad"], ["--synthetic"],
        ["--prompt-tokens", "129"], ["--chunk-size", "33"], ["--repeats", "2"], ["--warmups", "1"],
        ["--timeout-seconds", "181"], ["--execution-path", "ordinary"], ["--mode", "qwen-layer-stage-rank-check"]] {
        try reject(basic + extra)
    }
    for flag in ["--stage-prefill-policy", "--stage-logits-dtype", "--epoch", "--artifact-aggregate-sha256"] {
        var missing = basic; let index = missing.firstIndex(of: flag)!
        missing.removeSubrange(index...(index + 1)); try reject(missing)
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_prefill_rank_admission", cpuOnly = true
        let acceptedCases: Int, rejectedCases: Int
    }
    try emitJSON(Result(acceptedCases: accepted, rejectedCases: rejected))
}
