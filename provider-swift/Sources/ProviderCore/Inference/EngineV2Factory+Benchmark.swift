// Copyright © 2026 Eigen Labs.
//
// Benchmark-facing seam: perf harnesses must measure the exact module served
// in production. Gemma 4 VLM checkpoints expose their directly owned
// `Gemma4TextModel`; no extraction, re-keying, or second module is involved.

import MLXLMCommon

extension EngineV2Factory {

    /// Resolve the CBv2-serving model for a loaded checkpoint: the model
    /// itself for text checkpoints, or the exact VLM-owned text tower for
    /// Gemma 4 VLM checkpoints.
    public static func benchmarkServingModel(
        model: any LanguageModel,
        isVLM: Bool
    ) throws -> any LanguageModel {
        try directServingModel(model: model, isVLM: isVLM)
    }
}
