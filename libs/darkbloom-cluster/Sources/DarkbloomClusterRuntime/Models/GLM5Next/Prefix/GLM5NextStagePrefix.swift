import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// A GLM stage's committed request state at an exact prompt frontier, as the
/// prompt-prefix tiers keep it.
///
/// A DSA layer (`GLM5NextDSACache`) appends one row per committed position to
/// each of its histories, so its state at a frontier is a prefix of the
/// request's: one copy at a prompt's deepest frontier serves every shallower
/// one, as a dense stage's attention copy does. A KDA layer
/// (`GLM5NextKDACache`) holds a fixed convolution and recurrent state, so its
/// state at a frontier is its own and is kept per frontier.
///
/// The tiers' shared types carry it unchanged (`QwenStagePrefixState`): a DSA
/// layer's latents are its attention `keys` and its index keys and pool gates,
/// side by side, its `values`, each as `[1, 1, tokens, width]` (one head) so
/// the resident cache and the encrypted SSD record slice and store them as
/// they do attention rows; a KDA layer's convolution and recurrent state are
/// its `recurrent` pair. A committed prompt prefix is valid at every position,
/// so the DSA validity history is not stored and is rebuilt on restore. The
/// layer index is the model's global layer index.
enum GLM5NextStagePrefixSnapshot {
    /// The state of every layer at `frontier`, or nil when a DSA history is
    /// not storable here (a position marked invalid, or index keys and pool
    /// gates of different types). Arrays are this capture's own copies: no
    /// later append to the request's histories can reach them.
    static func capture(layers: [any KVCache], globalLayers: [Int], frontier: Int)
        throws -> (dsa: [Int: (keys: MLXArray, values: MLXArray)], kda: [Int: (conv: MLXArray, ssm: MLXArray)])? {
        guard layers.count == globalLayers.count, frontier > 0 else {
            throw ProbeError("GLM prefix capture differs from the stage's layers or frontier")
        }
        var dsa: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        var kda: [Int: (conv: MLXArray, ssm: MLXArray)] = [:]
        var validities: [MLXArray] = []
        for (layer, index) in zip(layers, globalLayers) {
            guard layer.offset == frontier else { throw ProbeError("GLM prefix capture frontier differs from a layer's") }
            if layer is GLM5NextDSACache {
                let state = layer.state
                guard state.count == 4, state[0].ndim == 3, state[0].dim(0) == 1, state[0].dim(1) == frontier,
                      state[1].shape == state[2].shape, state[1].dim(1) == frontier,
                      state[3].shape == [1, frontier], state[3].dtype == .bool else {
                    throw ProbeError("GLM prefix capture lacks a DSA history")
                }
                guard state[1].dtype == state[2].dtype else { return nil }
                validities.append(state[3])
                dsa[index] = (keys: owned(state[0].expandedDimensions(axis: 1)),
                              values: concatenated([state[1], state[2]], axis: -1).expandedDimensions(axis: 1))
            } else if layer is GLM5NextKDACache {
                let state = layer.state
                guard state.count == 2, state[0].ndim == 3, state[1].ndim == 4, state[0].dim(0) == 1 else {
                    throw ProbeError("GLM prefix capture lacks a KDA state")
                }
                kda[index] = (conv: owned(state[0]), ssm: owned(state[1]))
            } else {
                throw ProbeError("GLM prefix capture found an unknown layer cache")
            }
        }
        let arrays = dsa.values.flatMap { [$0.keys, $0.values] } + kda.values.flatMap { [$0.conv, $0.ssm] }
        let allValid = validities.isEmpty ? MLXArray(true) : all(concatenated(validities.map { $0.flattened() }))
        eval(arrays + [allValid])
        guard allValid.item(Bool.self) else { return nil }
        return (dsa, kda)
    }

