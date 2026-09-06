// Copyright © 2026 Eigen Labs.
// Resolve serving modules and their model-owned CBv2 metadata/cache hooks.

import MLXLLM
import MLXLMCommon
import MLXVLM

extension EngineV2Factory {
    /// Keep the loaded module's identity: Gemma VLM serves its owned text tower;
    /// Qwen3-VL serves through its wrapper to retain vision and DeepStack state.
    static func directServingModel(
        model: any LanguageModel, isVLM: Bool
    ) throws -> any LanguageModel {
        guard isVLM else { return model }
        if model is MLXVLM.Qwen3VL { return model }
        guard let gemma4 = model as? MLXVLM.Gemma4 else {
            throw EngineV2ProductionError.unsupportedModel(
                String(describing: type(of: model)))
        }
        return gemma4.textModel
    }

    /// Metadata seam for model diagnostics; unsupported families return nil.
    static func cbv2LayerKinds(model: any LanguageModel) -> [CBv2LayerKind]? {
        ProductionModelAdapter(model: model)?.layerKinds
    }

    /// One family dispatch supplies both backend metadata and cache construction.
    /// Cache creation stays lazy; GPT-OSS primes its sinks probe only there,
    /// after weights have loaded, and Gemma retains its compatibility check.
    struct ProductionModelAdapter {
        let layerKinds: [CBv2LayerKind]
        let modelCapabilities: CBv2ModelCapabilities
        let newCaches:
            ((Int, CBv2LayerKind) -> any CBv2AttendingLayerCache)
                throws -> [any CBv2AttendingLayerCache]

        init?(model: any LanguageModel) {
            switch model {
            case let gemma as Gemma4TextModel:
                layerKinds = gemma.cbv2LayerKinds
                modelCapabilities = .attentionOnly
                newCaches = { make in try gemma.newCacheV2(makeLayerCache: make) }
            case let gptoss as GPTOSSModel:
                layerKinds = gptoss.cbv2LayerKinds
                modelCapabilities = .attentionOnly
                newCaches = { make in gptoss.newCacheV2(makeLayerCache: make) }
            case let qwen as Qwen35Model:
                layerKinds = qwen.cbv2LayerKinds
                modelCapabilities = qwen.cbv2Capabilities
                newCaches = { make in qwen.newCacheV2(makeLayerCache: make) }
            case let qwen as MLXVLM.Qwen3VL:
                layerKinds = qwen.cbv2LayerKinds
                modelCapabilities = qwen.cbv2Capabilities
                newCaches = { make in qwen.newCacheV2(makeLayerCache: make) }
            default:
                return nil
            }
        }
    }
}
