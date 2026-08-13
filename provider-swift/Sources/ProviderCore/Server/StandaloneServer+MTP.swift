import Foundation

extension StandaloneServer {
    func specDecPreparation(
        modelId: String, modelInfo: ModelInfo, modelDirectory: URL? = nil
    ) async -> SpecDecPreparation {
        await specDecFunnel.prepare(
            .init(
                modelId: modelId,
                modelType: modelInfo.modelType,
                enabled: config.mtp,
                localPath: config.mtpDrafterPath,
                modelDirectory: modelDirectory,
                // `darkbloom start --local` is coordinator-independent. Only an
                // explicit operator-provided path may activate MTP here.
                allowDownload: false,
                environment: ProcessInfo.processInfo.environment))
    }
}
