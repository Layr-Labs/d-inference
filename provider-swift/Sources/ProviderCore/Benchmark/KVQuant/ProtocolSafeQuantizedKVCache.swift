import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// A `QuantizedKVCacheProtocol`-conforming wrapper around upstream
/// ``QuantizedKVCache`` that also implements ``KVCache/update(keys:values:)``.
///
/// Upstream ``QuantizedKVCache`` fatal-errors when ``update(keys:values:)`` is
/// called, which makes it unusable for models/attentions that invoke the plain
/// update path (including the benchmark's single-forward PPL/logits scorer and
/// Gemma 4's pre-conversion attention flow). This wrapper forwards the efficient
/// ``updateQuantized(keys:values:)`` path to the upstream cache and provides a
/// dequantizing fallback for ``update(keys:values:)``.
///
/// Because the wrapper conforms to ``QuantizedKVCacheProtocol``, models that
/// detect quantized caches (e.g. Gemma 4 and the standard
/// ``attentionWithCacheUpdate`` path) will use the native quantized attention
/// kernel. Models that do not detect the protocol will receive dequantized
/// fp16 keys/values from the fallback ``update``.
final class ProtocolSafeQuantizedKVCache: QuantizedKVCacheProtocol, KVCache,
    CustomDebugStringConvertible
{
    public let groupSize: Int
    public let bits: Int
    public let mode: QuantizationMode

    var offset: Int {
        get { inner.offset }
        set { inner.offset = newValue }
    }

    var maxSize: Int? { inner.maxSize }

    private let inner: QuantizedKVCache

    init(groupSize: Int = 64, bits: Int = 8, mode: QuantizationMode = .affine) {
        self.groupSize = groupSize
        self.bits = bits
        self.mode = mode
        self.inner = QuantizedKVCache(groupSize: groupSize, bits: bits, mode: mode)
    }

    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        let (quantizedKeys, quantizedValues) = inner.updateQuantized(keys: keys, values: values)

        let dequantizedKeys = dequantized(
            quantizedKeys.0,
            scales: quantizedKeys.1,
            biases: quantizedKeys.2,
            groupSize: groupSize,
            bits: bits,
            mode: mode
        )
        let dequantizedValues = dequantized(
            quantizedValues.0,
            scales: quantizedValues.1,
            biases: quantizedValues.2,
            groupSize: groupSize,
            bits: bits,
            mode: mode
        )

        return (dequantizedKeys, dequantizedValues)
    }

    func updateQuantized(keys: MLXArray, values: MLXArray) -> (
        (MLXArray, MLXArray, MLXArray?), (MLXArray, MLXArray, MLXArray?)
    ) {
        inner.updateQuantized(keys: keys, values: values)
    }

    func getQuantizedState() -> (
        (MLXArray, MLXArray, MLXArray?), (MLXArray, MLXArray, MLXArray?)
    )? {
        inner.getQuantizedState()
    }

    func innerState() -> [MLXArray] {
        inner.innerState()
    }

    var state: [MLXArray] {
        get { inner.state }
        set { inner.state = newValue }
    }

    var metaState: [String] {
        get { inner.metaState }
        set { inner.metaState = newValue }
    }

    var isTrimmable: Bool { inner.isTrimmable }

    @discardableResult
    func trim(_ n: Int) -> Int {
        inner.trim(n)
    }

    func copy() -> any KVCache {
        let copiedInner = inner.copy() as! QuantizedKVCache
        let new = ProtocolSafeQuantizedKVCache(
            groupSize: groupSize,
            bits: bits,
            mode: mode
        )
        new.inner.state = copiedInner.state
        new.inner.metaState = copiedInner.metaState
        new.offset = copiedInner.offset
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
        "ProtocolSafeQuantizedKVCache(offset=\(offset), groupSize=\(groupSize), bits=\(bits))"
    }
}
