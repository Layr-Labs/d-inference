import Foundation

extension ProviderLoop {
    static let specDecCatalogPrewarmTimeout: Duration = .seconds(2)

    /// Warm the in-process target-to-assistant metadata map before any startup
    /// preload or unified-local request can construct a target slot. This does
    /// not download assistant bytes and is bounded/fail-open; every ordinary
    /// load remains a local-only catalog-cache/artifact-cache consultation.
    func prewarmSpecDecCatalog() async {
        let backend = loopConfig.config.backend
        guard backend.mtp,
            backend.mtpDrafterPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
            SpecDecArtifactFunnel.killSwitchEnabled(
                environment: ProcessInfo.processInfo.environment),
            let modelId = advertisedModels.values
                // Inline Qwen assistants need no catalog prewarm.
                .filter({ EngineV2SupportedModels.isGemma4Target(modelType: $0.modelType) })
                .map(\.id)
                .sorted()
                .first
        else { return }

        let warmed = await specDecFunnel.prewarmCatalog(
            modelId: modelId,
            timeout: Self.specDecCatalogPrewarmTimeout)
        if warmed {
            logger.info("mtp: catalog metadata prewarm complete")
        } else {
            logger.warning(
                "mtp: catalog metadata prewarm failed or exceeded deadline; "
                    + "startup continues target-only until a later full slot load")
        }
    }

    func specDecPreparation(
        modelId: String,
        modelInfo: ModelInfo,
        modelDirectory: URL? = nil,
        allowDownload: Bool = true
    ) async -> SpecDecPreparation {
        let prepared = await specDecFunnel.prepare(
            .init(
                modelId: modelId,
                modelType: modelInfo.modelType,
                enabled: loopConfig.config.backend.mtp,
                localPath: loopConfig.config.backend.mtpDrafterPath,
                modelDirectory: modelDirectory,
                allowDownload: allowDownload,
                environment: ProcessInfo.processInfo.environment))
        let reason = prepared.status.reason?.rawValue ?? "ready"
        logger.info(
            "mtp: model=\(modelId) configured=\(prepared.status.configured) "
                + "artifact_ready=\(prepared.artifact != nil) reason=\(reason) "
                + "revision=\(prepared.status.revision ?? "none") "
                + "artifact_bytes=\(prepared.status.artifactBytes)")
        return prepared
    }

    /// Assistant memory is optional: if it does not fit after target admission,
    /// preserve target loadability and record a stable target-only fallback.
    func admitSpecDecIfMemoryAllows(
        _ preparation: SpecDecPreparation,
        targetRequiredGb: Double
    ) async -> SpecDecPreparation {
        guard let artifact = preparation.artifact else { return preparation }
        guard Self.assistantMemoryFits(
            availableGb: await availableMemoryGb(),
            targetRequiredGb: targetRequiredGb,
            assistantBytes: artifact.residentBytes)
        else {
            logger.warning(
                "mtp: model assistant skipped reason=\(MTPFallbackReason.assistantMemoryUnavailable.rawValue) "
                    + "assistant_bytes=\(artifact.residentBytes)")
            return preparation.fallingBack(.assistantMemoryUnavailable)
        }
        return preparation
    }

    static func assistantMemoryFits(
        availableGb: Double,
        targetRequiredGb: Double,
        assistantBytes: UInt64
    ) -> Bool {
        guard availableGb.isFinite, targetRequiredGb.isFinite,
            availableGb >= 0, targetRequiredGb >= 0
        else { return false }
        let assistantGb = Double(assistantBytes) / 1_073_741_824.0
        let required = targetRequiredGb + assistantGb
        return required.isFinite && availableGb >= required
    }
}
