import Foundation

/// Real-artifact comparison retains exact bounded input bytes before model IO.
enum QwenLayerStageComparisonAdmission {
    struct Inputs {
        let configurationData: Data
        let plan: QwenLayerStagePlan
        let prompt: [Int]
        let teacher: [Int]
        let vocabularySize: Int
        let conservativeStateAndBoundaryBytes: Int
    }

    static func validateOptions(_ options: Options) throws {
        guard options.mode == .qwenLayerStageCompare, !options.synthetic,
            options.modelDirectory != nil, options.tokensFile != nil,
            let pin = options.expectedArtifactAggregateSHA256, pin.utf8.count == 64,
            pin.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            !options.localCorrectness, options.executionPath == .cbv2Contiguous,
            options.transport == .jaccl, options.partition == .ffn,
            options.attentionOutputPrecision == .native, options.ffnOutputPrecision == .native,
            options.ffnBranchPrecision == .native, !options.hasRoutingDiagnostic,
            !options.gemmaDiagnostic, options.gemmaBoundaryFile == nil, options.logitsFile == nil,
            options.epoch == nil, options.seed == 7, options.repeats == 1, options.warmups == 0,
            (1...180).contains(options.timeoutSeconds), (1...128).contains(options.promptCount),
            (1...32).contains(options.chunkSize), (1...4).contains(options.decodeCount),
            (options.teacherTokensFile != nil) == (options.decodeCount > 1) else {
            throw ProbeError("qwen-layer-stage-compare requires pinned real dense Qwen, actual prompt/teacher inputs, native CBv2, prompt<=128, chunk<=32, output<=4, one run, seed7, zero warmups, timeout<=180 and no other diagnostics")
        }
    }

    static func preflight(_ options: Options) throws -> Inputs {
        try validateOptions(options)
        let data = try BoundedProbeInput.data(options.modelDirectory!.appendingPathComponent("config.json"),
            maximumBytes: 1_048_576)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError("Stage comparison configuration must be an object")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        let layers = try QwenStageMetadata.integer(text, "num_hidden_layers", limit: 128)
        guard layers % 2 == 0 else { throw ProbeError("Stage comparison requires an even phase-aligned layer split") }
        let plan = try QwenLayerStagePlan(configuration: data, ranges: [0..<(layers / 2), (layers / 2)..<layers])
        let vocabulary = try QwenStageMetadata.integer(text, "vocab_size", limit: 262144)
        let context = try QwenStageMetadata.integer(text, "max_position_embeddings", limit: 1048576)
        guard vocabulary > 3, options.promptCount + options.decodeCount <= context else {
            throw ProbeError("Stage comparison exceeds model vocabulary/context")
        }
        let prompt = try BoundedProbeInput.tokenIDs(options.tokensFile!)
        let teacher = try options.teacherTokensFile.map { try BoundedProbeInput.tokenIDs($0) } ?? []
        guard prompt.count == options.promptCount, teacher.count == options.decodeCount - 1,
            (prompt + teacher).allSatisfy({ (0..<vocabulary).contains($0) }) else {
            throw ProbeError("Stage comparison actual token count/history is outside admitted bounds")
        }
        let bytes = try conservativeStateAndBoundaryBytes(text: text, plan: plan,
            maximumTokens: prompt.count + options.decodeCount, chunkSize: options.chunkSize)
        return .init(configurationData: data, plan: plan, prompt: prompt, teacher: teacher,
            vocabularySize: vocabulary, conservativeStateAndBoundaryBytes: bytes)
    }

    /// Pinned Qwen configuration's CBv2 shapes, using four-byte activation/KV
    /// elements and three live recurrent generations. Add one largest CPU state
    /// snapshot and two boundary arrays. This is an admission bound for these
    /// named tensors only, not an allocator/workspace/process-memory guarantee.
    private static func conservativeStateAndBoundaryBytes(text: [String: Any], plan: QwenLayerStagePlan,
        maximumTokens: Int, chunkSize: Int) throws -> Int {
        func n(_ key: String) -> Int { BoundedProbeInput.integer(text[key])! }
        // The plan has already validated all dimensions and interval alignment.
        let conv = 4 * (n("linear_conv_kernel_dim") - 1) *
            (2 * n("linear_num_key_heads") * n("linear_key_head_dim") +
                n("linear_num_value_heads") * n("linear_value_head_dim"))
        let ssm = 4 * n("linear_num_value_heads") * n("linear_value_head_dim") * n("linear_key_head_dim")
        let attentionLayers = plan.layers / plan.interval
        let kv = 2 * 4 * maximumTokens * n("num_key_value_heads") * n("head_dim")
        let boundary = chunkSize * n("hidden_size") * 4
        let total = 3 * (plan.layers - attentionLayers) * (conv + ssm) +
            attentionLayers * (kv + 4) + max(conv, ssm, kv / 2) + 2 * boundary
        guard total <= 512 * 1024 * 1024 else {
            throw ProbeError("Stage comparison state/snapshot/boundary tensor estimate exceeds 512 MiB")
        }
        return total
    }
}
