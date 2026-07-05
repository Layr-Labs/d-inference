import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// KV cache that stores keys in fp16 and values in affine quantization.
///
/// This conforms to ``KVCache`` (not ``QuantizedKVCacheProtocol``) so model
/// attention uses the regular ``MLXFast/scaledDotProductAttention`` path. On
/// ``update(keys:values:)`` the returned keys are the full-precision cached keys
/// and the returned values are dequantized from internal affine-quantized
/// storage.
///
/// Values are kept in full precision until the cache offset reaches
/// ``startToken``, at which point the accumulated values are converted to
/// quantized storage. Subsequent updates quantize new values immediately. This
/// mirrors the timing behavior of mlx-swift-lm's dynamic KV cache quantization.
final class VOnlyQuantizedKVCache: KVCache, CustomDebugStringConvertible {
    var offset: Int = 0
    var maxSize: Int? { nil }

    private var keys: MLXArray?
    private var valueWeight: MLXArray?
    private var valueScales: MLXArray?
    private var valueBiases: MLXArray?
    private var unquantizedValues: MLXArray?

    let groupSize: Int
    let bits: Int
    let startToken: Int
    let mode: QuantizationMode

    private let step: Int

    init(
        groupSize: Int = 64,
        bits: Int = 4,
        startToken: Int = 0,
        mode: QuantizationMode = .affine
    ) {
        self.groupSize = groupSize
        self.bits = bits
        self.startToken = startToken
        self.mode = mode
        self.step = 256
    }

    func innerState() -> [MLXArray] {
        var arrays: [MLXArray] = []
        if let keys = keys {
            arrays.append(keys[.ellipsis, ..<offset, 0...])
        }
        if let unquantized = unquantizedValues {
            arrays.append(unquantized[.ellipsis, ..<offset, 0...])
        }
        if let wq = valueWeight {
            arrays.append(wq[.ellipsis, ..<offset, 0...])
            arrays.append(valueScales![.ellipsis, ..<offset, 0...])
            if let biases = valueBiases {
                arrays.append(biases[.ellipsis, ..<offset, 0...])
            }
        }
        return arrays
    }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        let B = keys.dim(0)
        let nKVHeads = keys.dim(1)
        let numSteps = keys.dim(2)
        let kHeadDim = keys.dim(3)
        let vHeadDim = values.dim(3)
        let prev = offset

        expandKeyBuffer(
            B: B,
            nKVHeads: nKVHeads,
            numSteps: numSteps,
            kHeadDim: kHeadDim,
            dtype: keys.dtype,
            prev: prev
        )

        let willBeQuantized = prev >= startToken
        if willBeQuantized {
            ensureQuantizedValueStorage(
                B: B,
                nKVHeads: nKVHeads,
                numSteps: numSteps,
                vHeadDim: vHeadDim,
                dtype: values.dtype,
                prev: prev
            )
        } else {
            ensureUnquantizedValueStorage(
                B: B,
                nKVHeads: nKVHeads,
                numSteps: numSteps,
                vHeadDim: vHeadDim,
                dtype: values.dtype,
                prev: prev
            )
        }

        offset += numSteps

        // Store keys.
        self.keys![.ellipsis, prev ..< offset, 0...] = keys

        // Store values and return the full cached values (dequantized when needed).
        let returnedValues: MLXArray
        if willBeQuantized {
            let q = quantized(values, groupSize: groupSize, bits: bits, mode: mode)
            valueWeight![.ellipsis, prev ..< offset, 0...] = q.wq
            valueScales![.ellipsis, prev ..< offset, 0...] = q.scales
            if let biases = q.biases {
                valueBiases![.ellipsis, prev ..< offset, 0...] = biases
            }
            returnedValues = dequantized(
                valueWeight![.ellipsis, ..<offset, 0...],
                scales: valueScales![.ellipsis, ..<offset, 0...],
                biases: valueBiases?[.ellipsis, ..<offset, 0...],
                groupSize: groupSize,
                bits: bits,
                mode: mode
            )
        } else {
            unquantizedValues![.ellipsis, prev ..< offset, 0...] = values
            returnedValues = unquantizedValues![.ellipsis, ..<offset, 0...]

            // Crossed the start threshold: convert accumulated values to quantized storage.
            if offset >= startToken {
                let q = quantized(returnedValues, groupSize: groupSize, bits: bits, mode: mode)
                valueWeight = q.wq
                valueScales = q.scales
                valueBiases = q.biases
                unquantizedValues = nil
            }
        }

