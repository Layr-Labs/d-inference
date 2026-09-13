import Foundation

extension ProviderLoop {
    static let specDecCatalogPrewarmTimeout: Duration = .seconds(2)

    /// Warm the in-process target-to-assistant metadata map before any startup
    /// preload or unified-local request can construct a target slot. This does
    /// not download assistant bytes and is bounded/fail-open; every ordinary
    /// load remains a local-only catalog-cache/artifact-cache consultation.
    ///
    /// `auto` prewarms only for the exact Gemma QAT target; explicit `on`
    /// also permits other supported external assistants. Embedded Qwen heads
    /// resolve from the checkpoint itself without catalog metadata.
    func prewarmSpecDecCatalog() async {
        let backend = loopConfig.config.backend
        guard backend.mtpDrafterPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
            SpecDecArtifactFunnel.killSwitchEnabled(
                environment: ProcessInfo.processInfo.environment),
            let modelId = advertisedModels.values
                .filter({
                    backend.mtpMode.requiresCatalogPrewarm(
                        forModelType: $0.modelType, modelID: $0.id)
                })
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
                    + "startup continues target-only while a verified assistant prepares for idle activation")
        }
    }

    func specDecPreparation(
        modelId: String,
        modelInfo: ModelInfo,
        modelDirectory: URL? = nil,
        allowDownload: Bool = true,
        logStatus: Bool = true
    ) async -> SpecDecPreparation {
        let inlineDeclaration = modelDirectory.map {
            SpecDecStore.inlineDeclarationProbe(directory: $0)
        } ?? .absent
        let prepared = await specDecFunnel.prepare(
            .init(
                modelId: modelId,
                modelType: modelInfo.modelType,
                enabled: loopConfig.config.backend.mtpMode.enablesMTP(
                    forModelType: modelInfo.modelType,
                    embeddedArtifactDeclared: inlineDeclaration.mayDeclareEmbeddedArtifact,
                    modelID: modelId),
                localPath: loopConfig.config.backend.mtpDrafterPath,
                modelDirectory: modelDirectory,
                inlineDeclaration: inlineDeclaration,
                allowDownload: allowDownload,
                environment: ProcessInfo.processInfo.environment))
        if logStatus {
            let reason = prepared.status.reason?.rawValue ?? "ready"
            logger.info(
                "mtp: model=\(modelId) configured=\(prepared.status.configured) "
                    + "artifact_ready=\(prepared.artifact != nil) reason=\(reason) "
                    + "revision=\(prepared.status.revision ?? "none") "
                    + "source_revision=\(prepared.status.sourceRevision ?? "none") "
                    + "artifact_bytes=\(prepared.status.artifactBytes)")
        }
        return prepared
    }

    /// Assistant memory is optional: if it does not fit after target admission,
    /// preserve target loadability and record a stable target-only fallback.
    /// Takes the target's WEIGHT basis, not a precomputed requirement: the
    /// memory sample below is an actor suspension, and a concurrent verified
    /// prefetch can raise the serving-set floor across it — the target
    /// requirement is resolved after the sample so the assistant is admitted
    /// against the load gate as it stands, not as it stood before the hop.
    func admitSpecDecIfMemoryAllows(
        _ preparation: SpecDecPreparation,
        targetWeightsGb: Double
    ) async -> SpecDecPreparation {
        guard let artifact = preparation.artifact else { return preparation }
        // Inline assistants ride the target checkpoint's own shards, already
        // counted by the scanner in targetWeightsGb — no additional charge
        // (SpecDecArtifact.additionalWeightBytes).
        guard artifact.additionalWeightBytes > 0 else { return preparation }
        let availableGb = await availableMemoryGb()
        guard Self.assistantMemoryFits(
            availableGb: availableGb,
            targetRequiredGb: ModelLoadAdmission.requiredToLoadGb(
                weightsGb: targetWeightsGb, headroomGb: loadHeadroomGb),
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
