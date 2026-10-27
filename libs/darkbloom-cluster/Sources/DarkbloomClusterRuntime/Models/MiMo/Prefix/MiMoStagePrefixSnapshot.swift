import Foundation
import MLX
import MLXLMCommon

/// A MiMo stage's committed request state at an exact prompt frontier, as the
/// prompt-prefix tiers keep it: the rows of every full-attention layer and the
/// tail of every sliding-window layer's ring.
///
/// A full-attention layer (a growing `KVCacheSimple`) holds every committed
/// position, so its rows at a frontier are a prefix of the request's rows: one
/// copy at a prompt's deepest frontier serves every shallower one, as a dense
/// stage's attention copy does. A sliding-window layer (a `RotatingKVCache` of
/// `window` positions) holds only a ring, so its state at a frontier is its
/// own: the last `min(frontier, window)` positions, in temporal order. That is
/// exactly what the ring keeps after a multi-token frame (`updateConcat`
/// leaves it in temporal order with `idx == count`); every later frame trims
/// it to the same last `window - 1` (multi-token) or `window` (one token)
/// positions whether it held `window - 1 + S` or `window` of them, so a ring
/// restored from the tail continues bit for bit as the original would. A ring
/// that was last written one token at a time (`updateInPlace`: rotated,
/// `idx != count`) is not in temporal order; a frontier reached that way is
/// not captured (the split frontier after a one-token frame, rare).
///
/// The tiers' shared types carry it unchanged (`QwenStagePrefixState`): the
/// full-attention rows are its `attention` (a prefix of the deepest copy, kept
/// once per prompt) and each sliding layer's tail is a per-frontier pair in its
/// `recurrent` slots (keys in the first, values in the second), so the
/// resident cache, the two-rank plan and the encrypted SSD record need no
/// MiMo-specific code. The layer index is the model's global layer index.
enum MiMoStagePrefixSnapshot {
    /// One local cache's role, from its class and the plan's layer kind.
    enum Kind: Equatable { case full, sliding(window: Int) }

    /// The state of every local cache at `frontier`, or nil when a sliding
    /// ring is not in temporal order (see the type). Arrays are this
    /// session's own copies (an exact multiply, `owned`): no later write to
    /// the request's caches can reach them, and a tail does not keep the
    /// whole ring buffer alive.
    static func capture(caches: [KVCache], globalLayers: [Int], frontier: Int)
        throws -> (full: [Int: (keys: MLXArray, values: MLXArray)], sliding: [Int: (keys: MLXArray, values: MLXArray)])? {
        guard caches.count == globalLayers.count, frontier > 0 else {
            throw ProbeError("MiMo prefix capture differs from the stage's layers")
        }
        var full: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        var sliding: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        for (cache, layer) in zip(caches, globalLayers) {
            guard cache.offset == frontier else { throw ProbeError("MiMo prefix capture frontier differs from a layer's") }
            switch try kind(cache) {
            case .full:
                let state = cache.state
                guard state.count == 2, state[0].ndim == 4, state[0].dim(2) == frontier, state[1].dim(2) == frontier else {
                    throw ProbeError("MiMo prefix capture lacks a full-attention row")
                }
                full[layer] = (keys: owned(state[0]), values: owned(state[1]))
            case .sliding(let window):
                let raw = cache.innerState()
                guard raw.count == 2, raw[0].ndim == 4, raw[0].dim(2) == raw[1].dim(2),
                      let idx = Int(cache.metaState[4]) else {
                    throw ProbeError("MiMo prefix capture lacks a sliding-window ring")
                }
                let count = raw[0].dim(2)
                // Rotated by one-token writes: not in temporal order, not kept.
                guard idx == count, count >= min(frontier, window) else { return nil }
                let kept = min(frontier, window)
                sliding[layer] = (keys: owned(raw[0][0..., 0..., (count - kept)..<count, 0...]),
                                  values: owned(raw[1][0..., 0..., (count - kept)..<count, 0...]))
            }
        }
        eval(full.values.flatMap { [$0.keys, $0.values] } + sliding.values.flatMap { [$0.keys, $0.values] })
        return (full, sliding)
    }

