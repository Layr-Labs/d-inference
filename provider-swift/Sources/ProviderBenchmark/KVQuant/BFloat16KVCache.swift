import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// KV cache that stores keys and values in bfloat16 instead of fp16.
///
/// This reduces the KV-cache footprint by roughly 2x and works with any model
/// attention that calls ``update(keys:values:)``, including Gemma 4's custom
/// attention path (which does not support ``QuantizedKVCache``).
///
/// Tokens before ``startToken`` are kept in the original dtype so that the
/// prompt prefix and any attention sinks stay at full precision; after the
/// threshold the accumulated cache is cast to bfloat16 and subsequent updates
/// are stored as bfloat16.
final class BFloat16KVCache: KVCache, CustomDebugStringConvertible {
    var offset: Int = 0
    var maxSize: Int? { nil }

    private var keys: MLXArray?
    private var values: MLXArray?
    private let startToken: Int
    private let step: Int

    init(startToken: Int = 0) {
        self.startToken = startToken
        self.step = 256
    }

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        let B = newKeys.dim(0)
        let nKVHeads = newKeys.dim(1)
        let numSteps = newKeys.dim(2)
        let kHeadDim = newKeys.dim(3)
        let vHeadDim = newValues.dim(3)
        let prev = offset

        let storageDtype: DType = prev >= startToken ? .bfloat16 : newKeys.dtype

        expandBuffer(
            B: B,
            nHeads: nKVHeads,
            numSteps: numSteps,
            headDim: kHeadDim,
            prev: prev,
            storage: &keys,
            dtype: storageDtype
        )
        expandBuffer(
            B: B,
            nHeads: nKVHeads,
            numSteps: numSteps,
            headDim: vHeadDim,
            prev: prev,
            storage: &values,
            dtype: storageDtype
        )

        offset += numSteps

        let keysToStore = storageDtype == .bfloat16 ? newKeys.asType(.bfloat16) : newKeys
        let valuesToStore = storageDtype == .bfloat16 ? newValues.asType(.bfloat16) : newValues

        keys![.ellipsis, prev ..< offset, 0...] = keysToStore
        values![.ellipsis, prev ..< offset, 0...] = valuesToStore

        // Crossed the start threshold: cast the accumulated cache to bfloat16.
        if prev < startToken && offset >= startToken {
            keys = keys!.asType(.bfloat16)
            values = values!.asType(.bfloat16)
        }

        return (
            keys![.ellipsis, ..<offset, 0...],
            values![.ellipsis, ..<offset, 0...]
        )
    }

    private func expandBuffer(
        B: Int,
        nHeads: Int,
        numSteps: Int,
        headDim: Int,
        prev: Int,
        storage: inout MLXArray?,
        dtype: DType
    ) {
        guard storage == nil || (prev + numSteps) > storage!.dim(2) else { return }

        let newSteps = ((step + numSteps - 1) / step) * step
        let shape = [B, nHeads, newSteps, headDim]
        let newBuffer = MLXArray.zeros(shape, dtype: dtype)

        if var current = storage {
            if prev % step != 0 {
                current = current[.ellipsis, ..<prev, 0...]
            }
            storage = concatenated([current, newBuffer], axis: 2)
        } else {
            storage = newBuffer
        }
    }

    func innerState() -> [MLXArray] {
        var arrays: [MLXArray] = []
        if let keys = keys {
            arrays.append(keys[.ellipsis, ..<offset, 0...])
        }
        if let values = values {
            arrays.append(values[.ellipsis, ..<offset, 0...])
        }
        return arrays
    }

    var state: [MLXArray] {
        get { innerState() }
        set {
            fatalError("BFloat16KVCache state deserialization is not implemented")
        }
    }

    var metaState: [String] {
        get {
            [
                String(step),
                String(offset),
                String(startToken),
            ]
        }
        set {
            fatalError("BFloat16KVCache metaState deserialization is not implemented")
        }
    }

    var isTrimmable: Bool { true }

    @discardableResult
    func trim(_ n: Int) -> Int {
        let trimmed = min(offset, n)
        offset -= trimmed
        return trimmed
    }

    func copy() -> any KVCache {
        let new = BFloat16KVCache(startToken: startToken)
        new.offset = offset
        if let keys = keys {
            new.keys = keys[.ellipsis]
        }
        if let values = values {
            new.values = values[.ellipsis]
        }
        return new
    }

    func makeMask(
        n: Int, windowSize: Int?, returnArray: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        if n == 1 {
            return .none
        }
        if returnArray || (windowSize != nil && n > windowSize!) {
            return .array(createCausalMask(n: n, offset: offset, windowSize: windowSize))
        }
        return .causal
    }

    var debugDescription: String {
        "BFloat16KVCache(offset=\(offset), startToken=\(startToken))"
    }
}
