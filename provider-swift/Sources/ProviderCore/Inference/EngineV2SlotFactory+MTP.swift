import Foundation
import MLXLMCommon
import MLXRunners

/// Model handle + EOS config snapshot pulled out of `ModelContainer.perform`.
/// The module crosses container isolation once and is then engine-thread owned.
struct EngineV2ModelSnapshot: @unchecked Sendable {
    let model: any LanguageModel
    let eosTokenIds: Set<Int>
    let extraEOSTokens: [String]
}

/// The adopted runner plus fail-open assistant preparation, completed before
/// KV re-slicing so sizing uses retained assistant bytes.
///
/// `runner` is nil only on the scripted-engine test seam, which builds no
/// real engine and therefore adopts nothing; every production path has one.
struct EngineV2PreparedModel: @unchecked Sendable {
    let snapshot: EngineV2ModelSnapshot
    let runner: (any Runner)?
    /// The module the engine serves — the runner's own answer where there is
    /// a runner, the loaded module otherwise. Read by sizing and telemetry.
    let servingModel: any LanguageModel
    let assistant: ProviderMTPAssistantHandle?
    let mtpStatus: MTPActivationStatus
    let mtpArtifact: SpecDecArtifact?

    var assistantBytes: UInt64 { mtpStatus.assistantBytes }

