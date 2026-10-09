import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Testing

@testable import ProviderCore

@Suite("Diffusion serving page bound for whole media")
struct EngineV2DiffusionMediaChunkBoundTests {
    private func configuration(canvas: Int = 256, vision: Bool = true) throws
        -> DiffusionGemmaConfiguration
    {
        let text: [String: Any] = [
            "vocab_size": 128, "hidden_size": 32, "intermediate_size": 48,
            "moe_intermediate_size": 16, "num_hidden_layers": 2,
            "num_attention_heads": 4, "num_key_value_heads": 2,
            "head_dim": 64, "global_head_dim": 64, "sliding_window": 256,
            "max_position_embeddings": 4096, "num_experts": 4, "top_k_experts": 2,
            "layer_types": ["sliding_attention", "full_attention"],
        ]
        var root: [String: Any] = [
            "model_type": "diffusion_gemma", "text_config": text,
            "canvas_length": canvas, "tie_word_embeddings": true,
            "image_token_id": 100, "boi_token_id": 102, "eoi_token_id": 103,
        ]
        if vision {
            root["vision_config"] = [
                "hidden_size": 32, "intermediate_size": 48, "num_hidden_layers": 1,
                "num_attention_heads": 2, "num_key_value_heads": 1,
                "head_dim": 72, "default_output_length": 4, "patch_size": 2,
                "position_embedding_size": 32, "pooling_kernel_size": 3,
            ]
        }
        return try JSONDecoder().decode(
            DiffusionGemmaConfiguration.self,
            from: JSONSerialization.data(withJSONObject: root))
    }

    @Test(arguments: EngineV2KVQuantizationSelection.allCases)
    func servingPoolQuotesEveryAcceptedVisualChunk(selection: EngineV2KVQuantizationSelection)
        throws
    {
        let config = try configuration()
        let actual = DiffusionGemmaProviderBridge.makePagedConfiguration(
            configuration: config, kvBytesCapacity: 128 << 20, dtype: .bfloat16,
            prefillChunkSize: 512, kvQuantization: selection)
        let maximum = DiffusionGemmaPrefillGeometry.maximumVisualBlockTokens
        let geometry = try DiffusionGemmaPrefillGeometry(
            promptCount: maximum + 5, chunkSize: 512,
            spans: [.init(tokenOffset: 2, length: maximum)])
        for start in [0] + Array(geometry.boundaries.dropLast()) {
            #expect(try geometry.chunkLength(start: start) <= actual.maxPrefillChunk)
        }
        #expect(actual.maxPrefillChunk == maximum)
        #expect(actual.capacityBytes == 128 << 20 && actual.segmentSizeBytes == 8 << 20)
        #expect(actual.dtype == .bfloat16 && actual.layerDTypes == [.bfloat16, .bfloat16])
        #expect(actual.nominalMaxSequenceLength == config.textConfig.maxPositionEmbeddings)
        #expect(actual.quantization == selection.configuration)
    }

    @Test func operatorChunkAndCanvasBoundsRemainHigherWhenRequired() throws {
        let config = try configuration(canvas: 2048)
        let actual = DiffusionGemmaProviderBridge.makePagedConfiguration(
            configuration: config, kvBytesCapacity: 128 << 20, dtype: .float32,
            prefillChunkSize: 1536, kvQuantization: .balanced)
        #expect(actual.maxPrefillChunk == 2048)
    }

    @Test func textOnlyConfigurationKeepsItsExistingChunkBound() throws {
        let actual = DiffusionGemmaProviderBridge.makePagedConfiguration(
            configuration: try configuration(vision: false), kvBytesCapacity: 128 << 20,
            dtype: .float32, prefillChunkSize: 512, kvQuantization: .balanced)
        #expect(actual.maxPrefillChunk == 512)
    }
}
