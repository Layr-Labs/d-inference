import Foundation

/// The opt-in lookahead diagnostic preserves every real-stage admission gate.
/// It changes wire/scheduling policy only; bare v1 peers fail v2 header admission.
enum QwenLayerStageLookaheadAdmission {
    static func validateOptions(_ options: Options) throws {
        // This foreign mode must reject before cloning into the serialized rank admission.
        guard options.stageCut == nil else {
            throw ProbeError("--stage-cut is only admitted by explicit short compare/rank or long reference/pair/rank modes")
        }
        guard options.mode == .qwenLayerStageLookaheadCheck else {
            throw ProbeError("Expected the explicit layer-stage lookahead diagnostic mode")
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
        return result
    }
}

func checkQwenLayerStageLookaheadAdmission() throws {
    let basic = ["--mode", "qwen-layer-stage-lookahead-check", "--model-dir", "unused",
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--transport", "loopback-test", "--epoch", String(repeating: "b", count: 32),
        "--execution-path", "cbv2-contiguous", "--tokens-file", "unused", "--teacher-tokens-file", "unused",
        "--prompt-tokens", "65", "--chunk-size", "32", "--decode-tokens", "4",
        "--repeats", "1", "--warmups", "0", "--timeout-seconds", "180"]
    _ = try Options(arguments: basic)
    var rejected = 0
    for extra in [["--transport", "jaccl"], ["--epoch", "bad"], ["--synthetic"],
        ["--prompt-tokens", "129"], ["--chunk-size", "33"], ["--decode-tokens", "5"],
        ["--timeout-seconds", "181"], ["--repeats", "2"], ["--warmups", "1"], ["--seed", "8"],
        ["--local-correctness"], ["--execution-path", "ordinary"], ["--partition", "full"],
        ["--attention-output-precision", "float32"], ["--ffn-output-precision", "float32"],
        ["--ffn-branch-precision", "float32"], ["--logits-file", "unused"],
        ["--routing-file", "unused"], ["--routing-replay-file", "unused"],
        ["--gemma-diagnostic"], ["--gemma-boundary-file", "unused"],
        ["--artifact-aggregate-sha256", "bad"]] {
        do { _ = try Options(arguments: basic + extra) } catch { rejected += 1; continue }
        throw ProbeError("Lookahead admission accepted an incompatible policy or unbounded input")
    }
    var withoutTeacher = basic
    let index = withoutTeacher.firstIndex(of: "--teacher-tokens-file")!
    withoutTeacher.removeSubrange(index...(index + 1))
    do { _ = try Options(arguments: withoutTeacher) }
    catch {
        rejected += 1
        struct Result: Encodable {
            let kind = "qwen_layer_stage_lookahead_admission", cpuOnly = true
            let rejectedFixtures: Int
        }
        try emitJSON(Result(rejectedFixtures: rejected))
        return
    }
    throw ProbeError("Lookahead diagnostic admitted multiple outputs without immutable teacher history")
}
