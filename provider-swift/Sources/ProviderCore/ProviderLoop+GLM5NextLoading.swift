import Foundation
import MLXLMCommon

extension ProviderLoop {
    /// Coordinator-mode GLM preflight, before any reservation: hardware, the
    /// exact catalog build and its requirements, the verified revision
    /// identity and the scanner LOAD quotation.
    /// Catalog reads are bounded cache refreshes; a stale entry is refreshed
    /// once, never trusted.
    func coordinatorGLM5NextPlan(modelId: String, modelInfo: ModelInfo, directory: URL) async throws
        -> GLM5NextServingPlan
    {
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
                modelID: modelId, directory: directory, catalog: catalog)
        }
        let serving: GLM5NextServingPlan
        do {
            serving = try await resolve(forceRefresh: false)
        } catch GLM5NextManagedLoadError.identityMismatch {
            serving = try await resolve(forceRefresh: true)
        } catch GLM5NextManagedLoadError.metadata {
            serving = try await resolve(forceRefresh: true)
        }
        guard ModelScanner.glm5NextLoadQuotationIsCurrent(
            modelInfo, directory: serving.plan.weights.directory)
        else { throw GLM5NextManagedLoadError.admission }
        return serving
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

    static func glm5NextFullContextRefusal(bundle: ProviderEngineBundle, context: Int) async -> String? {
        let bridge = bundle.bridge
        return GLM5NextCoordinatorServing.fullContextRefusal(
            poolBytes: await bridge.kvBackendPoolBytes(),
            watermarkFraction: bridge.admissionWatermarkFraction ?? AdmissionV2.Config().watermarkFraction,
            stepSetupBytes: bundle.glm5NextStepSetupBytes, fixedRequestBytes: bridge.fixedRequestBytes,
            bytesPerToken: bridge.kvBytesPerToken, context: context)
    }
}
