/// Gemma4ShardAdapter -- bridges the fork's `Gemma4PipelineShard` to
/// ProviderCore's `PipelineModelShard`, so a Gemma 4 model runs across the
/// cluster through the SAME engine/decode/transport/encryption path as Llama
/// and GPT-OSS.
///
/// Mirror of `GPTOSSShardAdapter`. Additive: selecting the architecture is done
/// by the caller (ClusterHeadBringup) from config.json's `model_type`.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

public final class Gemma4ShardAdapter: PipelineModelShard, @unchecked Sendable {
    private let shard: Gemma4PipelineShard
    public let totalLayers: Int
    public let ownedInterval: LayerInterval
    private var kvCaches: [KVCache]?
    private var batchedCaches: [KVCache]?

    public init(shard: Gemma4PipelineShard, ownedInterval: LayerInterval) {
        self.shard = shard
        self.totalLayers = shard.range.totalLayers
        self.ownedInterval = ownedInterval
    }

    public static func load(directory: URL, interval: LayerInterval) throws -> Gemma4ShardAdapter {
        let (shard, _) = try Gemma4PipelineShardLoader.loadFromDirectory(
            directory, start: interval.start, end: interval.end)
        return Gemma4ShardAdapter(shard: shard, ownedInterval: interval)
    }

    // MARK: - PipelineModelShard

    public func embed(tokens: [Int]) -> MLXArray {
        let ids = MLXArray(tokens.map { Int32($0) }, [1, tokens.count])
        return shard.embed(ids)
    }

    public func runOwnedLayers(_ hidden: MLXArray) -> MLXArray {
        shard.runOwnedLayers(hidden, cache: caches(), evalEvery: 4)
    }

    public func projectToLogits(_ hidden: MLXArray) -> MLXArray {
        shard.projectToLogits(hidden)
    }

    // MARK: - Batched path

    public func embedBatch(rows: [[Int]], leftPadding: [Int]) -> MLXArray {
        let maxLen = rows.map(\.count).max() ?? 0
        var flat = [Int32]()
        flat.reserveCapacity(rows.count * maxLen)
        for (b, row) in rows.enumerated() {
            let pad = leftPadding.indices.contains(b) ? leftPadding[b] : (maxLen - row.count)
            flat.append(contentsOf: repeatElement(Int32(0), count: pad))
            flat.append(contentsOf: row.map { Int32($0) })
            let filled = pad + row.count
            if filled < maxLen { flat.append(contentsOf: repeatElement(Int32(0), count: maxLen - filled)) }
        }
        let ids = MLXArray(flat, [rows.count, maxLen])
        return shard.embed(ids)
    }

    public func runOwnedLayersBatched(_ hidden: MLXArray) -> MLXArray {
        shard.runOwnedLayers(hidden, cache: batchedCaches ?? [], evalEvery: 4)
    }

    public func projectToLogitsBatched(_ hidden: MLXArray) -> MLXArray {
        shard.projectToLogits(hidden)
    }

    public func beginBatch(leftPadding: [Int]) {
        batchedCaches = shard.makeBatchedCaches(leftPadding: leftPadding)
    }

    public func filterBatch(keepIndices: [Int]) {
        guard let caches = batchedCaches else { return }
        let idx = MLXArray(keepIndices.map { Int32($0) }, [keepIndices.count])
        for c in caches { (c as? BatchedCache)?.filterBatched(batchIndices: idx) }
    }

    public func admitPrefill(_ hidden: MLXArray, leftPadding: [Int]) -> MLXArray {
        let admitted = shard.makeBatchedCaches(leftPadding: leftPadding)
        let out = shard.runOwnedLayers(hidden, cache: admitted, evalEvery: 4)
        if let live = batchedCaches {
            for (i, c) in live.enumerated() where i < admitted.count {
                if let bc = c as? BatchedCache, let other = admitted[i] as? BatchedCache {
                    bc.extendBatched(other)
                }
            }
        }
        return out
    }

    private func caches() -> [KVCache] {
        if let kvCaches { return kvCaches }
        // Single-stream (B=1) path: one KVCacheSimple per owned layer, exactly
        // like the GPT-OSS adapter. Gemma 4's sliding-window layers stay correct
        // because `runOwnedLayers` applies the windowSize-restricted mask per
        // layer type; the cache just retains keys (no memory cap), which is fine
        // for the short single-stream generations this path serves.
        let made = (0 ..< shard.ownedLayerCount).map { _ in KVCacheSimple() as KVCache }
        kvCaches = made
        return made
    }
}
