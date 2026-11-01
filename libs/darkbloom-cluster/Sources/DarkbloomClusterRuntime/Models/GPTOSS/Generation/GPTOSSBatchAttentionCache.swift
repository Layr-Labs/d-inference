import MLX
import MLXLLM
import MLXLMCommon

/// One decode forward's view of a layer's request-owned pages. Projections
/// share a native batch, while attention reads each request in the same
/// physical ring order as the one-request GPT-OSS path. There is no padding,
/// shared frontier, storage migration or persistent concatenated KV buffer.
/// The owning sessions retain their pages and retire them only after a fence.
final class GPTOSSBatchAttentionCache: GPTOSSPerRowAttentionCache {
    private let requests: [GPTOSSPagedKVCache]
    private let before: [Int]
    let positionOffsets: MLXArray
    var scalarPositionOffsets: [Int] { before }
    private var updated = false

    init(_ requests: [GPTOSSPagedKVCache]) throws {
        guard (1...8).contains(requests.count),
              Set(requests.map(ObjectIdentifier.init)).count == requests.count,
              let first = requests.first,
              requests.allSatisfy({ $0.maxSize == first.maxSize && $0.offset >= 0 && $0.offset < Int(Int32.max) }) else {
            throw ProbeError("GPT-OSS batch cache requires distinct compatible bounded request histories")
        }
        self.requests = requests
        before = requests.map(\.offset)
        positionOffsets = MLXArray(before.map(Int32.init))
    }

    func updateAndAttend(queries: MLXArray, keys: MLXArray, values: MLXArray,
                         scale: Float, sinks: MLXArray?) -> MLXArray {
        precondition(!updated && requests.map(\.offset) == before,
            "GPT-OSS batch cache is one decode step and cannot reuse advanced histories")
        precondition(queries.ndim == 4 && keys.ndim == 4 && values.ndim == 4
            && queries.dim(0) == requests.count && keys.dim(0) == requests.count && values.dim(0) == requests.count
            && queries.dim(2) == 1 && keys.dim(2) == 1 && values.dim(2) == 1
            && queries.dtype == keys.dtype && keys.dtype == values.dtype)
        updated = true
        let output = requests.enumerated().map { index, cache in
            let mask = cache.makeMask(n: 1, windowSize: cache.maxSize, returnArray: false)
            let (k, v) = cache.update(keys: keys[index..<(index + 1)], values: values[index..<(index + 1)])
            return MLXFast.scaledDotProductAttention(queries: queries[index..<(index + 1)],
                keys: k, values: v, scale: scale, mask: mask, sinks: sinks)
        }
        return concatenated(output, axis: 0)
    }

    var offset: Int { requests.map(\.offset).max() ?? 0 }
    var maxSize: Int? { requests.first?.maxSize }
    func innerState() -> [MLXArray] { [positionOffsets] + requests.flatMap { $0.innerState() } }
    func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
        preconditionFailure("GPT-OSS batch attention owns KV updates")
    }
    var state: [MLXArray] {
        get { [] }
        set { preconditionFailure("GPT-OSS batch views do not own serializable request state") }
    }
    var metaState: [String] {
        get { [] }
        set { preconditionFailure("GPT-OSS batch views do not own request metadata") }
    }
    var isTrimmable: Bool { false }
    func trim(_ n: Int) -> Int { 0 }
    func makeMask(n: Int, windowSize: Int?, returnArray: Bool) -> MLXFast.ScaledDotProductAttentionMaskMode {
        preconditionFailure("GPT-OSS batch attention owns each request's mask")
    }
    func copy() -> any KVCache {
        preconditionFailure("GPT-OSS batch views cannot duplicate request ownership")
    }
}
