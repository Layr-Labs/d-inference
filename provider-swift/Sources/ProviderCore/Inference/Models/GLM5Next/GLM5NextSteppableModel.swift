import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Target-only execution bridge over the original GLM target, constructed only
/// for `.benchmark` engines (`prepareProductionBackend` refuses it for serving).
/// The root is retained when present; no second text model, recurrent cache or
/// vision owner is made. The non-recurrent forwards are protocol requirements
/// EngineV2 never calls for a model with a recurrent-state spec.
final class GLM5NextSteppableModel: CBv2RecurrentMTPSteppableModel,
    CBv2RecurrentPrefillSteppableModel, CBv2PositionedMultimodalSteppableModel,
    CBv2CompleteCheckpointKVTypeProviding, CBv2TargetAuxiliaryAllocationProviding
{
    let target: GLM5NextTextModel
    let root: GLM5NextModel?
    init(target: GLM5NextTextModel, root: GLM5NextModel?) {
        self.target = target
        self.root = root
    }
    var cbv2Capabilities: CBv2ModelCapabilities { target.cbv2Capabilities }
    var recurrentStateSpec: CBv2RecurrentStateSpec? { target.cbv2RecurrentStateSpec }
    var cbv2CompleteCheckpointKVDTypes: [DType]? {
        Array(repeating: .float32, count: target.cbv2LayerKinds.count)
    }
    var cbv2TargetAuxiliaryAllocationSpecs: [CBv2AuxiliaryAllocationSpec]? {
        target.cbv2TargetAuxiliaryAllocationSpecs
    }
    var mtpCaptureLayers: CBv2MTPCaptureLayers? { nil }
    var supportsRequestStatefulMTP: Bool { false }  // Only the issued protected model enables MTP.
    var mtpTargetIdentity: ObjectIdentifier? { ObjectIdentifier(target) }
    var supportsMultimodalPrefill: Bool { root != nil }
    var causalPositionRequirement: CBv2CausalPositionRequirement { .scalarCacheOffset }
    func supportsMultimodalPrefill(attention: CBv2MultimodalAttention) -> Bool {
        root != nil && attention == .causal
    }
    func embedPromptTokens(_ tokens: MLXArray) -> MLXArray { target.embed(tokens) }

    func forward(tokens: MLXArray, caches: [any CBv2AttendingLayerCache]) -> MLXArray {
        preconditionFailure("GLM requires request-owned recurrent state")
    }
    func forward(
        tokens: MLXArray, inputEmbeddings: MLXArray,
        caches: [any CBv2AttendingLayerCache]
    ) -> MLXArray {
        preconditionFailure("GLM media requires request-owned recurrent state")
    }
    func forwardWithHidden(tokens: MLXArray, caches: [any CBv2AttendingLayerCache])
        -> (logits: MLXArray, lastHidden: MLXArray)
    {
        preconditionFailure("GLM requires request-owned recurrent state")
    }
    func forward(
        tokens: MLXArray, caches: [any CBv2AttendingLayerCache],
        recurrentState: [CBv2RecurrentStateEvaluation]
    ) -> MLXArray {
        target.cbv2Forward(tokens, caches: kvCaches(caches), recurrentState: recurrentState)
    }
    func forwardWithHidden(
        tokens: MLXArray, caches: [any CBv2AttendingLayerCache],
        recurrentState: [CBv2RecurrentStateEvaluation], positionIds: MLXArray?
    )
        -> (logits: MLXArray, lastHidden: MLXArray)
    {
        target.cbv2ForwardWithHidden(
            tokens, caches: kvCaches(caches),
            recurrentState: recurrentState, positionIds: positionIds)
    }
    func forwardWithHiddenForPrefill(
        tokens: MLXArray, caches: [any CBv2AttendingLayerCache],
        recurrentState: [CBv2RecurrentStateEvaluation], positionIds: MLXArray?,
        requirement: CBv2PrefillRequirement
    )
        -> (logits: MLXArray, lastHidden: MLXArray)
    {
        target.cbv2ForwardWithHiddenForPrefill(
            tokens, caches: kvCaches(caches),
            recurrentState: recurrentState, positionIds: positionIds, requirement: requirement)
    }
    func recurrentPrefill(
        tokens: MLXArray, inputEmbeddings: MLXArray?, caches: [any CBv2AttendingLayerCache],
        recurrentState: [CBv2RecurrentStateEvaluation], positionIds: MLXArray?,
        requirement: CBv2PrefillRequirement
    ) -> MLXArray {
        target.cbv2RecurrentPrefill(
            tokens, inputEmbedding: inputEmbeddings, cache: kvCaches(caches),
            recurrentState: recurrentState, positionIds: positionIds, requirement: requirement)
    }
    func forward(
        tokens: MLXArray, inputEmbeddings: MLXArray, caches: [any CBv2AttendingLayerCache],
        recurrentState: [CBv2RecurrentStateEvaluation], positionIds: MLXArray?
    ) -> MLXArray {
        do {
            return try target.prepareCBv2Forward(
                tokens: tokens, caches: kvCaches(caches),
                recurrentState: recurrentState, positionIds: positionIds,
                inputEmbeddings: inputEmbeddings
            ).logits
        } catch {
            // GLM's graph builder records recoverable native failures in its
            // actual shared paged-pool latch. This read-only public accessor has
            // a historical Qwen name; it is NOT a Qwen model/layout cast. Never
            // return an unwind array unless EngineV2's next check will throw.
            precondition(
                !caches.isEmpty
                    && caches.allSatisfy {
                        ($0 as? PagedLayerCache)?.qwen4HasWriteFault == true
                    }, "GLM prevalidated embedding-forward invariant failed")
            return MLXArray.zeros([tokens.dim(0), tokens.dim(1), target.vocabularySize])
        }
    }
    private func kvCaches(_ caches: [any CBv2AttendingLayerCache]) -> [any KVCache] {
        caches.map {
            guard let value = $0 as? any KVCache else {
                preconditionFailure("GLM received a foreign cache without KV ownership")
            }
            return value
        }
    }
}

