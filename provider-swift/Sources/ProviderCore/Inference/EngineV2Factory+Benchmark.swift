// Copyright © 2026 Eigen Labs.
//
// Benchmark-facing seam: the perf-gate harness (`ProviderBenchmark`'s
// ThroughputSweep / SchedulerPrefillBenchmark) must measure the SERVING
// model — for Gemma 4 VLM checkpoints that is the weight-sharing
// CBv2-adapted text model produced by `EngineV2VLMTextExtraction`, exactly
// as `EngineV2SlotFactory.makeProductionBridge` builds it. Without this the
// sweep would hand the raw VLM wrapper to `makeProductionEngine` and refuse
// (`unsupportedModel`), measuring nothing.

import Foundation
import MLXLMCommon

extension EngineV2Factory {

    /// Resolve the CBv2-serving model for a loaded checkpoint: the model
    /// itself for text checkpoints, the weight-sharing extracted text model
    /// for VLM checkpoints (zero extra weight memory; load-time parity gate
    /// included — throws on any extraction/verify failure).
    public static func benchmarkServingModel(
        model: any LanguageModel,
        isVLM: Bool,
        modelDirectory: URL?
    ) throws -> any LanguageModel {
        guard isVLM else { return model }
        guard let modelDirectory else {
            throw EngineV2VLMTextExtractionError.missingModelDirectory
        }
        return try EngineV2VLMTextExtraction.extractTextModel(
            from: model, modelDirectory: modelDirectory
        ).model
    }
}
