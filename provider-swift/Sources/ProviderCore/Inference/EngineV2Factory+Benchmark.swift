// Copyright © 2026 Eigen Labs.
//
// Benchmark-facing seam: perf harnesses must measure the exact module served
// in production. Gemma 4 VLM checkpoints expose their directly owned
// `Gemma4TextModel`; Qwen3-VL is served directly as its loaded wrapper.

import Foundation
import MLXLMCommon
import MLXVLM

extension EngineV2Factory {

    /// Resolve the exact module instance CBv2 serves for a VLM wrapper —
    /// the same answer `Runner.adopt` reaches on the serving path, kept here
    /// for the harnesses that need the tower object itself (MTP binding,
    /// per-layer profiling) before any engine exists. The serving path does
    /// not call this: it hands the loaded module to the runner and lets the
    /// family answer.
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

    /// Resolve the CBv2-serving model for a loaded checkpoint: the model
    /// itself for text and direct Qwen3-VL checkpoints, the exact VLM-owned
    /// text tower for Gemma 4, or the extracted Qwen3.5 dense/MoE language target.
    public static func benchmarkServingModel(
        model: any LanguageModel,
        isVLM: Bool,
        modelDirectory: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any LanguageModel {
        guard isVLM else { return model }
        if model is MLXVLM.Gemma4 {
            return try directServingModel(model: model, isVLM: true)
        }
        if model is MLXVLM.Qwen3VL {
            return try directServingModel(model: model, isVLM: true)
        }
        guard model is MLXVLM.Qwen35 else {
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
