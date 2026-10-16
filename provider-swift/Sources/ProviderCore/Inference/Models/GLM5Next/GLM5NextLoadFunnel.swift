import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation

/// Load-funnel helpers for the bounded local server. Plans come from the
/// explicit local selection (`GLM5NextLocalQualification`); coordinator-mode
/// GLM loading is refused by `ProviderLoop.ensureModelLoaded`.
enum GLM5NextLoadFunnel {
    static func preparation(plan: GLM5NextArtifactPlan, mode: MTPMode, externalPath: String?) throws
        -> SpecDecPreparation
    {
        guard externalPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw GLM5NextManagedLoadError.metadata(
                "GLM uses its embedded predictor; external drafter is unsupported")
        }
        guard GLM5NextLocalServing.configuresNativeMTP(mode, modelID: plan.weights.catalog.id) else {
            return .init(artifact: nil, status: .disabled(.configDisabled, configured: false))
        }
        return .init(
            artifact: nil,
            status: .init(
                configured: true, active: false, reason: nil, source: .inline,
                revision: plan.nativeIdentity.revision,
                sourceRevision: plan.nativeIdentity.revision,
                artifactBytes: plan.quotation.mtpBytes, assistantBytes: 0))
    }

    /// Target-only GLM has no checked native completion receipt, so a load
    /// must not start (or continue) unless the embedded MTP owner will serve.
    static func requireNativeMTP(_ preparation: SpecDecPreparation) throws {
        guard preparation.artifact == nil, preparation.status.configured,
            preparation.status.reason == nil, CBv2MTPConfig.envEnabled
        else { throw GLM5NextManagedLoadError.nativeMTPRequired }
    }

    /// Post-build publication condition: the bundle is MTP-active, the engine
    /// reports MTP active, and the bridge carries the native operation owner.
    static func servesWithNativeOwner(_ bundle: ProviderEngineBundle) async -> Bool {
        let bridge = bundle.bridge
        guard bundle.mtpStatus.active, await bridge.hasGLM5NextNativeOwner else { return false }
        return await bridge.mtpStatusSnapshot().active
    }

    /// Never replace the ordinary scanner allowance with a smaller native one.
    static func estimatedWeightsGb(scanned: Double, plan: GLM5NextArtifactPlan?) -> Double {
        guard let plan else { return scanned }
        guard scanned.isFinite, scanned > 0 else { return plan.quotation.estimatedWeightsGb }
        return max(scanned, plan.quotation.estimatedWeightsGb)
    }

    static func pendingBytes(scanned: Double, plan: GLM5NextArtifactPlan?, extra: UInt64) -> UInt64
    {
        let generic = ProviderLoop.pendingLoadReservationBytes(
            estimatedWeightsGb: estimatedWeightsGb(scanned: scanned, plan: plan),
            extraWeightBytes: extra)
        guard let plan else { return generic }
        let sum = plan.quotation.requiredWeightBytes.addingReportingOverflow(extra)
        return max(generic, sum.overflow ? .max : sum.partialValue)
    }

    /// The root shares its embedding/head with MTP. Count owned array objects
    /// once; retaining that trained partition is not an external assistant load.
    static func sizing(container: ModelContainer, defaultMaxTokens: Int) async throws
        -> SlotSizingSnapshot
    {
        try await container.perform { context in
            guard let root = context.model as? GLM5NextModel else {
                throw GLM5NextManagedLoadError.identityMismatch
            }
            var seen = Set<ObjectIdentifier>()
            var bytes = 0
            for (_, array) in root.parameters().flattened()
            where seen.insert(ObjectIdentifier(array)).inserted {
                let sum = bytes.addingReportingOverflow(array.nbytes)
                guard !sum.overflow else { throw GLM5NextManagedLoadError.admission }
                bytes = sum.partialValue
            }
            return .init(
                weightsBytes: bytes,
                fp16KVBytesPerToken: kvBytesPerToken(
                    layerKinds: root.textTower.cbv2LayerKinds),
                maxContextLength: root.configuration.textConfig.maxPositionEmbeddings,
                defaultMaxTokens: min(
                    defaultMaxTokens, root.configuration.textConfig.maxPositionEmbeddings))
        }
    }

    /// The legacy snapshot field name is FP16, but GLM stores asymmetric FP32
    /// latent/index rows. KDA's three live generations remain a fixed per-request
    /// charge owned by EngineV2, not a marginal token charge or weight byte.
    /// The embedded MTP layer's latent/index history is likewise excluded from
    /// this re-slice weight: `GLM5NextMTPExecution.memoryPlan` sizes it to the
    /// explicit context bound (not to admitted tokens) and the engine's MTP
    /// admission reserves those fixed buffers before use. Its drafter reports
    /// zero `requestStateBytesPerToken`, so nothing is double-counted.
    static func kvBytesPerToken(layerKinds: [CBv2LayerKind]) -> Int {
        layerKinds.filter { $0.sharesKVWithLayer == nil && $0.attention == .full }
            .reduce(0) { $0 + $1.kvHeads * ($1.headDim + $1.valueHeadDim) * 4 }
    }

    /// Outer-funnel retention after an unproven GLM completion. Charges the
    /// claimed load quotation plus any built bridge's KV claim against the
    /// newcomer (or, before weights exist, the load's activity lease) so
    /// fleet KV budgets keep excluding memory the retained owners may hold.
    static func retainUnprovenLoad(
        owners: [AnyObject], activity: WholeMacUnboundedActivity,
        newcomer: EngineV2NewcomerBox?, bundle: ProviderEngineBundle?, weightBytes: UInt64
    ) async {
        var retained = owners + [activity]
        if let newcomer { retained.append(newcomer) }
        if let bundle { retained.append(bundle) }
        let grant = await bundle?.bridge.slotKVBytesClaim() ?? 0
        GLM5NextLoadFaultState.retain(retained, charging: newcomer ?? activity,
            residentBytes: GLM5NextLoadFaultState.saturatingSum(
                [GLM5NextLoadFaultState.residentBytes(grant), weightBytes]))
    }

    static func isUnproven(_ error: any Error) -> Bool {
        if error as? GLM5NextManagedLoadError == .retirementUnproven { return true }
        if case .retainedFault? = error as? NativeConstructionError { return true }
        return false
    }
}

