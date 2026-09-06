import Foundation

extension EngineV2Factory {
    /// The same offline funnel used by standalone serving. A local override
    /// must contain exact flat config/weights and passes ordinary digest and
    /// target-compatibility checks; it cannot silently activate another head.
    static func benchmarkAssistantPreparation(
        modelId: String, modelType: String?, modelDirectory: URL,
        enabled: Bool, assistantDirectory: URL?, environment: [String: String]
    ) async throws -> SpecDecPreparation {
        let funnel = SpecDecArtifactFunnel(resolver: SpecDecResolver(), catalog: nil)
        let declaration = SpecDecStore.inlineDeclarationProbe(directory: modelDirectory)
        let prepared = await funnel.prepare(.init(
            modelId: modelId, modelType: modelType, enabled: enabled,
            localPath: assistantDirectory?.path, modelDirectory: modelDirectory,
            inlineDeclaration: declaration, allowDownload: false, environment: environment))
        await funnel.shutdown()
        guard !enabled || prepared.artifact != nil else {
            throw EngineV2BenchmarkSession.Failure.mtpUnavailable
        }
        return prepared
    }

    static func benchmarkAssistantIdentity(_ artifact: SpecDecArtifact?) -> [String: String] {
        guard let artifact else { return ["source": "none"] }
        var identity = ["source": artifact.source.rawValue, "revision": artifact.revision]
        identity["source_revision"] = artifact.sourceRevision
        identity["manifest_sha256"] = artifact.manifestSHA256
        identity["config_sha256"] = artifact.localConfigSHA256
        identity["inline_index_sha256"] = artifact.inlineIndexSHA256
        for (name, digest) in artifact.localWeightSHA256 ?? [:] {
            identity["weight_sha256." + name] = digest
        }
        return identity
    }
}