    /// Restores `state` (this stage's state at `state.committedTokens`) into
    /// fresh caches. Every local layer must be present exactly once, in its
    /// own kind, with the frontier's row counts; anything else is refused and
    /// the request prefills from zero on both ranks.
    ///
    /// The caches get copies, never the kept arrays: a ring takes its next
    /// token in place (`updateInPlace` assigns into its keys) and an MLXArray
    /// is a reference, so a ring holding the kept arrays would change the
    /// kept entry for every later hit and the bytes its SSD record is written
    /// from. A copy is exact (`x * 1`) and costs one stage state's bytes.
    static func restore(_ state: QwenStagePrefixState, into caches: [KVCache], globalLayers: [Int]) throws {
        let frontier = state.committedTokens
        guard frontier > 0, caches.count == globalLayers.count,
              caches.allSatisfy({ $0.offset == 0 && $0.innerState().isEmpty }) else {
            throw ProbeError("MiMo prefix restore needs fresh caches")
        }
        var fullLayers = Set<Int>(), slidingLayers = Set<Int>()
        for (fresh, layer) in zip(caches, globalLayers) {
            // The caches are classes: this binding mutates the request's own.
            var cache = fresh
            switch try kind(cache) {
            case .full:
                guard let pair = state.attention[layer], pair.keys.ndim == 4, pair.values.ndim == 4,
                      pair.keys.dim(2) == frontier, pair.values.dim(2) == frontier,
                      pair.keys.dim(0) == 1, pair.values.dim(0) == 1, pair.keys.dim(1) == pair.values.dim(1) else {
                    throw ProbeError("MiMo prefix restore lacks full-attention layer \(layer)")
                }
                cache.state = [owned(pair.keys), owned(pair.values)]
                fullLayers.insert(layer)
            case .sliding(let window):
                let kept = min(frontier, window)
                guard let pair = state.recurrent[layer], pair.conv.ndim == 4, pair.ssm.ndim == 4,
                      pair.conv.dim(2) == kept, pair.ssm.dim(2) == kept,
                      pair.conv.dim(0) == 1, pair.ssm.dim(0) == 1, pair.conv.dim(1) == pair.ssm.dim(1) else {
                    throw ProbeError("MiMo prefix restore lacks sliding-window layer \(layer)")
                }
                let meta = cache.metaState
                guard meta.count == 5 else { throw ProbeError("MiMo prefix restore found an unknown ring") }
                cache.state = [owned(pair.conv), owned(pair.ssm)]
                // keep, window, step as the fresh ring has them; offset and the
                // write position as the original ring had them after its frame.
                cache.metaState = [meta[0], meta[1], meta[2], String(frontier), String(kept)]
                slidingLayers.insert(layer)
            }
            guard cache.offset == frontier else { throw ProbeError("MiMo prefix restore left a layer at another frontier") }
        }
        guard Set(state.attention.keys) == fullLayers, Set(state.recurrent.keys) == slidingLayers else {
            throw ProbeError("MiMo prefix state names a layer outside this stage")
        }
        eval(caches.flatMap { $0.innerState() })
    }

    /// What one frontier's sliding tails hold once every ring is full: each
    /// layer's bytes per kept position times its own window, whatever the
    /// frontier they were taken at.
    static func windowTailBytes(_ sliding: [Int: (keys: MLXArray, values: MLXArray)], caches: [KVCache],
                                globalLayers: [Int]) throws -> Int {
        var total = 0
        for (cache, layer) in zip(caches, globalLayers) {
            guard case .sliding(let window) = try kind(cache), let tail = sliding[layer] else { continue }
            let positions = tail.keys.dim(2)
            guard positions > 0, tail.values.dim(2) == positions else {
                throw ProbeError("MiMo prefix capture kept an empty sliding tail")
            }
            let perPosition = (tail.keys.nbytes + tail.values.nbytes + positions - 1) / positions
            let full = perPosition.multipliedReportingOverflow(by: window)
            guard !full.overflow else { throw ProbeError("MiMo prefix tail size overflows") }
            total = try QwenLongPrefillCheckedBytes.sum([total, full.partialValue])
        }
        return total
    }

    /// A new array with its own storage and the same bits.
    private static func owned(_ array: MLXArray) -> MLXArray { array * MLXArray(1).asType(array.dtype) }

    static func kind(_ cache: KVCache) throws -> Kind {
        if let ring = cache as? RotatingKVCache {
            guard let window = ring.maxSize, window > 0, ring.metaState.count == 5, ring.metaState[0] == "0" else {
                throw ProbeError("MiMo prefix needs a sliding ring with no kept prefix")
            }
            return .sliding(window: window)
        }
        guard type(of: cache) == KVCacheSimple.self else { throw ProbeError("MiMo prefix found an unknown layer cache") }
        return .full
    }
}

extension ClusterStagePrefixCapture {
    /// One request's prefix capture on one MiMo stage: the full-attention rows
    /// are its shared copy and each sliding layer's tail a frontier's own pair
    /// (keys in `conv`, values in `ssm`). A frontier where a ring was rotated
    /// is skipped.
    static func mimo(frontiers: Set<Int>) -> ClusterStagePrefixCapture {
        ClusterStagePrefixCapture(frontiers: frontiers) { caches, globalLayers, frontier in
            guard let state = try MiMoStagePrefixSnapshot.capture(caches: caches, globalLayers: globalLayers,
                                                                  frontier: frontier) else { return nil }
            // Every frontier is charged a full window per sliding layer: a tail
            // taken before the prompt filled the window is shorter than every
            // later one, and this cost also stands for the stage's later
            // requests (`QwenStagePrefixCache.record`: the first one stands).
            let tails = try MiMoStagePrefixSnapshot.windowTailBytes(state.sliding, caches: caches,
                                                                     globalLayers: globalLayers)
            return (shared: state.full, own: state.sliding.mapValues { (conv: $0.keys, ssm: $0.values) },
                    ownChargeBytes: tails)
        }
    }
}
