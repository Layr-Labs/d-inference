import Foundation

/// A distinct bounded real-model loopback mode. It never enters TP loading or
/// persistent-worker semantics; the existing comparison preflight owns inputs.
enum QwenLayerStageRankAdmission {
    static func validateOptions(_ options: Options) throws {
        guard options.mode == .qwenLayerStageRankCheck, options.transport == .loopbackTest,
            let epoch = options.epoch, epoch.count == 32,
            epoch.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ProbeError("qwen-layer-stage-rank-check requires explicit loopback-test and a fresh cohort epoch")
        }
        try QwenLayerStageComparisonAdmission.validateOptions(comparisonOptions(options))
    }

    static func preflight(_ options: Options) throws -> QwenLayerStageComparisonAdmission.Inputs {
        try validateOptions(options)
        let inputs = try QwenLayerStageComparisonAdmission.preflight(comparisonOptions(options))
        guard let root = try JSONSerialization.jsonObject(with: inputs.configurationData) as? [String: Any] else {
            throw ProbeError("Rank stage configuration is not an object")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        _ = try QwenStageMetadata.integer(text, "hidden_size", limit: 8192)
        return inputs
    }

    static func requestID(epoch: String) throws -> UUID {
        guard epoch.utf8.count == 32, epoch.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ProbeError("Invalid layer-stage cohort epoch")
        }
        var text = epoch
        for offset in [20, 16, 12, 8] { text.insert("-", at: text.index(text.startIndex, offsetBy: offset)) }
        guard let uuid = UUID(uuidString: text) else { throw ProbeError("Invalid layer-stage cohort UUID") }
        return uuid
    }

    private static func comparisonOptions(_ options: Options) -> Options {
        var comparison = options
        // These three fields select orchestration only. Preserve every model,
        // token, arithmetic, storage, count and timeout gate from the solo proof.
        comparison.mode = .qwenLayerStageCompare
        comparison.transport = .jaccl
        comparison.epoch = nil
        return comparison
    }
}

func checkQwenLayerStageRankAdmission() throws {
    let basic = ["--mode", "qwen-layer-stage-rank-check", "--model-dir", "unused",
        "--artifact-aggregate-sha256", String(repeating: "a", count: 64),
        "--transport", "loopback-test", "--epoch", String(repeating: "b", count: 32),
        "--execution-path", "cbv2-contiguous", "--tokens-file", "unused", "--teacher-tokens-file", "unused",
        "--prompt-tokens", "65", "--chunk-size", "32", "--decode-tokens", "4",
        "--repeats", "1", "--warmups", "0", "--timeout-seconds", "180"]
    _ = try Options(arguments: basic)
    var rejected = 0
    func reject(_ arguments: [String]) throws {
        do { _ = try Options(arguments: arguments) } catch { rejected += 1; return }
        throw ProbeError("Layer-stage rank admission accepted incompatible inputs")
    }
    for extra in [["--transport", "jaccl"], ["--epoch", "bad"], ["--synthetic"],
        ["--prompt-tokens", "129"], ["--chunk-size", "33"], ["--decode-tokens", "5"],
        ["--timeout-seconds", "181"], ["--repeats", "2"], ["--warmups", "1"], ["--seed", "8"],
        ["--local-correctness"], ["--execution-path", "ordinary"], ["--partition", "full"],
        ["--attention-output-precision", "float32"], ["--ffn-output-precision", "float32"],
        ["--ffn-branch-precision", "float32"], ["--logits-file", "unused"],
        ["--routing-file", "unused"], ["--routing-replay-file", "unused"],
        ["--gemma-diagnostic"], ["--gemma-boundary-file", "unused"],
        ["--artifact-aggregate-sha256", "bad"]] { try reject(basic + extra) }
    for flag in ["--epoch", "--artifact-aggregate-sha256", "--tokens-file", "--teacher-tokens-file"] {
        var arguments = basic
        let index = arguments.firstIndex(of: flag)!
        arguments.removeSubrange(index...(index + 1))
        try reject(arguments)
    }
    struct Result: Encodable {
        let kind = "qwen_layer_stage_rank_admission", cpuOnly = true
        let rejectedFixtures: Int
    }
    try emitJSON(Result(rejectedFixtures: rejected))
}
