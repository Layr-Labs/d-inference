import Foundation
import MLX

@testable import MLXLLM
@testable import MLXLMCommon
@testable import ProviderCore

/// Configuration-only fixtures for the five exact artifacts in the 0.9 gate.
/// Geometry/dtypes: 2026-09-05-five-model-native-kv-probes.md. Qwen config
/// hashes: b852ada3… (3.6), 58a2b700… (3.5), 4691da94… (3.8).
/// No weights, forward pass, tensor evaluation or physical capacity measurement.
struct SegmentedFleetGeometry {
    let id: String
    let kinds: [CBv2LayerKind]
    let dtypes: [DType]
    let context: Int
    let qwen: Qwen35TextConfiguration?

    static func all() throws -> [Self] {
        func qwen(_ id: String, wide: Bool) throws -> Self {
            let fields: [String: Any] = [
                "hidden_size": wide ? 5120 : 2048,
                "num_hidden_layers": wide ? 64 : 40,
                "num_attention_heads": wide ? 24 : 16,
                "num_key_value_heads": wide ? 4 : 2,
                "head_dim": 256, "full_attention_interval": 4,
                "linear_num_key_heads": 16, "linear_key_head_dim": 128,
                "linear_num_value_heads": wide ? 48 : 32,
                "linear_value_head_dim": 128, "linear_conv_kernel_dim": 4,
                "max_position_embeddings": 262_144, "mtp_num_hidden_layers": 1,
            ]
            let config = try JSONDecoder().decode(Qwen35TextConfiguration.self,
                from: JSONSerialization.data(withJSONObject: fields))
            let kinds = config.cbv2LayerKinds
            return Self(id: id, kinds: kinds, dtypes: Array(repeating: .bfloat16, count: kinds.count),
                        context: 262_144, qwen: config)
        }
        return [
            try qwen("qwen3.6-35b-a3b-vl-mtp-mxfp8", wide: false),
            try qwen("qwen3.5-35b-a3b", wide: false),
            try qwen("EigenLabs/Qwen3.8-27B-4bit-mtp", wide: true),
            Self(id: "gpt-oss-20b", kinds: CBv2LayerKindDerivation.gptossLayerKinds(
                layerTypes: nil, numHiddenLayers: 24, slidingWindow: 128,
                headDim: 64, numAttentionHeads: 64, numKeyValueHeads: 8),
                 // Actual probe: the first sliding layer is BF16; all later
                 // layers, including sliding layers, are FP32.
                 dtypes: [.bfloat16] + Array(repeating: .float32, count: 23),
                 context: 131_072, qwen: nil),
            Self(id: "gemma-4-26b", kinds: CBv2LayerKindDerivation.gemma4LayerKinds(
                layerTypes: CBv2LayerKindDerivation.layerTypes(slidingWindowPattern: 6, numLayers: 30),
                slidingWindow: 1024, numKvSharedLayers: 0, headDim: 256,
                globalHeadDim: 512, numAttentionHeads: 16, numKeyValueHeads: 8,
                numGlobalKeyValueHeads: 2),
                 dtypes: Array(repeating: .bfloat16, count: 30), context: 262_144, qwen: nil),
        ]
    }

    var resliceSlot: EngineV2KVSizing.ResliceSlot {
        // Production SlotSizing uses the fp16 owning-full marginal rate for
        // fairness. Native Admission separately prices actual types and rings.
        let rate = kinds.reduce(0) { total, kind in
            guard kind.sharesKVWithLayer == nil, case .full = kind.attention else { return total }
            return total + 2 * kind.kvHeads * kind.headDim * 2
        }
        return .init(modelId: id, fp16KVBytesPerToken: rate, maxContextLength: context)
    }

    func admissionConfig(policy: AllocationFootprintPolicy) throws -> AdmissionV2.Config {
        var config = AdmissionV2.Config(watermarkFraction: 0, layerElementBytes: dtypes.map(\.size))
        if let qwen {
            // EngineV2 normal compact rectangular replay: three base recurrent
            // generations plus one strict-prefix continuation at depth >= 2.
            let recurrent = qwen.cbv2RecurrentStateSpec(activationDType: .bfloat16)
            config.fixedBytesPerRequest = try recurrent.allocationBytesPerGeneration(policy: policy) * 4
            config.auxiliaryBytesPerToken = Qwen35InlineMTPAssistant.stateBytesPerToken(
                configuration: qwen, layerCount: 1, cacheElementBytes: 2, hiddenElementBytes: 2)
            config.auxiliaryTokenGranularity = 256
            config.auxiliaryTokenAllocationPadding = 4
            let specs = [
                CBv2AuxiliaryAllocationSpec(bytesPerToken: qwen.kvHeads * 256 * 2,
                    allocationCount: 2, tokenGranularity: 256, tokenPadding: 4),
                CBv2AuxiliaryAllocationSpec(bytesPerToken: qwen.hiddenSize * 2,
                    tokenPadding: 4, partitioned: true),
                CBv2AuxiliaryAllocationSpec(bytesPerToken: 4, tokenPadding: 4, partitioned: true),
            ]
            guard let projection = CBv2AuxiliaryAllocationProjection(policy: policy, buffers: specs)
            else { throw FixtureError.allocatorProjection }
            config.auxiliaryAllocationProjection = projection
        }
        // GPT has no MTP. Gemma's configured drafter rebuilds per round from
        // borrowed target KV: it declares zero persistent request state, not
        // disabled MTP. Its per-round execution remains in the activation gate.
        return config
    }

    /// Production's default solo stripes also bound native window rings.
    /// Dense Qwen uses 4096; the other exact artifacts use 2048.
    var maximumPrefillChunk: Int {
        id == "EigenLabs/Qwen3.8-27B-4bit-mtp"
            ? EngineV2Factory.defaultDenseQwenSoloPrefillStripeTokens
            : EngineV2Factory.defaultSoloPrefillStripeTokens
    }

    func poolConfig(grant: Int) -> PagedKVPoolConfig {
        .init(capacityBytes: grant, dtype: dtypes[0], maxPrefillChunk: maximumPrefillChunk,
              nominalMaxSequenceLength: context, maxBufferLength: 256 << 20,
              segmentSizeBytes: 64 << 20, layerDTypes: dtypes)
    }

    enum FixtureError: Error { case allocatorProjection }
}
