import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Specification for a unified KV cache that may quantize keys and/or values
/// after a token threshold, using MLX's affine quantization.
public struct KVQuantCacheSpec: Sendable, Equatable {
    public let bits: Int
    public let groupSize: Int
    public let startToken: Int
    public let quantizeKeys: Bool
    public let quantizeValues: Bool

    public init(
        bits: Int,
        groupSize: Int,
        startToken: Int,
        quantizeKeys: Bool,
        quantizeValues: Bool
    ) {
        self.bits = bits
        self.groupSize = groupSize
        self.startToken = startToken
        self.quantizeKeys = quantizeKeys
        self.quantizeValues = quantizeValues
    }
}

extension KVQuantCandidateMode {
    /// Cache spec for this mode, or `nil` when no quantization is requested.
    public var cacheSpec: KVQuantCacheSpec? {
        switch self {
        case .fp16KV, .bf16KV, .fullVBF16:
            return nil
        case .affine4:
            return KVQuantCacheSpec(
                bits: 4, groupSize: 64, startToken: 1024,
                quantizeKeys: true, quantizeValues: true)
        case .affine8:
            return KVQuantCacheSpec(
                bits: 8, groupSize: 64, startToken: 1024,
                quantizeKeys: true, quantizeValues: true)
        case .fullVAffine4:
            return KVQuantCacheSpec(
                bits: 4, groupSize: 64, startToken: 1024,
                quantizeKeys: false, quantizeValues: true)
        case .fullVTurbo4, .fullKVTurbo4, .turbo4v2:
            // These are experimental; fall back to the affine scalar path for now.
            return KVQuantCacheSpec(
                bits: 4, groupSize: 64, startToken: 1024,
                quantizeKeys: false, quantizeValues: true)
        case .k8v8g128:
            return KVQuantCacheSpec(
                bits: 8, groupSize: 128, startToken: 0,
                quantizeKeys: true, quantizeValues: true)
        case .k8v8g64, .k8v8g64Dequant:
            return KVQuantCacheSpec(
                bits: 8, groupSize: 64, startToken: 0,
                quantizeKeys: true, quantizeValues: true)
        case .k6v6g64:
            return KVQuantCacheSpec(
                bits: 6, groupSize: 64, startToken: 0,
                quantizeKeys: true, quantizeValues: true)
        case .k6v6g64Dequant:
            return KVQuantCacheSpec(
                bits: 6, groupSize: 64, startToken: 0,
                quantizeKeys: true, quantizeValues: true)
        }
    }
}

/// A model-agnostic KV cache that stores keys/values in fp16 until
/// ``startToken`` tokens have been seen, then converts to affine quantization.
///
/// This is intentionally simpler than upstream's `QuantizedKVCache` path:
/// it works for both K+V and V-only quantization, respects a start delay,
/// and is usable for single-forward scoring as well as autoregressive
/// generation. The trade-off is that it dequantizes values on every read,
/// so it is not the fastest path for generation-heavy workloads.
public final class KVQuantizedCache: KVCache {
    public let spec: KVQuantCacheSpec

    public private(set) var offset: Int = 0
    public var maxSize: Int? { nil }

    private let step = 256

    // fp16 buffers used before conversion.
    private var keyBuffer: KVCacheSimple?
    private var valueBuffer: KVCacheSimple?

    // Quantized state used after conversion.
    private var keyQuantized: (MLXArray, MLXArray, MLXArray?)?
    private var valueQuantized: (MLXArray, MLXArray, MLXArray?)?

    private var converted = false

    public init(spec: KVQuantCacheSpec) {
        self.spec = spec
        self.keyBuffer = KVCacheSimple()
        self.valueBuffer = KVCacheSimple()
    }

    public func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        offset += keys.dim(2)

        if !converted {
            // Accumulate in fp16 until we cross the start threshold.
            _ = keyBuffer?.update(keys: keys, values: values)
            _ = valueBuffer?.update(keys: keys, values: values)

            if offset > spec.startToken {
                convert()
            }

            if converted {
                return (dequantizedKeys(), dequantizedValues())
            } else {
                return (keysFromBuffer(), valuesFromBuffer())
            }
        }

        // Already converted: append to the quantized store and return dequantized tensors.
        if spec.quantizeKeys {
            appendAndQuantize(keys, to: &keyQuantized)
        } else {
            _ = keyBuffer?.update(keys: keys, values: values)
        }

        if spec.quantizeValues {
            appendAndQuantize(values, to: &valueQuantized)
        } else {
            _ = valueBuffer?.update(keys: keys, values: values)
        }

