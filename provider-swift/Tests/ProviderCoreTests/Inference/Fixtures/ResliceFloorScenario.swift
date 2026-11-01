// Copyright © 2026 Eigen Labs.

import Foundation
import MLX

@testable import MLXLLM
@testable import MLXLMCommon
@testable import ProviderCore

/// The 0.10.5 "would leave a model without its fixed request workspace"
/// refusal: six catalog models resident on a 192 GB Mac, then
/// gemma-4-26b-qat-4bit or gpt-oss-20b as the seventh slot. Configuration
/// only: no weights, forward pass or tensor evaluation.
///
/// KV rates are the engine's marginal fp16 rate (full-attention rows only).
/// Weights are the production catalog's `total_size_bytes`. Fixed request
/// workspace is each engine's recurrent state per request, a lower bound:
/// it leaves out allocator rounding, convolution state for Nemotron, and
/// assistant history. A slot's floor is what `EngineV2Bridge
/// .minimumServiceableGrantBytes` reports for that workspace.
enum ResliceFloorScenario {
    struct Model {
        let id: String
        let modelType: String
        let fp16KVBytesPerToken: Int
        let maxContextLength: Int
        let weightsBytes: Int
        let fixedRequestBytes: Int

        var resliceSlot: EngineV2KVSizing.ResliceSlot {
            .init(modelId: id, fp16KVBytesPerToken: fp16KVBytesPerToken, maxContextLength: maxContextLength)
        }

        var sizing: SlotSizingSnapshot {
            .init(weightsBytes: weightsBytes, fp16KVBytesPerToken: fp16KVBytesPerToken,
                  maxContextLength: maxContextLength, defaultMaxTokens: 8192)
        }

        var minimumGrantBytes: Int { ResliceFloorScenario.minimumGrantBytes(fixedRequestBytes: fixedRequestBytes) }
    }

    static let physicalBytes: UInt64 = 192 << 30

    /// The fleet budgets the reporting provider logged for the two refusals.
    static let reportedGemmaBudget: UInt64 = 51_467_271_830
    static let reportedGPTOSSBudget: UInt64 = 54_999_766_706

    static let gemmaQAT = Model(id: "gemma-4-26b-qat-4bit", modelType: "gemma4",
        fp16KVBytesPerToken: 20_480, maxContextLength: 262_144,
        weightsBytes: 15_641_239_295, fixedRequestBytes: 0)
    static let gptOSS = Model(id: "gpt-oss-20b", modelType: "gpt_oss",
        fp16KVBytesPerToken: 24_576, maxContextLength: 131_072,
        weightsBytes: 12_104_215_835, fixedRequestBytes: 0)

    /// The resident set. Its Qwen recurrent rows come from decoding each
    /// model's text configuration. With MTP on (`mtp_mode = auto`), Qwen
    /// adds one compact-replay generation to the three base generations;
    /// Nemotron Lightning's request-stateful assistant at the tested depth
    /// adds depth − 1.
    static func residents() throws -> [Model] {
        let base = CBv2RecurrentStateSpec.maximumLiveGenerations
        let depth = CBv2MTPConfig.testedMaxDraftTokens
        let wide = try qwenGeneration(wide: true)
        let narrow = try qwenGeneration(wide: false)
        // 23 Mamba-2 layers, FP32 SSM state [64 heads, 64, 128] each.
        let lightningGeneration = 23 * 64 * 64 * 128 * 4
        return [
            Model(id: "ternary-bonsai-2-27b", modelType: "prism_hadamard_qwen35",
                  fp16KVBytesPerToken: 65_536, maxContextLength: 262_144,
                  weightsBytes: 8_608_670_713, fixedRequestBytes: base * wide),
            Model(id: "qwen3.6-35b-a3b-vl-mtp-mxfp8", modelType: "qwen3_5_moe",
                  fp16KVBytesPerToken: 20_480, maxContextLength: 262_144,
                  weightsBytes: 21_308_856_601, fixedRequestBytes: (base + 1) * narrow),
            Model(id: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: "qwen3_5",
                  fp16KVBytesPerToken: 65_536, maxContextLength: 262_144,
                  weightsBytes: 16_320_415_757, fixedRequestBytes: (base + 1) * wide),
            Model(id: "gemma-4-26b", modelType: "gemma4",
                  fp16KVBytesPerToken: 20_480, maxContextLength: 262_144,
                  weightsBytes: 27_986_040_506, fixedRequestBytes: 0),
            Model(id: "qwen3.5-35b-a3b", modelType: "qwen3_5_moe",
                  fp16KVBytesPerToken: 20_480, maxContextLength: 262_144,
                  weightsBytes: 20_893_747_852, fixedRequestBytes: (base + 1) * narrow),
            Model(id: "nvidia-nemotron-3.5-lightning", modelType: "nemotron_h",
                  fp16KVBytesPerToken: 6_144, maxContextLength: 262_144,
                  weightsBytes: 19_059_595_830, fixedRequestBytes: (base + depth - 1) * lightningGeneration),
        ]
    }