/// GLM serves only through its embedded native MTP owner, so a configuration
/// that disables MTP makes every GLM load fail with `nativeMTPRequired`. The
/// local model list uses the same predicate as `GLM5NextLoadFunnel` so such a
/// model is reported not loadable instead of advertised.
public enum GLM5NextLocalServing {
    static func configuresNativeMTP(_ mode: MTPMode, modelID: String) -> Bool {
        mode.enablesMTP(forModelType: "glm5_next", embeddedArtifactDeclared: true, modelID: modelID)
    }

    public static func nativeMTPAvailable(
        mode: MTPMode, modelID: String, processMTPEnabled: Bool = CBv2MTPConfig.envEnabled
    ) -> Bool {
        processMTPEnabled && configuresNativeMTP(mode, modelID: modelID)
    }

    /// Splits out exact `glm5_next` models that cannot load under `mode`.
    /// Every other model passes through unchanged.
    public static func partition(
        _ models: [ModelInfo], mode: MTPMode, processMTPEnabled: Bool = CBv2MTPConfig.envEnabled
    ) -> (loadable: [ModelInfo], nativeMTPUnavailable: [ModelInfo]) {
        var loadable: [ModelInfo] = []
        var unavailable: [ModelInfo] = []
        for model in models {
            if GLM5NextPromptPolicy.applies(modelType: model.modelType),
                !nativeMTPAvailable(mode: mode, modelID: model.id, processMTPEnabled: processMTPEnabled) {
                unavailable.append(model)
            } else {
                loadable.append(model)
            }
        }
        return (loadable, unavailable)
    }
}
