import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// What a MiMo phase split hands over: the producer stage's attention caches
/// after the last prompt frame, one keys and one values tensor per layer, in
/// layer order. The rank that adopts them holds every layer (it loaded the
/// producer stage beside its own) and decodes alone; the rank that held the
/// first range only took a share of the prompt.
///
/// A full-attention layer's cache is the prompt's keys and values
/// `[1, heads, prompt, width]`. A sliding-window layer's rotating cache keeps,
/// after a prompt prefilled frame by frame, the last `window - 1` positions of
/// the previous frame plus the frame just appended (its own concatenation
/// rule), with its write index at the end; that length and index follow from
/// the request's frame grid alone, so both ranks derive them and only the
/// arrays cross. Everything here is derived from the loaded stage's own
/// configuration: no MiMo table, no cut.
enum MiMoPhaseSplitState {
    /// The prompt's frame lengths, in order.
    static func frameTokenCounts(_ request: QwenLayerStageGenerationRequest) throws -> [Int] {
        try (0..<request.prefillFrameCount).map { sequence in
            let frame = try request.frame(sequence: sequence)
            guard frame.phase == .prefill else { throw ProbeError("A prompt frame is not a prefill frame") }
            return frame.tokenCount
        }
    }

    /// The rotating cache's retained length after prompt frames of these lengths.
    static func slidingRetainedTokens(window: Int, frames: [Int]) throws -> Int {
        guard window >= 1, !frames.isEmpty, frames.allSatisfy({ $0 >= 1 }) else {
            throw ProbeError("A sliding-window layer needs a positive window and a prompt")
        }
        var length = 0
        for (index, count) in frames.enumerated() {
            // First frame: the cache takes the frame as it is. Later frames: the
            // cache keeps at most window - 1 earlier positions, then appends.
            length = (index == 0 ? 0 : min(length, window - 1)) + count
        }
        return length
    }

    /// Hand-off components of a producer stage after a prompt prefilled in
    /// frames of these lengths, in the order the producer exports and the
    /// adopter installs them.
    static func expectedShapes(stage configuration: MiMoV26Configuration, firstGlobalLayer: Int, frames: [Int],
                               activationDType: String) throws -> [QwenPhaseSplitStateShape] {
        let prompt = frames.reduce(0, +)
        guard firstGlobalLayer == 0, configuration.numHiddenLayers >= 1, (1...32_768).contains(prompt) else {
            throw ProbeError("A MiMo phase split hands over the producer stage after a whole prompt")
        }
        let element = try QwenPhaseSplitStateShape.elementBytes(activationDType)
        let product = QwenLongPrefillCheckedBytes.product
        var shapes: [QwenPhaseSplitStateShape] = []
        for local in 0..<configuration.numHiddenLayers {
            let geometry = try configuration.attentionGeometry(at: local)
            let tokens = try geometry.slidingWindow.map { try slidingRetainedTokens(window: $0, frames: frames) } ?? prompt
            for (component, width) in [("kv.keys", geometry.headDim), ("kv.values", geometry.valueHeadDim)] {
                let shape = [1, geometry.keyValueHeads, tokens, width]
                shapes.append(.init(globalLayerIndex: firstGlobalLayer + local, component: component, shape: shape,
                    dtype: activationDType, byteCount: try product(shape + [element])))
            }
        }
        return shapes
    }

    /// The rotating cache's metadata after the prompt (`RotatingKVCache.metaState`):
    /// keep 0, the window, the cache's own step, the prompt as its offset and
    /// the retained length as its write index.
    static func slidingMetadata(window: Int, retained: Int, prompt: Int, step: Int) -> [String] {
        ["0", String(window), String(step), String(prompt), String(retained)]
    }

    /// The producer caches' arrays after the prompt, in `shapes` order, each
    /// checked against its agreed shape and (for a rotating cache) the
    /// rotation the frame grid gives. Lazy views; the caller reads the bytes.
    static func exportArrays(caches: [KVCache], configuration: MiMoV26Configuration, prompt: Int,
                             shapes: [QwenPhaseSplitStateShape]) throws -> [MLXArray] {
        guard shapes.count == 2 * caches.count, caches.count == configuration.numHiddenLayers else {
            throw ProbeError("Producer caches differ from the agreed hand-off manifest")
        }
        var arrays: [MLXArray] = []
        for (local, cache) in caches.enumerated() {
            let state = cache.state
            let keys = shapes[2 * local], values = shapes[2 * local + 1]
            guard state.count == 2, cache.offset == prompt,
                  state[0].shape == keys.shape, state[1].shape == values.shape,
                  String(describing: state[0].dtype) == keys.dtype, String(describing: state[1].dtype) == values.dtype else {
                throw ProbeError("Producer layer \(local) state differs from the agreed hand-off manifest")
            }
            let geometry = try configuration.attentionGeometry(at: local)
            if let rotating = cache as? RotatingKVCache {
                guard let window = geometry.slidingWindow, let step = Int(rotating.metaState[2]),
                      rotating.metaState == slidingMetadata(window: window, retained: keys.shape[2], prompt: prompt, step: step) else {
                    throw ProbeError("Producer layer \(local) rotation differs from the request's frame grid")
                }
            } else {
                guard geometry.slidingWindow == nil, cache is KVCacheSimple else {
                    throw ProbeError("Producer layer \(local) cache kind differs from its attention")
                }
            }
            arrays.append(state[0]); arrays.append(state[1])
        }
        return arrays
    }

