// Copyright © 2026 Eigen Labs.
// Qwen3.8-27B on an M5 Ultra prefills prompts beside decode rows in 1,024-token
// chunks; other chips and every other dense Qwen keep the SDK chunk, and
// DARKBLOOM_QWEN38_PREFILL_CHUNK=0 (forwarded to the background provider)
// restores it for the 27B.

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

private let m5Ultra: (family: ChipFamily, tier: ChipTier) = (.m5, .ultra)

@Suite("Qwen3.8-27B prefill chunk")
struct EngineV2Qwen38PrefillChunkTests {
    private let sdk = CBv2SchedulerConfig()

    @Test("both Qwen3.8-27B builds take the 1,024-token chunk on an M5 Ultra and keep the step budget and stripe",
          arguments: ModelRuntimeRequirements.qwen38ConcreteModelIDs.sorted())
    func qwen38TakesItsChunk(modelID: String) throws {
        let geometry = EngineV2Factory.prefillGeometry(
            model: try qwen38GeometryModel(), modelID: modelID, chipIdentity: m5Ultra, environment: [:])
        #expect(geometry.prefillChunkTokens == EngineV2Factory.qwen38PrefillChunkTokens)
        #expect(EngineV2Factory.qwen38PrefillChunkTokens == 1024)
        // The step budget, the solo stripe and the paged rings are unchanged.
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
            model: try qwen38GeometryModel(), modelID: modelID, chipIdentity: m5Ultra, environment: [:])
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
            chipIdentity: m5Ultra, environment: [EngineV2Factory.qwen38PrefillChunkKey: raw])
        #expect(geometry.prefillChunkTokens == expected)
    }

    @Test("other chips and an unknown chip keep the SDK chunk for the 27B",
          arguments: [
            (ChipFamily.m5, ChipTier.max), (.m5, .pro), (.m5, .base), (.m4, .max), (.m3, .ultra),
            (.m6, .ultra), (.unknown, .unknown),
          ] as [(ChipFamily, ChipTier)])
    func otherChipsKeepSDKChunk(family: ChipFamily, tier: ChipTier) throws {
        let config = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 8, model: try qwen38GeometryModel(),
            modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", chipIdentity: (family, tier), environment: [:])
        #expect(config.prefillChunkSize == sdk.prefillChunkSize)
        #expect(config.maxBatchedTokensPerStep == sdk.maxBatchedTokensPerStep)
    }

    @Test("the serving policy hands its chip to the scheduler geometry")
    func servingPolicyForwardsChip() throws {
        func chunk(_ chip: (family: ChipFamily, tier: ChipTier)?) throws -> Int {
            EngineV2Factory.productionServingPolicy(
                model: try qwen38GeometryModel(), modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp",
                modelArtifactSHA256: nil, constructionPurpose: .serving,
                automaticallySelectConcurrency: true, performanceQualificationAllowed: true,
                backend: .paged, maxContextLength: 8192, maxConcurrentRequests: 4,
                environment: [:], chipIdentity: chip
            ).scheduler.prefillChunkSize
        }
        #expect(try chunk((.m5, .ultra)) == 1024)
        #expect(try chunk((.m5, .max)) == sdk.prefillChunkSize)
        #expect(try chunk(nil) == sdk.prefillChunkSize)
    }

    @Test("no chip identity keeps the SDK chunk")
    func noChipKeepsSDKChunk() throws {
        let geometry = EngineV2Factory.prefillGeometry(
            model: try qwen38GeometryModel(), modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp",
            chipIdentity: nil, environment: [:])
        #expect(geometry.prefillChunkTokens == sdk.prefillChunkSize)
    }

    @Test("an explicit DARKBLOOM_CBV2_PREFILL_CHUNK still wins")
    func explicitChunkWins() throws {
        let geometry = EngineV2Factory.prefillGeometry(
            model: try qwen38GeometryModel(), modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp",
            chipIdentity: m5Ultra, environment: [EngineV2Factory.prefillChunkKey: "512"])
        #expect(geometry.prefillChunkTokens == 512)
    }

    @Test("the production scheduler config carries the 27B chunk")
    func schedulerConfigCarriesChunk() throws {
        let config = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 8, model: try qwen38GeometryModel(),
            modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", chipIdentity: m5Ultra, environment: [:])
        #expect(config.prefillChunkSize == 1024)
        #expect(config.maxBatchedTokensPerStep == sdk.maxBatchedTokensPerStep)
        #expect(config.soloPrefillStripeTokens == EngineV2Factory.defaultDenseQwenSoloPrefillStripeTokens)
    }

    @Test("the default equals the switch off plus an explicit 1,024-token chunk")
    func defaultEqualsExplicitChunk() throws {
        let model = try qwen38GeometryModel()
        let id = "EigenLabs/Qwen3.8-27B-4bit-mtp"
        let byDefault = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 8, model: model, modelID: id, chipIdentity: m5Ultra,
            environment: [:])
        let explicit = EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 8, model: model, modelID: id, chipIdentity: m5Ultra,
            environment: [
                EngineV2Factory.qwen38PrefillChunkKey: "0", EngineV2Factory.prefillChunkKey: "1024",
            ])
        #expect(byDefault.prefillChunkSize == explicit.prefillChunkSize)
        #expect(byDefault.maxBatchedTokensPerStep == explicit.maxBatchedTokensPerStep)
        #expect(byDefault.soloPrefillStripeTokens == explicit.soloPrefillStripeTokens)
        #expect(byDefault.bidirectionalMediaPrefillChunkCeiling
            == explicit.bidirectionalMediaPrefillChunkCeiling)
        #expect(byDefault.mixedStepPrefillTokenCap == explicit.mixedStepPrefillTokenCap)
        #expect(byDefault.maxConcurrentPartialPrefills == explicit.maxConcurrentPartialPrefills)
    }

    @Test("the switch reaches the LaunchAgent")
    func rollbackIsForwarded() {
        let key = EngineV2Factory.qwen38PrefillChunkKey
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }
}
