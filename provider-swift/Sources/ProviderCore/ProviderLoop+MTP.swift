import Foundation

extension ProviderLoop {
    func specDecPreparation(
        modelId: String,
        modelInfo: ModelInfo,
        allowDownload: Bool = true
    ) async -> SpecDecPreparation {
        let started = ContinuousClock.now
        let prepared = await specDecFunnel.prepareForLoad(
            .init(
                modelId: modelId,
                modelType: modelInfo.modelType,
                enabled: loopConfig.config.backend.mtp,
                localPath: loopConfig.config.backend.mtpDrafterPath,
                allowDownload: allowDownload,
                environment: ProcessInfo.processInfo.environment))
        let elapsed = ContinuousClock.now - started
        let durationMs = Int64(max(
            0,
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15))
        let reason = prepared.status.reason?.rawValue ?? "ready"
        let policy = loopConfig.config.backend.mtp
            ? "default_or_config_on"
            : "config_off"
        logger.info(
            "mtp: model=\(modelId) policy=\(policy) "
                + "artifact_ready=\(prepared.artifact != nil) reason=\(reason) "
                + "revision=\(prepared.status.revision ?? "none") "
                + "artifact_bytes=\(prepared.status.artifactBytes) "
                + "download_verify_ms=\(durationMs)")
        return prepared
    }

}