    func fallingBack(_ reason: MTPFallbackReason) -> Self {
        Self(
            snapshot: snapshot,
            runner: runner,
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

    /// Adopt the resident module through the registry, twice.
    ///
    /// The first adoption answers ONE question the provider cannot answer
    /// itself: which module this family serves (a VLM wrapper's own tower,
    /// or the wrapper). The drafter then binds to exactly that instance, and
    /// the second adoption carries it in as `preloadedDrafter`. Both
    /// adoptions read no tensors — two `config.json` reads — so the pair
    /// costs nothing next to binding a drafter to the wrong object.
    ///
    /// The multimodal retry inside `adoptRunner` is the extraction path for
    /// a wrapper the family does not serve
    /// (`EngineV2VLMTextExtraction`, which re-keys and parity-gates the
    /// tower it builds).
    private static func adopt(
        modelId: String,
        isVLM: Bool,
        modelDirectory: URL,
        snapshot: EngineV2ModelSnapshot,
        tokenizer: any MLXLMCommon.Tokenizer,
        drafter: (any CBv2MTPDrafter)? = nil,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)?,
        logInfo: @escaping @Sendable (String) -> Void
    ) throws -> any Runner {
        do {
            return try EngineV2Factory.adoptRunner(
                model: snapshot.model,
                tokenizer: tokenizer,
                modelDirectory: modelDirectory,
                options: EngineV2Factory.runnerLoadOptions(
                    modelDirectory: modelDirectory,
                    kvBytesCapacity: 0,
                    maxSequenceLength: RunnerLoadOptions().maxSequenceLength,
                    preloadedDrafter: drafter),
                textTowerCandidates: isVLM
                    ? [
                        // The tower a wrapper OWNS, when it owns one: the
                        // wrapper and the engine then share one parameter
                        // tree and one residency footprint.
                        { try EngineV2Factory.directServingModel(
                            model: snapshot.model, isVLM: true) },
                        // Otherwise the tower this provider BUILDS from the
                        // checkpoint, re-keyed and parity-gated at load.
                        {
                            let extraction = try EngineV2VLMTextExtraction.extractTextModel(
                                from: snapshot.model, modelDirectory: modelDirectory)
                            if let parityDiff = extraction.parityMaxAbsLogitDiff {
                                logInfo(
                                    "engine_v2: \(modelId) VLM text extraction passed the "
                                        + "load-time parity gate (max |Δlogit| \(parityDiff))")
                            }
                            return extraction.servingModel
                        },
                    ] : [])
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
        modelDirectory: URL? = nil,
        container: ModelContainer,
        specDecPreparation: SpecDecPreparation,
        assistantLoader: any ProviderMTPAssistantLoading = ProductionProviderMTPAssistantLoader(),
        tokenizer: (any MLXLMCommon.Tokenizer)? = nil,
        adoptRunner: Bool = true,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> EngineV2PreparedModel {
        let snapshot = await modelSnapshot(container: container)
        var resolvedTokenizer = tokenizer
        if resolvedTokenizer == nil {
            resolvedTokenizer = await container.perform { ctx in ctx.tokenizer }
        }
        let slotTokenizer = resolvedTokenizer!

        // First adoption: which module does this family serve? The scripted
        // -engine seam builds no real engine, so it adopts nothing and
        // serves the loaded module as it stands.
        let targetRunner: (any Runner)?
        if adoptRunner, let modelDirectory {
            targetRunner = try adopt(
                modelId: modelId,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                snapshot: snapshot,
                tokenizer: slotTokenizer,
                emitTelemetry: emitTelemetry,
                logInfo: logInfo)
        } else {
            targetRunner = nil
        }
        let servingModel = targetRunner?.servingModel ?? snapshot.model

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
                    runner: targetRunner,
                    servingModel: servingModel,
                    assistant: nil,
                    mtpStatus: mtpStatus,
                    mtpArtifact: nil)
            }
            do {
                assistant = try await assistantLoader.loadAndBind(
                    artifact: artifact,
                    runner: targetRunner.map { type(of: $0) },
                    modelDirectory: modelDirectory,
                    target: servingModel)
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

        // Second adoption, only when a drafter actually bound: the runner
        // reports `mtp` among its loaded decoders exactly then.
        var runner = targetRunner
        if let drafter = assistant?.drafter, let modelDirectory, adoptRunner {
            runner = try adopt(
                modelId: modelId,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                snapshot: snapshot,
                tokenizer: slotTokenizer,
                drafter: drafter,
                emitTelemetry: emitTelemetry,
                logInfo: logInfo)
        }

        return EngineV2PreparedModel(
            snapshot: snapshot,
            runner: runner,
            servingModel: runner?.servingModel ?? servingModel,
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
        modelDirectory: URL? = nil,
        container: ModelContainer,
        previousArtifact: SpecDecArtifact?,
        previousStatus: MTPActivationStatus,
        assistant: ProviderMTPAssistantHandle?,
        tokenizer: (any MLXLMCommon.Tokenizer)? = nil,
        adoptRunner: Bool = true,
        emitTelemetry: (@Sendable (TelemetryEvent) -> Void)? = nil,
        logInfo: @escaping @Sendable (String) -> Void = { _ in },
        logWarning: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> EngineV2PreparedModel {
        let snapshot = await modelSnapshot(container: container)
        var resolvedTokenizer = tokenizer
        if resolvedTokenizer == nil {
            resolvedTokenizer = await container.perform { ctx in ctx.tokenizer }
        }
        let slotTokenizer = resolvedTokenizer!

        /// Re-adopt over the retained container, carrying a drafter the slot
        /// already owns. Reads no tensors and never calls an assistant
        /// loader — that is the whole rule of recovery.
        func readopt(drafter: (any CBv2MTPDrafter)?) throws -> (any Runner)? {
            guard adoptRunner, let modelDirectory else { return nil }
            return try adopt(
                modelId: modelId,
                isVLM: isVLM,
                modelDirectory: modelDirectory,
                snapshot: snapshot,
                tokenizer: slotTokenizer,
                drafter: drafter,
                emitTelemetry: emitTelemetry,
                logInfo: logInfo)
        }

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
                let runner = try readopt(drafter: assistant.drafter)
                return EngineV2PreparedModel(
                    snapshot: snapshot,
                    runner: runner,
                    servingModel: runner?.servingModel ?? reusedTarget,
                    assistant: assistant,
                    mtpStatus: MTPActivationStatus.candidate(artifact).activated(
                        assistantBytes: artifact.residentBytes),
                    mtpArtifact: artifact)
            }
            let reason = revalidation.reason ?? .assistantTargetIncompatible
            logWarning(
                "mtp: model=\(modelId) recovery fallback reason=\(reason.rawValue) detail="
                    + (revalidation.detail ?? "installed assistant binding is not reusable"))
            let runner = try readopt(drafter: nil)
            return EngineV2PreparedModel(
                snapshot: snapshot,
                runner: runner,
                servingModel: runner?.servingModel ?? snapshot.model,
                assistant: nil,
                mtpStatus: previousStatus.fallingBack(reason),
                mtpArtifact: nil)
        }

        let reason: MTPFallbackReason? = previousStatus.active ? .engineInactive : nil
        let runner = try readopt(drafter: nil)
        return EngineV2PreparedModel(
            snapshot: snapshot,
            runner: runner,
            servingModel: runner?.servingModel ?? snapshot.model,
            assistant: nil,
            mtpStatus: reason.map(previousStatus.fallingBack) ?? previousStatus,
            mtpArtifact: nil)
    }
}
