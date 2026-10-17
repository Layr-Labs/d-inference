import Foundation

extension ProviderLoop {
    /// Coordinator-mode GLM preflight, before any reservation: hardware, the
    /// exact catalog build and its requirements, the verified revision
    /// identity and the scanner LOAD quotation.
    /// Catalog reads are bounded cache refreshes; a stale entry is refreshed
    /// once, never trusted.
    /// `restoringVerifiedSnapshot` is set only by a revision swap's rollback,
    /// which reloads the snapshot whose live hash the provider already verified.
    func coordinatorGLM5NextPlan(
        modelId: String, modelInfo: ModelInfo, directory: URL, restoringVerifiedSnapshot: Bool = false
    ) async throws -> GLM5NextServingPlan {
        if let refusal = GLM5NextHardwareRequirement.refusal(hardware: loopConfig.hardware) {
            throw GLM5NextManagedLoadError.metadata(refusal)
        }
        guard modelId == GLM5NextCoordinatorServing.catalogModelID else {
            throw GLM5NextManagedLoadError.metadata(
                "coordinator mode serves GLM only as catalog model \(GLM5NextCoordinatorServing.catalogModelID)")
        }
        func resolve(forceRefresh: Bool) async throws -> GLM5NextServingPlan {
            _ = await specDecFunnel.prewarmCatalog(modelId: modelId,
                timeout: Self.specDecCatalogPrewarmTimeout, forceRefresh: forceRefresh)
            let catalog = await specDecFunnel.cachedCatalogModel(id: modelId)
            if let catalog {
                try ModelRuntimeRequirements.requireEligible(modelID: modelId,
                    catalogRequirements: catalog.requiredProviderCapabilities,
                    available: loopConfig.runtimeCapabilities)
            }
            return try GLM5NextCoordinatorServing.resolvePlan(
                modelID: modelId, directory: directory, catalog: catalog,
                previouslyVerifiedAggregate: restoringVerifiedSnapshot ? liveModelHashes[modelId] : nil)
        }
        let serving = try await Self.resolvingWithOneCatalogRefresh(resolve(forceRefresh:))
        guard ModelScanner.glm5NextLoadQuotationIsCurrent(
            modelInfo, directory: serving.plan.weights.directory)
        else { throw GLM5NextManagedLoadError.admission }
        return serving
    }

    /// A stale or missing cached catalog entry is refreshed once; any other
    /// refusal (hardware, capability, quotation) is final.
    static func resolvingWithOneCatalogRefresh<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ resolve: (_ forceRefresh: Bool) async throws -> T
    ) async throws -> T {
        do {
            return try await resolve(false)
        } catch GLM5NextManagedLoadError.identityMismatch {
            return try await resolve(true)
        } catch GLM5NextManagedLoadError.metadata {
            return try await resolve(true)
        }
    }

    /// The bracketing load hashes must equal the manifest aggregate the plan
    /// was resolved against.
    static func requireGLM5NextLoadedArtifact(hash: String?, plan: GLM5NextArtifactPlan) throws {
        guard hash == plan.weights.manifest.aggregateSHA256 else {
            throw GLM5NextManagedLoadError.identityMismatch
        }
    }

    /// The loaded tower must store exactly the configuration-derived rows the
    /// coordinator quotation assumes, and the advertised bound must fit alone.
    static func requireGLM5NextServingGeometry(
        plan: GLM5NextServingPlan, targetSizing: SlotSizingSnapshot
    ) throws {
        guard targetSizing.fp16KVBytesPerToken
            == GLM5NextCoordinatorServing.targetKVBytesPerToken(plan.plan.configuration.textConfig),
            targetSizing.maxContextLength == plan.maximumContextLength
        else { throw GLM5NextManagedLoadError.identityMismatch }
    }

    /// The same admissible capacity (minus one step's setup) that request
    /// admission uses must hold one request at the advertised bound.
    static func glm5NextFullContextRefusal(bridge: EngineV2Bridge, context: Int) async -> String? {
        GLM5NextCoordinatorServing.fullContextRefusal(
            admissibleBytes: await bridge.admissionCapacityBytes(),
            fixedRequestBytes: bridge.fixedRequestBytes,
            bytesPerToken: bridge.kvBytesPerToken, context: context)
    }
}
