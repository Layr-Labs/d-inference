import Foundation

/// A one-output control for removing per-frame observations, with the original
/// real-model/storage/native arithmetic admission unchanged.
enum QwenLayerStagePrefillAdmission {
    static func validateOptions(_ options: Options) throws {
        // Reject before the shared comparison adapter changes the mode.
        guard options.stageCut == nil else {
            throw ProbeError("--stage-cut is only admitted by qwen-layer-stage-compare")
        }
        guard options.mode == .qwenLayerStagePrefillCheck, options.decodeCount == 1,
              options.teacherTokensFile == nil else {
            throw ProbeError("Stage prefill control requires one output and no teacher history")
        }
        try QwenLayerStageComparisonAdmission.validateOptions(comparisonOptions(options))
    }

    static func preflight(_ options: Options) throws -> QwenLayerStageComparisonAdmission.Inputs {
        try validateOptions(options)
        return try QwenLayerStageComparisonAdmission.preflight(comparisonOptions(options))
    }

    private static func comparisonOptions(_ options: Options) -> Options {
        var result = options
        result.mode = .qwenLayerStageCompare
        return result
    }
}

func checkQwenLayerStagePrefillAdmission() throws {
    let basic = ["--mode", "qwen-layer-stage-prefill-check", "--model-dir", "unused",
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--execution-path", "cbv2-contiguous", "--tokens-file", "unused",
        "--prompt-tokens", "65", "--chunk-size", "32", "--decode-tokens", "1",
        "--repeats", "1", "--warmups", "0", "--timeout-seconds", "180"]
    _ = try Options(arguments: basic)
    let invalid = [["--decode-tokens", "2"], ["--teacher-tokens-file", "unused"],
        ["--decode-tokens", "2", "--teacher-tokens-file", "unused"], ["--prompt-tokens", "129"],
        ["--chunk-size", "33"], ["--local-correctness"], ["--warmups", "1"],
        ["--transport", "loopback-test"], ["--epoch", String(repeating: "b", count: 32)],
        ["--execution-path", "ordinary"]]
    for extra in invalid {
        do { _ = try Options(arguments: basic + extra) }
        catch { continue }
        throw ProbeError("Stage prefill control accepted incompatible input or execution policy")
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_prefill_admission", cpuOnly = true
        let acceptedFixtures = 1, rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: invalid.count))
}
