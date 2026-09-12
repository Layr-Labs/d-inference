import Foundation

extension StandaloneServer {
    func specDecPreparation(
        modelId: String, modelInfo: ModelInfo, modelDirectory: URL? = nil
    ) async -> SpecDecPreparation {
        // The shared funnel validates embedded Qwen heads and the external
        // Gemma assistant. Missing external artifacts download asynchronously;
        // the current target-only engine remains available until an idle swap.
        let inlineDeclaration = modelDirectory.map {
            SpecDecStore.inlineDeclarationProbe(directory: $0)
        } ?? .absent
        return await specDecFunnel.prepare(
            .init(
                modelId: modelId,
                modelType: modelInfo.modelType,
                enabled: config.mtpMode.enablesMTP(
                    forModelType: modelInfo.modelType,
                    embeddedArtifactDeclared: inlineDeclaration.mayDeclareEmbeddedArtifact,
                    modelID: modelId),
                localPath: config.mtpDrafterPath,
                modelDirectory: modelDirectory,
                inlineDeclaration: inlineDeclaration,
                // Catalog/download failure remains target-only. No request
                // waits for the optional assistant's network transfer.
                allowDownload: true,
                environment: ProcessInfo.processInfo.environment))
    }
}
