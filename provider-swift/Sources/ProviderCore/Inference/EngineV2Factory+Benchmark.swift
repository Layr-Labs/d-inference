// Copyright © 2026 Eigen Labs.
//
// Benchmark-facing seam: perf harnesses must measure the exact module served
// in production, and they need the module OBJECT (MTP binding, per-layer
// profiling) before any engine exists.
//
// It is the runner's answer, not a second opinion: adopting reads no tensors
// and each family returns the module it serves — a wrapper's own tower, the
// re-keyed and parity-gated target, or the loaded module unchanged.

import Foundation
import MLXLMCommon
import MLXRunners

extension EngineV2Factory {

    /// The module CBv2 will serve for this checkpoint.
    public static func benchmarkServingModel(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        modelDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any LanguageModel {
        try adoptRunner(
            model: model,
            tokenizer: tokenizer,
            modelDirectory: modelDirectory,
            options: runnerLoadOptions(
                modelDirectory: modelDirectory,
                kvBytesCapacity: 0,
                maxSequenceLength: RunnerLoadOptions().maxSequenceLength,
                environment: environment)
        ).servingModel
    }
}
