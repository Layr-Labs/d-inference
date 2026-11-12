#if CBV2_WINDOW_STATE_FIXTURE
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

enum WindowedStateLegacyQwenCheck {
    static func require(_ value: Bool, _ message: String) throws {
        try WindowedStateFixtureOwner.require(value, message)
    }

    static func configuration() throws -> Data {
        // Same proven tiny Qwen geometry, with four layers and MTP disabled.
        try JSONSerialization.data(withJSONObject: ["model_type": "qwen3_5_text", "hidden_size": 64,
            "num_hidden_layers": 4, "intermediate_size": 128, "num_attention_heads": 1,
            "num_key_value_heads": 1, "linear_num_value_heads": 1, "linear_num_key_heads": 1,
            "linear_key_head_dim": 32, "linear_value_head_dim": 32, "linear_conv_kernel_dim": 4,
            "vocab_size": 128, "head_dim": 64, "full_attention_interval": 4,
            "num_experts": 0, "num_experts_per_tok": 0, "mtp_num_hidden_layers": 0,
            "tie_word_embeddings": false, "max_position_embeddings": 32768] as [String: Any], options: [.sortedKeys])
    }

    static func run(check: @escaping () throws -> Void) throws -> [String] {
        let configuration = try configuration()
        try check()
        let model = try constructQwenModel(configuration)
        let parameters = model.parameters().flattened().sorted { $0.0 < $1.0 }
        try require(parameters.count < 200 && parameters.reduce(0) { $0 + $1.1.nbytes } < 4 * 1024 * 1024,
            "Tiny Qwen source exceeds fixed fixture envelope")
        var replacements: [(String, MLXArray)] = []
        for (name, old) in parameters {
            try check()
            let salt = name.utf8.reduce(0) { ($0 + Int($1)) % 31 }
            let data = (0..<old.size).map { index -> Float in
                if name.hasSuffix("A_log") { return -1 }
                if name.contains("norm") { return 1 + Float((index + salt) % 5) * 0.02 }
                return Float((index + salt) % 17 - 8) * 0.003
            }
            replacements.append((name, MLXArray(data).reshaped(old.shape)))
        }
        try model.update(parameters: ModuleParameters.unflattened(replacements), verify: [.all])
        model.freeze(); eval(model); try check()
        guard let forward = model as? any CBv2PositionedRecurrentLanguageModelForwardable else { throw ProbeError("Tiny Qwen forward contract differs") }
        func geometry() throws -> CBv2RequestGeometry {
            try .init(model: model, family: .qwen35, feedForwardKind: "dense", layerCount: 4,
                vocabularySize: 128, configurationData: configuration, maximumTokens: 8)
        }
        let state = try CBv2OwnedRequestState(geometry: geometry(), promptCount: 2, outputCount: 6)
        defer { if !state.isClosed { try? state.retire(failed: true) } }
        try require(state.geometry.attentionLayout == nil && state.geometry.recurrent.layers.count == 3
            && state.geometry.kinds.count == 1, "Legacy Qwen unexpectedly entered attention-only state")
        let packets: [[Int32]] = [[1, 2], [3], [4]]
        for tokens in packets {
            _ = try state.run(tokenCount: tokens.count, check: check, forward: { caches, recurrent in
                try check()
                return forward.cbv2Forward(MLXArray(tokens).reshaped([1, tokens.count]),
                    caches: caches.map { $0 as! any KVCache }, recurrentState: [recurrent], positionIds: nil)
            }, validateOutput: { output in
                try require(output.shape == [1, tokens.count, 128]
                    && output.asType(.float32).asArray(Float.self).allSatisfy(\.isFinite), "Tiny Qwen logits differ from finite output geometry")
            })
            let a = try state.snapshot(globalLayerIndices: [0, 1, 2, 3], includeBytes: true, check: check)
            let b = try WindowedStateLegacySnapshotControl.capture(geometry: state.geometry, rows: state.rows,
                recurrent: state.recurrent, committedTokens: state.committedTokens,
                globalLayerIndices: [0, 1, 2, 3], includeBytes: true, check: check)
            try require(a.fingerprint == b.fingerprint && a.entries.map(\.identity) == b.entries.map(\.identity)
                && a.entries.map(\.bytes) == b.entries.map(\.bytes) && a.entries.allSatisfy({ $0.logicalRange == nil }),
                "Legacy actual Qwen v1 snapshot bytes/fingerprint changed")
        }
        try state.retire()
        let missing = try CBv2OwnedRequestState(geometry: geometry(), promptCount: 2, outputCount: 6)
        defer { try? missing.retire(failed: true) }
        var refused = false
        do {
            _ = try missing.run(tokenCount: 1, check: check, forward: { _, _ in MLXArray(Float(0)) }, validateOutput: { _ in })
        } catch {
            guard let error = error as? CBv2RecurrentStateError,
                  error == .lifecycleViolation("recurrent evaluation did not stage every declared layer") else { throw error }
            refused = true
        }
        try missing.retire(failed: true)
        try require(refused && missing.isFailed && missing.isClosed && missing.backend.bytesReserved == 0,
            "Missing nonempty recurrent generation did not refuse and retire")
        try check()
        return ["actual-tiny-qwen-full-and-recurrent-forward", "legacy-v1-snapshot-exact-control",
            "legacy-nonempty-missing-recurrent-refusal"]
    }
}
#endif