    /// Restores `state` (this stage's state at `state.committedTokens`) into a
    /// fresh request cache. Every local layer must be present exactly once, in
    /// its own kind, with the frontier's row count; anything else is refused and
    /// the request prefills from zero on both ranks. The cache gets copies,
    /// never the kept arrays, so later appends cannot change a kept entry.
    static func restore(_ state: QwenStagePrefixState, into layers: [any KVCache], globalLayers: [Int]) throws {
        let frontier = state.committedTokens
        guard frontier > 0, layers.count == globalLayers.count,
              layers.allSatisfy({ $0.offset == 0 && $0.innerState().isEmpty }) else {
            throw ProbeError("GLM prefix restore needs a fresh cache")
        }
        var dsaLayers = Set<Int>(), kdaLayers = Set<Int>()
        for (fresh, index) in zip(layers, globalLayers) {
            // The caches are classes: this binding mutates the request's own.
            var layer = fresh
            if layer is GLM5NextDSACache {
                guard let pair = state.attention[index], pair.keys.ndim == 4, pair.values.ndim == 4,
                      pair.keys.dim(0) == 1, pair.keys.dim(1) == 1, pair.keys.dim(2) == frontier,
                      pair.values.dim(0) == 1, pair.values.dim(1) == 1, pair.values.dim(2) == frontier,
                      pair.values.dim(3) > 0, pair.values.dim(3) % 2 == 0 else {
                    throw ProbeError("GLM prefix restore lacks DSA layer \(index)")
                }
                let width = pair.values.dim(3) / 2
                let latents = owned(pair.keys.squeezed(axis: 1)), packed = pair.values.squeezed(axis: 1)
                layer.state = [latents, owned(packed[0..., 0..., ..<width]), owned(packed[0..., 0..., width...]),
                               MLXArray.ones([1, frontier], dtype: .bool)]
                dsaLayers.insert(index)
            } else if layer is GLM5NextKDACache {
                guard let pair = state.recurrent[index], pair.conv.ndim == 3, pair.ssm.ndim == 4,
                      pair.conv.dim(0) == 1, pair.ssm.dim(0) == 1, pair.ssm.dtype == .float32 else {
                    throw ProbeError("GLM prefix restore lacks KDA layer \(index)")
                }
                layer.state = [owned(pair.conv), owned(pair.ssm)]
                layer.metaState = ["glm5_kda_v1", String(frontier)]
                kdaLayers.insert(index)
            } else {
                throw ProbeError("GLM prefix restore found an unknown layer cache")
            }
            guard layer.offset == frontier else { throw ProbeError("GLM prefix restore left a layer at another frontier") }
        }
        guard Set(state.attention.keys) == dsaLayers, Set(state.recurrent.keys) == kdaLayers else {
            throw ProbeError("GLM prefix state names a layer outside this stage")
        }
        eval(layers.flatMap { $0.innerState() })
    }

    /// A new array with its own storage and the same bits.
    private static func owned(_ array: MLXArray) -> MLXArray { array * MLXArray(1).asType(array.dtype) }
}

extension ClusterStagePrefixCapture {
    /// One request's prefix capture on one GLM stage: the DSA histories are
    /// its shared copy and the KDA states a frontier's own. A frontier where a
    /// history was not storable is skipped.
    static func glm5Next(frontiers: Set<Int>) -> ClusterStagePrefixCapture {
        ClusterStagePrefixCapture(frontiers: frontiers) { layers, globalLayers, frontier in
            guard let state = try GLM5NextStagePrefixSnapshot.capture(layers: layers, globalLayers: globalLayers,
                                                                      frontier: frontier) else { return nil }
            return (shared: state.dsa, own: state.kda,
                    ownChargeBytes: state.kda.values.reduce(0) { $0 + $1.conv.nbytes + $1.ssm.nbytes })
        }
    }
}

extension GLM5NextStageSession: ClusterStagePrefixSession {
    func discardRestored(check: () throws -> Void) throws { try close(check: check) }
}

/// The shared two-exchange prefix plan (`agreeClusterStagePrefixPlan`) for a
/// GLM stage: a restored or fresh `GLM5NextStageSession`, and a capture of its
/// DSA histories and KDA states (`ClusterStagePrefixCapture.glm5Next`).
func agreeGLM5NextStagePrefixPlan(cache: QwenStagePrefixCache?, stage: GLM5NextStageBinding,
    agreement: QwenLayerStageGenerationAgreement, collective: Collective, check: () throws -> Void
) throws -> ClusterStagePrefixPlanOutcome<GLM5NextStageSession> {
    return try agreeClusterStagePrefixPlan(family: "glm", cache: agreement.request.stillImages == nil ? cache : nil, agreement: agreement, collective: collective,
        check: check, restored: { planned, state in
            try GLM5NextStageSession(stage: stage, agreement: try agreement.planned(planned), restoring: state)
        }, fresh: { _, planned in
            try GLM5NextStageSession(stage: stage, agreement: planned)
        }, capture: ClusterStagePrefixCapture.glm5Next)
}
