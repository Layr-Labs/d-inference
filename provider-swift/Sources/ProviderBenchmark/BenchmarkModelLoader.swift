import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCore

/// Load local benchmark weights with the same factories and tokenizer as serving.
/// Callers retain their own declaration/provenance checks and serving-model resolution.
enum BenchmarkModelLoader {
    static func load(directory: URL, isVLM: Bool) async throws -> ModelContainer {
        if isVLM {
            return try await VLMModelFactory.shared.loadContainer(
                from: directory, using: LocalTokenizerLoader())
        }
        return try await LLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
    }
}
