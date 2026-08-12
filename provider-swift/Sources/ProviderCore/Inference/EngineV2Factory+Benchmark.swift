// Copyright © 2026 Eigen Labs.
//
// Benchmark-facing seam: perf harnesses must measure the exact module served
// in production. Gemma 4 VLM checkpoints expose their directly owned
// `Gemma4TextModel`; no extraction, re-keying, or second module is involved.

import Foundation
import MLXLMCommon
import MLXVLM

extension EngineV2Factory {

    /// Resolve the CBv2-serving model for a loaded checkpoint: the model
    /// itself for text checkpoints, or the exact VLM-owned text tower for
    /// Gemma 4 VLM checkpoints.
    public static func benchmarkServingModel(
        model: any LanguageModel,
        isVLM: Bool,
        modelDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any LanguageModel {
        guard isVLM else { return model }
        if model is MLXVLM.Gemma4 {
            return try directServingModel(model: model, isVLM: true)
        }
        guard model is MLXVLM.Qwen35MoE else {
            throw EngineV2VLMTextExtractionError.unsupportedWrapper(
                String(describing: type(of: model)))
        }
        guard let modelDirectory else {
            throw EngineV2VLMTextExtractionError.missingModelDirectory
        }
        return try EngineV2VLMTextExtraction.extractTextModel(
            from: model, modelDirectory: modelDirectory, environment: environment
        ).servingModel
    }
}