        return (dequantizedKeys(), dequantizedValues())
    }

    private func keysFromBuffer() -> MLXArray {
        guard let keyBuffer else { return dequantizedKeys() }
        let state = keyBuffer.state
        guard state.count >= 1 else { return dequantizedKeys() }
        return state[0][.ellipsis, ..<offset, 0...]
    }

    private func valuesFromBuffer() -> MLXArray {
        guard let valueBuffer else { return dequantizedValues() }
        let state = valueBuffer.state
        guard state.count >= 2 else { return dequantizedValues() }
        return state[1][.ellipsis, ..<offset, 0...]
    }

    private func convert() {
        if spec.quantizeKeys {
            if let keyBuffer, keyBuffer.state.count >= 1 {
                keyQuantized = quantize(keyBuffer.state[0][.ellipsis, ..<offset, 0...])
            }
            self.keyBuffer = nil
        }

        if spec.quantizeValues {
            if let valueBuffer, valueBuffer.state.count >= 2 {
                valueQuantized = quantize(valueBuffer.state[1][.ellipsis, ..<offset, 0...])
            }
            self.valueBuffer = nil
        }

        converted = true
    }

    private func appendAndQuantize(_ tensor: MLXArray, to quantState: inout (MLXArray, MLXArray, MLXArray?)?) {
        let previous = dequantized(state: quantState)
        let combined = concatenated([previous, tensor], axis: 2)
        quantState = quantize(combined)
    }

    private func quantize(_ tensor: MLXArray) -> (MLXArray, MLXArray, MLXArray?) {
        let q = quantized(tensor, groupSize: spec.groupSize, bits: spec.bits)
        return (q.wq, q.scales, q.biases)
    }

    private func dequantizedKeys() -> MLXArray {
        if spec.quantizeKeys {
            return dequantized(state: keyQuantized)
        } else {
            return keysFromBuffer()
        }
    }

    private func dequantizedValues() -> MLXArray {
        if spec.quantizeValues {
            return dequantized(state: valueQuantized)
        } else {
            return valuesFromBuffer()
        }
    }

    private func dequantized(state: (MLXArray, MLXArray, MLXArray?)?) -> MLXArray {
        guard let state else { return MLXArray.zeros([0]) }
        return MLX.dequantized(
            state.0,
            scales: state.1,
            biases: state.2,
            groupSize: spec.groupSize,
            bits: spec.bits
        )
    }

    public var isTrimmable: Bool { true }

    @discardableResult
    public func trim(_ n: Int) -> Int {
        let trimmed = min(offset, n)
        offset -= trimmed

        if converted {
            if spec.quantizeKeys {
                keyQuantized = quantize(dequantized(state: keyQuantized)[.ellipsis, ..<offset, 0...])
            }
            if spec.quantizeValues {
                valueQuantized = quantize(dequantized(state: valueQuantized)[.ellipsis, ..<offset, 0...])
            }
        }

        keyBuffer?.trim(n)
        valueBuffer?.trim(n)
        return trimmed
    }

    public func copy() -> any KVCache {
        let copy = KVQuantizedCache(spec: spec)
        copy.offset = offset
        copy.converted = converted

        if let keyBuffer {
            copy.keyBuffer = keyBuffer.copy() as? KVCacheSimple
        }
        if let valueBuffer {
            copy.valueBuffer = valueBuffer.copy() as? KVCacheSimple
        }

        if let keyQuantized {
            copy.keyQuantized = treeMap({ $0[.ellipsis] }, keyQuantized)
        }
        if let valueQuantized {
            copy.valueQuantized = treeMap({ $0[.ellipsis] }, valueQuantized)
        }

        return copy
    }

    public var state: [MLXArray] {
        get { innerState() }
        set {
            fatalError("KVQuantizedCache state mutation is not implemented")
        }
    }

    public func innerState() -> [MLXArray] {
        var arrays: [MLXArray] = []
        if let keyBuffer {
            arrays.append(contentsOf: keyBuffer.innerState())
        }
        if let valueBuffer {
            arrays.append(contentsOf: valueBuffer.innerState())
        }
        if let keyQuantized {
            arrays.append(contentsOf: [keyQuantized.0, keyQuantized.1, keyQuantized.2].compactMap { $0 })
        }
        if let valueQuantized {
            arrays.append(contentsOf: [valueQuantized.0, valueQuantized.1, valueQuantized.2].compactMap { $0 })
        }
        return arrays
    }

    public var metaState: [String] {
        get {
            [
                String(spec.bits),
                String(spec.groupSize),
                String(spec.startToken),
                spec.quantizeKeys ? "1" : "0",
                spec.quantizeValues ? "1" : "0",
                converted ? "1" : "0",
                String(offset),
            ]
        }
        set {
            fatalError("KVQuantizedCache metaState mutation is not implemented")
        }
    }

    public func makeMask(
        n: Int,
        windowSize: Int?,
        returnArray: Bool
    ) -> MLXFast.ScaledDotProductAttentionMaskMode {
        if n == 1 {
            return .none
        }
        if returnArray || (windowSize != nil && n > windowSize!) {
            return .array(createCausalMask(n: n, offset: offset, windowSize: windowSize))
        }
        return .causal
    }

    // MARK: - Tree-map helpers for quantized tuples

    private func treeMap<T>(
        _ transform: (MLXArray) -> T,
        _ tuple: (MLXArray, MLXArray, MLXArray?)
    ) -> (T, T, T?) {
        if let biases = tuple.2 {
            return (transform(tuple.0), transform(tuple.1), transform(biases))
        } else {
            return (transform(tuple.0), transform(tuple.1), nil)
        }
    }
}
