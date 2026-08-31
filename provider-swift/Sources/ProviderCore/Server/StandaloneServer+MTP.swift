import Foundation

extension StandaloneServer {
    func specDecPreparation(
        modelId: String, modelInfo: ModelInfo, modelDirectory: URL? = nil
    ) async -> SpecDecPreparation {
        // One mechanism: the funnel. Qwen 3.5-family checkpoints embed their
        // MTP head inline (`mtplx_mtp` in config.json), so the standalone
        // server resolves exactly what the artifact on disk declares — no
        // model-id pins, no separately published heads, no staged copies.
        // The previous `StandaloneQwen38MTPResolver` (external
        // `EigenLabs/Qwen3.8-27B-MTP-4bit` head pinned by revision) was
        // removed when the 27B moved to the embedded artifact.
        let embeddedDeclared = modelDirectory.map {
            SpecDecStore.inlineDeclarationProbe(directory: $0)
                .mayDeclareEmbeddedArtifact
        } ?? false
        return await specDecFunnel.prepare(
            .init(
                modelId: modelId,
                modelType: modelInfo.modelType,
                enabled: config.mtpMode.enablesMTP(
                    forModelType: modelInfo.modelType,
                    embeddedArtifactDeclared: embeddedDeclared),
                localPath: config.mtpDrafterPath,
                modelDirectory: modelDirectory,
                // `darkbloom start --local` is coordinator-independent and
                // never auto-downloads an assistant.
                allowDownload: false,
                environment: ProcessInfo.processInfo.environment))
    }
}