    /// Installs adopted arrays into fresh caches: a full-attention layer's
    /// growing cache takes keys and values as they are; a sliding layer's
    /// rotating cache also takes the rotation the frame grid gives.
    static func install(_ state: QwenLayerStageAdoptedState, into caches: [KVCache], shapes: [QwenPhaseSplitStateShape],
                        prompt: Int, configuration: MiMoV26Configuration) throws {
        guard shapes.count == 2 * caches.count, state.attention.count == caches.count, state.recurrent.isEmpty,
              state.committedTokens == prompt, caches.allSatisfy({ $0.offset == 0 }) else {
            throw ProbeError("Adopted state names other layers or another frontier than the producer stage holds")
        }
        for (local, cache) in caches.enumerated() {
            let keys = shapes[2 * local], values = shapes[2 * local + 1]
            guard keys.globalLayerIndex == local, values.globalLayerIndex == local,
                  let arrays = state.attention[local], arrays.keys.shape == keys.shape, arrays.values.shape == values.shape,
                  String(describing: arrays.keys.dtype) == keys.dtype,
                  String(describing: arrays.values.dtype) == values.dtype else {
                throw ProbeError("Adopted layer \(local) differs from the agreed hand-off manifest")
            }
            let geometry = try configuration.attentionGeometry(at: local)
            if let rotating = cache as? RotatingKVCache {
                guard let window = geometry.slidingWindow, let step = Int(rotating.metaState[2]) else {
                    throw ProbeError("Adopted layer \(local) is not a sliding-window layer")
                }
                rotating.metaState = slidingMetadata(window: window, retained: keys.shape[2], prompt: prompt, step: step)
                rotating.state = [arrays.keys, arrays.values]
            } else {
                guard geometry.slidingWindow == nil, let simple = cache as? KVCacheSimple else {
                    throw ProbeError("Adopted layer \(local) is not a full-attention layer")
                }
                simple.state = [arrays.keys, arrays.values]
            }
            guard cache.offset == prompt else { throw ProbeError("Adopted layer \(local) frontier differs") }
        }
    }
}

extension QwenPhaseSplitPlan {
    /// The terms of a MiMo phase split, from the producer stage both ranks
    /// hold (rank 0 as its own range, rank 1 beside its own) and the request.
    /// Same terms schema, transfer segments and limits as every other family.
    init(mimoProducer stage: LoadedMiMoLayerStage, request: QwenLayerStageGenerationRequest,
         maximumSegmentBytes: Int = CollectivePointToPointShape.hardByteLimit,
         relayBatchTokens: Int = QwenPhaseSplitTerms.defaultRelayBatchTokens,
         handoffLimitMilliseconds: Int = QwenPhaseSplitTerms.defaultHandoffLimitMilliseconds) throws {
        guard stage.stageIndex == 0, stage.plan.stages.count == 2,
              (4096...CollectivePointToPointShape.hardByteLimit).contains(maximumSegmentBytes),
              (1...QwenPhaseSplitTerms.maximumRelayBatchTokens).contains(relayBatchTokens),
              (1000...120_000).contains(handoffLimitMilliseconds) else {
            throw ProbeError("A MiMo phase split requires the producer stage of an admitted two-stage Plan and bounded terms")
        }
        guard request.reusedPrefixTokens == 0 else { throw ProbeError("A MiMo phase split hands over a whole prompt") }
        let shapes = try MiMoPhaseSplitState.expectedShapes(stage: stage.model.configuration,
            firstGlobalLayer: stage.plan.stages[0].sourceRange.lowerBound,
            frames: try MiMoPhaseSplitState.frameTokenCounts(request), activationDType: request.profile.activationDType)
        let segments = try Self.segments(shapes, maximumSegmentBytes: maximumSegmentBytes)
        guard try QwenPhaseSplitHandoffHeader.encodedBytesBound(shapes: shapes)
                <= QwenPhaseSplitHandoffHeader.frameBytes - QwenControlFrame.headerBytes else {
            throw ProbeError("Phase split: this model and cut name more state components than one hand-off header holds")
        }
        self.shapes = shapes; self.segments = segments
        terms = .init(handoffCommittedTokens: request.promptCount,
            producerLayerCount: stage.plan.stages[0].sourceRange.count, entryCount: shapes.count,
            logicalBytes: try QwenLongPrefillCheckedBytes.sum(shapes.map(\.byteCount)),
            manifestSHA256: sha256(Data((["mimo-phase-split-manifest-v1", "tokens=\(request.promptCount)"]
                + shapes.map(\.identity)).joined(separator: "\n").utf8)),
            maximumSegmentBytes: maximumSegmentBytes, segmentCount: segments.count,
            relayBatchTokens: relayBatchTokens, handoffLimitMilliseconds: handoffLimitMilliseconds)
    }
}
