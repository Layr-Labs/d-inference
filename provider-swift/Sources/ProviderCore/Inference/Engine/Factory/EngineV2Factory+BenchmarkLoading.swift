import Foundation
import MLX
import MLXLMCommon
import ProviderCoreFoundation

extension EngineV2Factory {
    /// Offline GLM baseline through the real managed loader and ordinary slot
    /// factory. Caller-supplied pinned metadata does not register a public model.
    /// Deliberately target-only and cache-free: a baseline, never a serving profile.
    /// maximumContextLength is a required enforced engine bound. Keep the
    /// returned bound in reports; it does not replace the source config maximum.
    @_spi(Benchmarking)
    public static func loadGLM5NextBenchmarkSession(
        directory: URL, catalog: CatalogModel, manifest: ModelManifest,
        maximumContextLength: Int,
        operatorReserveBytes: UInt64,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> (container: ModelContainer, session: EngineV2BenchmarkSession, maximumContextLength: Int) {
        try GLM5NextLoadFaultState.requireHealthy()
        // The pinned GLM identity defaults SSD on for serving. This baseline is
        // cache-free, so an unset flag is pinned off; an explicit opt-in refuses.
        var environment = environment
        if environment[PrefixCachePolicy.environmentFlag]?
            .trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            environment[PrefixCachePolicy.environmentFlag] = "0"
        }
        guard !PrefixCachePolicy.isEnabled(modelId: catalog.id, environment: environment),
            !PrefixCachePolicy.isMemoryEnabled(environment: environment) else {
            throw EngineV2BenchmarkSession.Failure.unexpectedResidentCache
        }
        let plan = try GLM5NextArtifactPlan.inspect(directory: directory, catalog: catalog, manifest: manifest)
        let context = try GLM5NextExecutionBound.require(maximumContextLength,
            modelMaximum: plan.configuration.textConfig.maxPositionEmbeddings)
        let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(env: environment, modelIDs: [catalog.id])
        let budget = GlobalKVCacheBudget(
            capFraction: UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: environment),
            activationReserveBytes: reserve, configReserveBytes: operatorReserveBytes)
        let activity = budget.serviceBudget.beginUnboundedActivity()
        var retained = false
        defer { if !retained { activity.finish() } }
        var newcomer: EngineV2NewcomerBox?
        var built: ProviderEngineBundle?
        // Every owner an unproven completion may still back stays alive for
        // the process; nothing is released or refunded after this.
        func retainForProcess() {
            var owners: [AnyObject] = [budget, activity]
            if let newcomer { owners.append(newcomer) }
            if let built { owners.append(built) }
            GLM5NextLoadFaultState.retain(owners)
            retained = true
        }
        do {
            let loaded = EngineV2NewcomerBox(try await loadBenchmarkContainer(modelID: catalog.id, directory: directory,
                glm5Catalog: catalog, glm5Manifest: manifest, kvBudget: budget).container)
            newcomer = loaded
            let loadedSizing = try await GLM5NextLoadFunnel.sizing(container: loaded.borrow(), defaultMaxTokens: 32)
            let sizing = SlotSizingSnapshot(weightsBytes: loadedSizing.targetWeightsBytes,
                auxiliaryWeightBytes: loadedSizing.auxiliaryWeightBytes,
                fp16KVBytesPerToken: loadedSizing.fp16KVBytesPerToken,
                maxContextLength: context, defaultMaxTokens: min(loadedSizing.defaultMaxTokens, context))
            guard KVHeadroomProbe.hasServeableKVHeadroom(activationReserveBytes: reserve) else {
                throw EngineV2BenchmarkSession.Failure.invalidCapacity
            }
            let grant = try benchmarkProductionGrant(modelId: catalog.id, sizing: sizing,
                environment: environment, operatorReserveBytes: operatorReserveBytes)
            let tokenizer = try await loaded.borrow().perform { TokenizerHandle($0.tokenizer) }
            let preparation = SpecDecPreparation(artifact: nil,
                status: .disabled(.configDisabled, configured: false))
            let bundle = try await EngineV2SlotFactory.makeProductionBundle(modelId: catalog.id,
                modelType: "glm5_next", isVLM: true, modelDirectory: directory,
                container: loaded.borrow(), tokenizer: tokenizer, sizing: sizing,
                kvBytesCapacity: grant.grantBytes, maxConcurrentRequests: 1, constructionPurpose: .benchmark,
                kvBudget: budget, activationReserveBytes: reserve, kvBackendConfig: "paged",
                kvQuantizationConfig: "native", checkpointQuantizationConfig: "native",
                modelArtifactSHA256: manifest.aggregateSHA256, weightHash: nil,
                specDecPreparation: preparation, environment: environment, startServingTelemetry: false)
            built = bundle
            guard let engine = await bundle.bridge.ownedEngine as? EngineV2 else {
                throw EngineV2BenchmarkSession.Failure.unexpectedEngine
            }
            try plan.weights.recheck()
            let sample = budget.memoryHeadroomSnapshot()
            guard KVHeadroomProbe.postBuildServeable(kvBackendKind: .paged,
                pagedPoolBytes: await bundle.bridge.kvBackendPoolBytes(),
                activationReserveBytes: reserve, measuredHeadroomBytes: sample.runtimeRemainingBytes) else {
                throw EngineV2BenchmarkSession.Failure.unservablePostLoad(
                    headroomBytes: sample.runtimeRemainingBytes, requiredBytes: UnifiedMemoryCap.minimumLoadKVBytes)
            }
            let session = EngineV2BenchmarkSession(bundle: bundle, engine: engine,
                backend: "paged", fallback: nil, effectiveMaxConcurrentRequests: 1, memoryEnabled: false,
                activationReserveBytes: reserve, postLoadMaximumKVBytes: sample.runtimeRemainingBytes,
                budget: budget, assistantIdentity: [:], productionGrant: grant,
                postBuildHeadroomBytes: sample.runtimeRemainingBytes)
            // Evidence must retain this enforced bound, not label the result
            // with the original checkpoint's advertised maximum context.
            return (try loaded.borrow(), session, context)
        } catch {
            if GLM5NextLoadFunnel.isUnproven(error) {
                retainForProcess()
                throw error
            }
            if let built {
                do { try await GLM5NextRetirement.beforeRelease(built.bridge) }
                catch {
                    retainForProcess()
                    throw GLM5NextManagedLoadError.retirementUnproven
                }
            }
            built?.releaseAssistant()
            built = nil
            await newcomer?.releaseAfterExternalResources()
            throw error
        }
    }

    /// Explicit trusted-metadata overload; the old directory-only entry remains
    /// closed for GLM and existing model families keep their original loader.
    @_spi(Benchmarking)
    public static func loadBenchmarkContainer(modelID: String, directory: URL,
        glm5Catalog: CatalogModel, glm5Manifest: ModelManifest, kvBudget: GlobalKVCacheBudget)
        async throws -> (container: ModelContainer, isVLM: Bool) {
        guard modelID == glm5Catalog.id else { throw GLM5NextManagedLoadError.identityMismatch }
        let plan = try GLM5NextArtifactPlan.inspect(directory: directory, catalog: glm5Catalog, manifest: glm5Manifest)
        let load = try await GLM5NextManagedLoad.claim(plan: plan, budget: kvBudget)
        let serving = try await ModelContainerLoading.loadServingContainer(from: directory,
            modelID: modelID, nativeGLM5Load: load)
        guard let container = serving.autoregressive else { throw GLM5NextManagedLoadError.identityMismatch }
        return (container, true)
    }

    /// Ordinary CLI native MiMo route: one real budget owns loading and the
    /// final session. No bare directory-only native factory or second model.
    @_spi(Benchmarking)
    public static func loadNativeMiMoBenchmarkSession(
        modelID: String, directory: URL, verifiedWeightHash: String,
        operatorReserveBytes: UInt64,
        maxConcurrentRequests: Int = 1, mtpEnabled: Bool = false,
        kvBackend: String = "auto",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> (container: ModelContainer, session: EngineV2BenchmarkSession) {
        guard ["auto", "contiguous"].contains(kvBackend.lowercased()) else {
            throw MiMoV26ServingLoadError.unsupportedBackend
        }
        guard let load = try MiMoV26ServingLoad.inspect(directory: directory),
            PrefixCachePolicy.checkpointIdentityHash(verifiedWeightHash) != nil else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        let reserve = UnifiedMemoryCap.resolvedActivationReserveBytes(env: environment, modelIDs: [modelID])
        let budget = GlobalKVCacheBudget(
            capFraction: UnifiedMemoryCap.resolvedCapFraction(explicit: nil, env: environment),
            activationReserveBytes: reserve,
            configReserveBytes: operatorReserveBytes)
        let registry = MiMoV26NativeLoadRegistry.shared
        try registry.requireNewNativeWorkAllowed()
        let lifecycle = try registry.openLifecycle()
        do {
            try load.claim(budget: budget, lifecycle: lifecycle, registry: registry)
            guard let transaction = load.transaction else {
                throw MiMoV26ServingLoadError.nativeOwnerMismatch
            }
            let ownership = MiMoV26BenchmarkOwnership(
                registry: registry, lifecycle: lifecycle, transaction: transaction)
            let task = try registry.launchOwnedTask(for: transaction) {
                _ = try GPUEnforcement.requireMetal()
                MLXMemoryGuard.configureOnce()
                let serving = try await ModelContainerLoading.loadServingContainer(
                    from: directory, modelID: modelID, nativeMiMoLoad: load)
                guard let container = serving.autoregressive else {
                    throw MiMoV26ServingLoadError.nativeOwnerMismatch
                }
                guard WeightHasher.computeHash(snapshotDir: directory, modelID: modelID) == verifiedWeightHash else {
                    throw EngineV2BenchmarkSession.Failure.invalidVerifiedWeightHash
                }
                try load.recheck()
                let tokenizer = await container.perform { TokenizerHandle($0.tokenizer) }
                try load.recheck()
                let session = try await makeBenchmarkSession(modelId: modelID, modelDirectory: directory,
                    isVLM: false, container: container, tokenizer: tokenizer,
                    verifiedWeightHash: verifiedWeightHash, kvBytesCapacity: 1 << 30,
                    maxConcurrentRequests: maxConcurrentRequests, mtpEnabled: mtpEnabled,
                    useProductionKVGrant: true, kvBackendConfig: kvBackend,
                    requirePersistentKey: false, environment: environment,
                    nativeMiMoLoad: load, nativeMiMoBudget: budget,
                    nativeMiMoOperatorReserveBytes: operatorReserveBytes,
                    nativeMiMoOwnership: ownership,
                    memorySnapshotForTesting: { (ProcessInfo.processInfo.physicalMemory, UInt64(Memory.activeMemory)) })
                return (container: container, session: session)
            }
            return try await withTaskCancellationHandler {
                let result = try await task.value
                // The caller is outside the stored setup task: join its exact
                // handle before returning or consuming a retirement outcome.
                await registry.joinOwnedTasksFromOutside(transaction)
                try Task.checkCancellation()
                return result
            } onCancel: {
                task.cancel()
                transaction.revoke()
            }
        } catch {
            // Closing/cancelling is not a drain. Join the actual construction
            // task before asking its strongly registered owner to retire. Any
            // pending/faulted result remains retained by that registry.
            _ = try? registry.closeLifecycle(lifecycle)
            load.revoke()
            if let transaction = load.transaction {
                await registry.joinOwnedTasksFromOutside(transaction)
            }
            let retirement = await load.finishFailureAfterUnwind()
            if case .notClaimed = retirement { throw error }
            try EngineV2BenchmarkSession.requireNativeRetirement(retirement)
            throw error
        }
    }

    /// The ordinary benchmark must use the same model-ID-qualified text/vision
    /// factory and external-resource lifetime as a production slot.
    @_spi(Benchmarking)
    public static func loadBenchmarkContainer(
        modelID: String, directory: URL
    ) async throws -> (container: ModelContainer, isVLM: Bool) {
        let selection = ModelContainerLoading.factorySelection(at: directory, modelID: modelID)
        let container = try await ModelContainerLoading.loadContainer(from: directory, modelID: modelID)
        return (container, selection == .vision)
    }

    /// Call only after the benchmark session has drained and shut down.
    @_spi(Benchmarking)
    public static func releaseBenchmarkContainer(_ container: ModelContainer) async {
        await ModelContainerLoading.releaseExternalResources(in: container)
    }
}
