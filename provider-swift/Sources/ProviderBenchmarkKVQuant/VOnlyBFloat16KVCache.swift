import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// KV cache that keeps keys in fp16 and stores values in bfloat16.
///
/// This is a middle-ground compression option: it cuts the value-cache
/// footprint in half (roughly a 25% total KV-cache reduction) while leaving
/// the key cache at full precision, which usually preserves top-token
/// agreement better than quantizing both. Like ``BFloat16KVCache``, it works
/// with model attentions that call ``update(keys:values:)`` directly, so it
/// is compatible with Gemma 4's custom attention path.
///
/// Tokens before ``startToken`` are kept in the original dtype; after the
/// threshold the accumulated values are cast to bfloat16 and subsequent
/// value updates are stored as bfloat16.
final class VOnlyBFloat16KVCache: KVCache, CustomDebugStringConvertible {
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

        let valuesDtype: DType = prev >= startToken ? .bfloat16 : newValues.dtype

        expandBuffer(
            B: B,
            nHeads: nKVHeads,
            numSteps: numSteps,
            headDim: kHeadDim,
            prev: prev,
            storage: &keys,
            dtype: newKeys.dtype
        )
        expandBuffer(
            B: B,
            nHeads: nKVHeads,
            numSteps: numSteps,
            headDim: vHeadDim,
            prev: prev,
            storage: &self.values,
            dtype: valuesDtype
        )

        offset += numSteps

        keys![.ellipsis, prev ..< offset, 0...] = newKeys
        let valuesToStore = valuesDtype == .bfloat16 ? newValues.asType(.bfloat16) : newValues
        values![.ellipsis, prev ..< offset, 0...] = valuesToStore

        // Crossed the start threshold: cast the accumulated values to bfloat16.
        if prev < startToken && offset >= startToken {
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
            fatalError("VOnlyBFloat16KVCache state deserialization is not implemented")
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
            fatalError("VOnlyBFloat16KVCache metaState deserialization is not implemented")
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
        let new = VOnlyBFloat16KVCache(startToken: startToken)
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
        "VOnlyBFloat16KVCache(offset=\(offset), startToken=\(startToken))"
    }
}
