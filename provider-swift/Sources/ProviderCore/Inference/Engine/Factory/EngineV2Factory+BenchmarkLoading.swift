import Foundation
import MLXLMCommon

extension EngineV2Factory {
    /// The ordinary benchmark must use the same model-ID-qualified text/vision
    /// factory and external-resource lifetime as a production slot.
    @_spi(Benchmarking)
    public static func loadBenchmarkContainer(
        modelID: String, directory: URL
    ) async throws -> (container: ModelContainer, isVLM: Bool) {
        let selection = ModelContainerLoading.factorySelection(at: directory, modelID: modelID)
        let container = try await ModelContainerLoading.loadContainer(from: directory, modelID: modelID)
        return (container, selection == .vision)
    }

    /// Call only after the benchmark session has drained and shut down.
    @_spi(Benchmarking)
    public static func releaseBenchmarkContainer(_ container: ModelContainer) async {
        await ModelContainerLoading.releaseExternalResources(in: container)
    }
}
