import Foundation

extension StandaloneServer {
    func specDecPreparation(
        modelId: String, modelInfo: ModelInfo, modelDirectory: URL? = nil
    ) async -> SpecDecPreparation {
        await specDecFunnel.prepare(
            .init(
                modelId: modelId,
                modelType: modelInfo.modelType,
                enabled: config.mtpMode.enablesMTP(forModelType: modelInfo.modelType),
                localPath: config.mtpDrafterPath,
                modelDirectory: modelDirectory,
                // `darkbloom start --local` is coordinator-independent.
                // Automatic Qwen MTP uses only its already-downloaded inline
                // artifact; Gemma requires both explicit `.on` and a local path.
                allowDownload: false,
                environment: ProcessInfo.processInfo.environment))
    }
}