/// GLM's step-owned pages support ordinary causal substitution, not a
/// bidirectional span overlay. Keep those two capabilities distinct; never
/// change the shared cache's span-mask claim to get a media request admitted.
final class GLM5NextCausalCacheBank: CBv2MultimodalAttentionCapabilityProviding,
    CBv2CompositionInvalidating
{
    private let bank: CBv2LayerCacheBank
    private let root: GLM5NextModel?
    init(
        target: GLM5NextTextModel, root: GLM5NextModel?, backend: PagedKVBackend,
        caches: [any CBv2AttendingLayerCache]
    ) throws {
        guard root == nil || root?.textTower === target,
            backend.layerKinds == target.cbv2LayerKinds,
            caches.count == target.cbv2LayerKinds.count,
            zip(caches, target.cbv2LayerKinds).allSatisfy({ cache, kind in
                cache.kind == kind && cache is PagedLayerCache
            }
            ),
            backend.pool.config.gatheredAttention?.admissionMode == .stepOwned(.pinnedMetal)
        else {
            throw GLM5NextManagedLoadError.identityMismatch
        }
        self.root = root
        bank = CBv2LayerCacheBank(caches: caches)
    }
    var supportsMultimodalSpans: Bool { false }
    var supportsPackedPrefill: Bool { false }
    var supportsPackedMultimodalSpans: Bool { false }
    var supportsMTPRectangularVerification: Bool { false }
    func supportsMultimodalPrefill(attention: CBv2MultimodalAttention) -> Bool {
        root != nil && attention == .causal
    }
    func layerCaches(rowStates: [[(any CBv2SequenceKV)?]]) -> [any CBv2AttendingLayerCache] {
        bank.layerCaches(rowStates: rowStates)
    }
    func invalidateBoundComposition() { bank.invalidateBoundComposition() }
    func releaseBoundRows() { bank.releaseBoundRows() }
}
