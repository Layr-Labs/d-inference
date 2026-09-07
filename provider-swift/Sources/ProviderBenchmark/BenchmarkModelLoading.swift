import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCore

enum BenchmarkModelLoading {
    static func load(directory: URL, isVLM: Bool) async throws -> ModelContainer {
        if isVLM {
            return try await VLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
        }
        return try await LLMModelFactory.shared.loadContainer(from: directory, using: LocalTokenizerLoader())
    }
}