        return (self.keys![.ellipsis, ..<offset, 0...], returnedValues)
    }

    private func expandKeyBuffer(
        B: Int,
        nKVHeads: Int,
        numSteps: Int,
        kHeadDim: Int,
        dtype: DType,
        prev: Int
    ) {
        guard self.keys == nil || (prev + numSteps) > self.keys!.dim(2) else { return }

        let newSteps = ((step + numSteps - 1) / step) * step
        let kShape = [B, nKVHeads, newSteps, kHeadDim]
        let newK = MLXArray.zeros(kShape, dtype: dtype)

        if var currentKeys = self.keys {
            if prev % step != 0 {
                currentKeys = currentKeys[.ellipsis, ..<prev, 0...]
            }
            self.keys = concatenated([currentKeys, newK], axis: 2)
        } else {
            self.keys = newK
        }
    }

    private func ensureQuantizedValueStorage(
        B: Int,
        nKVHeads: Int,
        numSteps: Int,
        vHeadDim: Int,
        dtype: DType,
        prev: Int
    ) {
        guard valueWeight == nil || (prev + numSteps) > valueWeight!.dim(2) else { return }

        let newSteps = ((step + numSteps - 1) / step) * step
        let shape = [B, nKVHeads, newSteps]

        if var wq = valueWeight, var scales = valueScales {
            if prev % step != 0 {
                wq = wq[.ellipsis, ..<prev, 0...]
                scales = scales[.ellipsis, ..<prev, 0...]
                valueBiases = valueBiases.map { $0[.ellipsis, ..<prev, 0...] }
            }

            let emptyWeight = MLXArray.zeros(shape + [wq.dim(-1)], dtype: wq.dtype)
            let emptyScales = MLXArray.zeros(shape + [scales.dim(-1)], dtype: scales.dtype)
            valueWeight = concatenated([wq, emptyWeight], axis: -2)
            valueScales = concatenated([scales, emptyScales], axis: -2)

            if let biases = valueBiases {
                let emptyBiases = MLXArray.zeros(shape + [biases.dim(-1)], dtype: biases.dtype)
                valueBiases = concatenated([biases, emptyBiases], axis: -2)
            }
        } else {
            let source: MLXArray
            if let unquantized = unquantizedValues {
                source = unquantized[.ellipsis, ..<prev, 0...]
            } else {
                source = MLXArray.zeros(shape + [vHeadDim], dtype: dtype)
            }

            let q = quantized(source, groupSize: groupSize, bits: bits, mode: mode)
            valueWeight = q.wq
            valueScales = q.scales
            valueBiases = q.biases
            unquantizedValues = nil
        }
    }

    private func ensureUnquantizedValueStorage(
        B: Int,
        nKVHeads: Int,
        numSteps: Int,
        vHeadDim: Int,
        dtype: DType,
        prev: Int
    ) {
        guard unquantizedValues == nil || (prev + numSteps) > unquantizedValues!.dim(2) else {
            return
        }

        let newSteps = ((step + numSteps - 1) / step) * step
        let vShape = [B, nKVHeads, newSteps, vHeadDim]
        let newV = MLXArray.zeros(vShape, dtype: dtype)

        if var current = unquantizedValues {
            if prev % step != 0 {
                current = current[.ellipsis, ..<prev, 0...]
            }
            unquantizedValues = concatenated([current, newV], axis: 2)
        } else {
            unquantizedValues = newV
        }
    }

    var state: [MLXArray] {
        get { innerState() }
        set {
            // Serialization is not required for the benchmark gate.
            fatalError("VOnlyQuantizedKVCache state deserialization is not implemented")
        }
    }

    var metaState: [String] {
        get {
            [
                String(step),
                String(offset),
                String(groupSize),
                String(bits),
                String(startToken),
            ]
        }
        set {
            fatalError("VOnlyQuantizedKVCache metaState deserialization is not implemented")
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
        let new = VOnlyQuantizedKVCache(
            groupSize: groupSize,
            bits: bits,
            startToken: startToken,
            mode: mode
        )
        new.offset = offset
        if let keys = keys {
            new.keys = keys[.ellipsis]
        }
        if let unquantized = unquantizedValues {
            new.unquantizedValues = unquantized[.ellipsis]
        }
        if let wq = valueWeight {
            new.valueWeight = wq[.ellipsis]
            new.valueScales = valueScales![.ellipsis]
            new.valueBiases = valueBiases?[.ellipsis]
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
        "VOnlyQuantizedKVCache(offset: \(offset), groupSize: \(groupSize), bits: \(bits), start: \(startToken))"
    }
}
