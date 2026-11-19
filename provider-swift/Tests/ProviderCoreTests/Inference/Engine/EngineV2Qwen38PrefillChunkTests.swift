// Copyright © 2026 Eigen Labs.
// Qwen3.8-27B prefills prompts beside decode rows in 1,024-token chunks; every
// other dense Qwen keeps the SDK chunk, and DARKBLOOM_QWEN38_PREFILL_CHUNK=0
// (forwarded to the background provider) restores it for the 27B.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

private func qwen38GeometryModel() throws -> Qwen35Model {
    let json: [String: Any] = [
        "model_type": "qwen3_5",
        "text_config": [
            "model_type": "qwen3_5_text", "hidden_size": 64, "num_hidden_layers": 2,
            "intermediate_size": 64, "num_attention_heads": 1, "num_key_value_heads": 1,
            "head_dim": 64, "linear_num_value_heads": 1, "linear_num_key_heads": 1,
            "linear_key_head_dim": 64, "linear_value_head_dim": 64, "linear_conv_kernel_dim": 4,
            "full_attention_interval": 2, "vocab_size": 64,
        ] as [String: Any],
    ]
    return Qwen35Model(
        try JSONDecoder().decode(
            Qwen35Configuration.self, from: JSONSerialization.data(withJSONObject: json)))
}

@Suite("Qwen3.8-27B prefill chunk")
struct EngineV2Qwen38PrefillChunkTests {
    private let sdk = CBv2SchedulerConfig()

    @Test("both Qwen3.8-27B builds take the 1,024-token chunk and keep the step budget and stripe",
          arguments: ModelRuntimeRequirements.qwen38ConcreteModelIDs.sorted())
    func qwen38TakesItsChunk(modelID: String) throws {
        let geometry = EngineV2Factory.prefillGeometry(
            model: try qwen38GeometryModel(), modelID: modelID, environment: [:])
        #expect(geometry.prefillChunkTokens == EngineV2Factory.qwen38PrefillChunkTokens)
        #expect(EngineV2Factory.qwen38PrefillChunkTokens == 1024)
        // The step budget stays the SDK's, so a step never carries more prompt
        // tokens than before; the solo stripe and the paged rings are unchanged.
        #expect(geometry.maxBatchedTokensPerStep == sdk.maxBatchedTokensPerStep)
        #expect(geometry.soloPrefillStripeTokens == EngineV2Factory.defaultDenseQwenSoloPrefillStripeTokens)
        // Only bidirectional (Gemma) media blocks read this ceiling; Qwen media
        // is causal and takes the 1,024-token plain chunk like text.
        #expect(geometry.bidirectionalMediaPrefillChunkCeiling == sdk.prefillChunkSize)
        // On the 256-token recurrent checkpoint grid.
        #expect(EngineV2Factory.qwen38PrefillChunkTokens % 256 == 0)
    }

    @Test("other dense Qwen ids and an unknown id keep the SDK chunk",
          arguments: [nil, "Qwen3.5-9B", "EigenLabs/Qwen3.8-27B-4bit-mtp-v2", "qwen3.6-35b-a3b-vl-mtp-mxfp8"]
            as [String?])
    func otherIDsKeepSDKChunk(modelID: String?) throws {
        let geometry = EngineV2Factory.prefillGeometry(
            model: try qwen38GeometryModel(), modelID: modelID, environment: [:])
        #expect(geometry.prefillChunkTokens == sdk.prefillChunkSize)
        #expect(geometry.maxBatchedTokensPerStep == sdk.maxBatchedTokensPerStep)
    }

    @Test("the switch: 0, off, false or no keeps the SDK chunk; anything else keeps 1,024",
          arguments: [
            ("0", 512), ("off", 512), (" OFF ", 512), ("false", 512), ("no", 512),
            ("1", 1024), ("on", 1024), ("", 1024), ("2048", 1024),
          ] as [(String, Int)])
    func killSwitch(raw: String, expected: Int) throws {
        let geometry = EngineV2Factory.prefillGeometry(
            model: try qwen38GeometryModel(), modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp",
            environment: [EngineV2Factory.qwen38PrefillChunkKey: raw])
        #expect(geometry.prefillChunkTokens == expected)
    }

    @Test("an explicit DARKBLOOM_CBV2_PREFILL_CHUNK still wins")
    func explicitChunkWins() throws {
        let geometry = EngineV2Factory.prefillGeometry(
            model: try qwen38GeometryModel(), modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp",
            environment: [EngineV2Factory.prefillChunkKey: "512"])
        #expect(geometry.prefillChunkTokens == 512)
    }

    @Test("the production scheduler config carries the 27B chunk")
    func schedulerConfigCarriesChunk() throws {
        let config = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 8, model: try qwen38GeometryModel(),
            modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", environment: [:])
        #expect(config.prefillChunkSize == 1024)
        #expect(config.maxBatchedTokensPerStep == sdk.maxBatchedTokensPerStep)
        #expect(config.soloPrefillStripeTokens == EngineV2Factory.defaultDenseQwenSoloPrefillStripeTokens)
    }

    @Test("the switch reaches the LaunchAgent")
    func rollbackIsForwarded() {
        let key = EngineV2Factory.qwen38PrefillChunkKey
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }
}
