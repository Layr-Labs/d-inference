import MLXLMCommon

/// Model handle + EOS config snapshot pulled out of `ModelContainer.perform`.
/// The module crosses container isolation once and is then engine-thread owned.
struct EngineV2ModelSnapshot: @unchecked Sendable {
    let model: any LanguageModel
    let eosTokenIds: Set<Int>
    let extraEOSTokens: [String]
}

/// Direct serving-target resolution plus fail-open assistant preparation,
/// completed before KV re-slicing so sizing uses retained assistant bytes.
struct EngineV2PreparedModel: @unchecked Sendable {
    let snapshot: EngineV2ModelSnapshot
    let servingModel: any LanguageModel
    let assistant: ProviderMTPAssistantHandle?
    let mtpStatus: MTPActivationStatus
    let mtpArtifact: SpecDecArtifact?

    var assistantBytes: UInt64 { mtpStatus.assistantBytes }

    func fallingBack(_ reason: MTPFallbackReason) -> Self {
        Self(
            snapshot: snapshot,
            servingModel: servingModel,
            assistant: nil,
            mtpStatus: mtpStatus.fallingBack(reason),
            mtpArtifact: nil)
    }
}

extension EngineV2SlotFactory {
    private static func modelSnapshot(
        container: ModelContainer
    ) async -> EngineV2ModelSnapshot {
        await container.perform { ctx in
            EngineV2ModelSnapshot(
                model: ctx.model,
                eosTokenIds: ctx.configuration.eosTokenIds,
                extraEOSTokens: ctx.configuration.extraEOSTokens.sorted())
        }
    }

    private static func servingModel(
        modelId: String,
        isVLM: Bool,
        snapshot: EngineV2ModelSnapshot,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?,
        logInfo: @escaping @Sendable (String) -> Void
    ) throws -> any LanguageModel {
        guard isVLM else { return snapshot.model }
        do {
            let target = try EngineV2Factory.directServingModel(
                model: snapshot.model, isVLM: true)
            logInfo(
                "engine_v2: \(modelId) using the Gemma 4 VLM-owned text tower "
                    + "directly (shared identity and residency)")
            return target
        } catch {
            EngineV2Factory.emitRefusalTelemetry(
                modelId: modelId,
                reason: EngineV2RefusalReason.classify(error),
                error: error,
                emitTelemetry: emitTelemetry)
            throw error
        }
    }

    static func prepareProductionModel(
        modelId: String,
        isVLM: Bool,
        container: ModelContainer,
        specDecPreparation: SpecDecPreparation,
        assistantLoader: any ProviderMTPAssistantLoading = Gemma4ProviderMTPAssistantLoader(),
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> EngineV2PreparedModel {
        let snapshot = await modelSnapshot(container: container)
        let servingModel = try servingModel(
            modelId: modelId,
            isVLM: isVLM,
            snapshot: snapshot,
            emitTelemetry: emitTelemetry,
            logInfo: logInfo)

        var assistant: ProviderMTPAssistantHandle?
        var mtpStatus = specDecPreparation.status
        var retainedArtifact: SpecDecArtifact?
        if let candidate = specDecPreparation.artifact {
            let artifact: SpecDecArtifact
            let revalidation = SpecDecStore.revalidateForLoad(candidate)
            if let verified = revalidation.artifact {
                artifact = verified
                mtpStatus = .candidate(verified)
            } else {
                let reason = revalidation.reason ?? .warmArtifactCorrupt
                mtpStatus = mtpStatus.fallingBack(reason)
                logWarning(
                    "mtp: model=\(modelId) fallback reason=\(reason.rawValue) detail="
                        + (revalidation.detail ?? "artifact revalidation failed"))
                return EngineV2PreparedModel(
                    snapshot: snapshot,
                    servingModel: servingModel,
                    assistant: nil,
                    mtpStatus: mtpStatus,
                    mtpArtifact: nil)
            }
            do {
                assistant = try await assistantLoader.loadAndBind(
                    artifact: artifact, target: servingModel)
                assistant?.bind(
                    sourceTarget: snapshot.model, servingTarget: servingModel)
                mtpStatus = mtpStatus.activated(assistantBytes: artifact.residentBytes)
                retainedArtifact = artifact
            } catch let error as ProviderMTPAssistantLoadError {
                mtpStatus = mtpStatus.fallingBack(error.reason)
                logWarning(
                    "mtp: model=\(modelId) fallback reason=\(error.reason.rawValue) detail=\(error)")
            } catch {
                mtpStatus = mtpStatus.fallingBack(.assistantLoadFailed)
                logWarning(
                    "mtp: model=\(modelId) fallback reason=\(MTPFallbackReason.assistantLoadFailed.rawValue) detail=\(error)")
            }
        }
        return EngineV2PreparedModel(
            snapshot: snapshot,
            servingModel: servingModel,
            assistant: assistant,
            mtpStatus: mtpStatus,
            mtpArtifact: retainedArtifact)
    }

    /// Recovery may reuse already-accounted assistant residency, but it must
    /// never call an assistant loader. Invalid or structurally stale ownership
    /// falls back to a fresh target-only engine over the retained container.
    static func prepareRecoveryModel(
        modelId: String,
        isVLM: Bool,
        container: ModelContainer,
        previousArtifact: SpecDecArtifact?,
        previousStatus: MTPActivationStatus,
        assistant: ProviderMTPAssistantHandle?,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> EngineV2PreparedModel {
        let snapshot = await modelSnapshot(container: container)

        if previousStatus.active,
            let previousArtifact,
            let assistant,
            previousStatus.source == previousArtifact.source,
            previousStatus.revision == previousArtifact.revision,
            previousStatus.artifactBytes == previousArtifact.artifactBytes,
            previousStatus.assistantBytes == previousArtifact.residentBytes
        {
            let revalidation = SpecDecStore.revalidateForLoad(previousArtifact)
            if let artifact = revalidation.artifact,
                let reusedTarget = assistant.recoveryServingTarget(
                    for: snapshot.model)
            {
                return EngineV2PreparedModel(
                    snapshot: snapshot,
                    servingModel: reusedTarget,
                    assistant: assistant,
                    mtpStatus: MTPActivationStatus.candidate(artifact).activated(
                        assistantBytes: artifact.residentBytes),
                    mtpArtifact: artifact)
            }
            let reason = revalidation.reason ?? .assistantTargetIncompatible
            logWarning(
                "mtp: model=\(modelId) recovery fallback reason=\(reason.rawValue) detail="
                    + (revalidation.detail ?? "installed assistant binding is not reusable"))
            let target = try servingModel(
                modelId: modelId,
                isVLM: isVLM,
                snapshot: snapshot,
                emitTelemetry: emitTelemetry,
                logInfo: logInfo)
            return EngineV2PreparedModel(
                snapshot: snapshot,
                servingModel: target,
                assistant: nil,
                mtpStatus: previousStatus.fallingBack(reason),
                mtpArtifact: nil)
        }

        let reason: MTPFallbackReason? = previousStatus.active ? .engineInactive : nil
        let target = try servingModel(
            modelId: modelId,
            isVLM: isVLM,
            snapshot: snapshot,
            emitTelemetry: emitTelemetry,
            logInfo: logInfo)
        return EngineV2PreparedModel(
            snapshot: snapshot,
            servingModel: target,
            assistant: nil,
            mtpStatus: reason.map(previousStatus.fallingBack) ?? previousStatus,
            mtpArtifact: nil)
    }
}