    static let lightningID = "nvidia-nemotron-3.5-lightning"

    /// An ordinary engine's floor at the SDK's default admission watermark;
    /// an engine with no fixed workspace reports the base minimum.
    static func minimumGrantBytes(fixedRequestBytes: Int) -> Int {
        guard fixedRequestBytes > 0 else { return Int(EngineV2KVSizing.minimumServiceableGrantBytes) }
        let watermark = AdmissionV2.Config().watermarkFraction
        let capacity = 16 << 30
        return EngineV2Bridge.minimumOrdinaryGrantBytes(
            fixedRequestBytes: fixedRequestBytes, capacityBytes: capacity,
            admissibleCapacityBytes: capacity - Int(Double(capacity) * watermark),
            watermarkFraction: watermark)
    }

    /// A real ordinary engine over a contiguous backend holding `grant`, with
    /// `fixedRequestBytes` of workspace per request at the SDK's default
    /// watermark: its bridge reports the production floor and serving width.
    static func makeBridge(modelId: String, fixedRequestBytes: Int, grant: Int,
                           kvBytesPerToken: Int = 0) -> EngineV2Bridge {
        let fixture = DeadlineAdmissionFixtureModel()
        let admission = AdmissionV2.Config(elementBytes: 4, fixedBytesPerRequest: fixedRequestBytes)
        let engine = EngineV2(model: fixture, layerKinds: fixture.kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: grant)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: fixture.kinds),
            schedulerConfig: .init(maxConcurrentRequests: 4, enablePrefixCache: false),
            admissionConfig: admission)
        return EngineV2Bridge(engine: engine, modelId: modelId,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [],
            kvBytesPerToken: kvBytesPerToken, fixedRequestBytes: engine.resolvedFixedBytesPerRequest,
            admissionWatermarkFraction: admission.watermarkFraction, kvBackendKind: .contiguous)
    }

    /// One recurrent generation of the dense 27B (`wide`) or the 35B-A3B
    /// Qwen text tower.
    private static func qwenGeneration(wide: Bool) throws -> Int {
        let fields: [String: Any] = [
            "hidden_size": wide ? 5120 : 2048,
            "num_hidden_layers": wide ? 64 : 40,
            "num_attention_heads": wide ? 24 : 16,
            "num_key_value_heads": wide ? 4 : 2,
            "head_dim": 256, "full_attention_interval": 4,
            "linear_num_key_heads": 16, "linear_key_head_dim": 128,
            "linear_num_value_heads": wide ? 48 : 32,
            "linear_value_head_dim": 128, "linear_conv_kernel_dim": 4,
            "max_position_embeddings": 262_144,
        ]
        let config = try JSONDecoder().decode(Qwen35TextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: fields))
        return try config.cbv2RecurrentStateSpec(activationDType: .bfloat16).fixedBytesPerRequest()
    }
}
