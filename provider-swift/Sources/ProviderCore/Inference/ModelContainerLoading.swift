// Copyright © 2026 Eigen Labs.
//
// Shared checkpoint → `ModelContainer` loading (v0.7.5 one-engine).
//
// Both slot owners (`ProviderLoop.ensureModelLoaded` and the standalone
// server's lazy load) pick the model factory the same way: a checkpoint
// whose config.json declares `vision_config` loads via `VLMModelFactory`
// (so image/video requests can run the container's prepare/generate
// vision path and the v2 engine is built over the weight-sharing text
// extraction); everything else loads via `LLMModelFactory`.

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

enum ModelContainerLoading {
    /// Load the checkpoint at `directory`, VLM-aware.
    static func loadContainer(from directory: URL) async throws -> MLXLMCommon.ModelContainer {
        if ProviderLoop.modelIsVLM(at: directory) {
            return try await VLMModelFactory.shared.loadContainer(
                from: directory,
                using: LocalTokenizerLoader()
            )
        }
        return try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalTokenizerLoader()
        )
    }
}
