/// EncryptedPrefixCachePersistence — the encrypted, on-SSD backend for
/// the engine's in-GPU block prefix cache (design Path 2). Conforms to
/// `MLXLMCommon.PrefixCachePersistence`: the engine calls `saveBlock`
/// when it evicts an LRU block and `loadBlock` on a block-hash miss, so
/// evicted blocks are encrypted to disk (surviving eviction AND process
/// restart) instead of being dropped and re-prefilled.
///
/// SECURITY (TB-007): enabling the engine prefix cache reintroduces a
/// cross-tenant data-leak / TTFT-side-channel risk. The provider cannot
/// see tenant identity, so this cache is shared across consumers on the
/// provider. This backend adds encryption-AT-REST (disk theft defense)
/// but does NOT close the in-process cross-tenant sharing/timing
/// channel. Gated behind a default-off flag; ships only with an explicit
/// threat-model sign-off. See docs/ssd-kv-cache-design.md.
///
/// Synchronous by contract (`PrefixCachePersistence` runs in the engine
/// step loop): the KEK is unwrapped ONCE at setup (async) and held as a
/// `SymmetricKey`; save/load then use `EncryptedKVStore.writeSync/
/// readSync` + `KVCacheSerializer` with no actor hops.
///
/// Keying: files are content-addressed by the engine's block hash
/// (`<hashHex>.darkbloom-kv`) inside a per-model directory. Only
/// `KVCacheSimple` blocks are persisted (the engine's prefix cache is
/// KVCacheSimple-only anyway; rotating/recurrent are out of scope here).
///
/// MB-1: `loadBlock` verifies the file's `metadata.modelHash` and shape
/// match this model before trusting it (a wrong-model file decrypts
/// cleanly otherwise — the AAD is its own metadata).

import CryptoKit
import Foundation
import MLXLMCommon
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "encrypted-prefix-persistence")

public final class EncryptedPrefixCachePersistence: PrefixCachePersistence, @unchecked Sendable {
    // All stored properties are immutable after init; the only side
    // effects are independent file reads/writes — hence @unchecked
    // Sendable is sound (no shared mutable state).
    private let kekKey: SymmetricKey
    private let dir: URL
    private let binding: PrefixCacheModelBinding

    public init(kekKey: SymmetricKey, dir: URL, binding: PrefixCacheModelBinding) {
        self.kekKey = kekKey
        self.dir = dir
        self.binding = binding
    }

    // MARK: - PrefixCachePersistence

    public func saveBlock(blockHash: Data, layerCaches: [KVCacheSimple]) {
        let caches = layerCaches as [any KVCache]
        guard KVCacheSerializer.areSupported(caches) else { return }

        do {
            let (chunks, layout) = try KVCacheSerializer.serialize(caches)
            let layoutJSON = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
            let tokenCount = layerCaches.first?.state.first?.dim(2) ?? 0
            let meta = EncryptedKVStoreMetadata(
                modelHash: binding.modelHash,
                modelDtype: binding.modelDtype,
                modelArch: binding.modelArch,
                vocabSize: binding.vocabSize,
                numLayers: binding.numLayers,
                kvHeads: binding.kvHeads,
                headDim: binding.headDim,
                tokenCount: tokenCount,
                tokenPrefixHash: blockHash.dbkvHexString,
                kvCacheClass: "KVCache",
                metaState: [layoutJSON],
                chunkPlaintextSizes: chunks.map { $0.count }
            )
            try EncryptedKVStore.writeSync(to: fileURL(blockHash), metadata: meta, chunks: chunks, kekKey: kekKey)
        } catch {
            // Best-effort: a lost block just means a future cold prefill.
            logger.warning("saveBlock failed for \(blockHash.dbkvHexString, privacy: .public): \(String(describing: error))")
        }
    }

    public func loadBlock(blockHash: Data) -> [KVCacheSimple]? {
        let url = fileURL(blockHash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // MB-1: validate metadata BEFORE decrypt.
        let meta: EncryptedKVStoreMetadata
        do {
            meta = try EncryptedKVStore.readMetadataOnly(from: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard meta.modelHash == binding.modelHash,
              meta.numLayers == binding.numLayers,
              meta.kvHeads == binding.kvHeads,
              meta.headDim == binding.headDim else {
            logger.warning("MB-1: block file model/shape mismatch — dropping \(blockHash.dbkvHexString, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // Prefix binding: the file authenticates under its OWN metadata
        // (AAD), so MB-1's model/shape check can't tell that a same-model
        // file holds a DIFFERENT prompt prefix (renamed/swapped file, hash
        // collision). Require the file's prefix hash to equal the requested
        // block hash, or treat it as a cold miss — never serve another
        // prefix's KV.
        guard meta.tokenPrefixHash == blockHash.dbkvHexString else {
            logger.warning("block file prefix-hash mismatch — refusing \(blockHash.dbkvHexString, privacy: .public)")
            return nil
        }

        do {
            let (readMeta, chunks) = try EncryptedKVStore.readSync(from: url, kekKey: kekKey)
            guard let layoutJSON = readMeta.metaState.first,
                  let layout = try? JSONDecoder().decode(KVCacheLayout.self, from: Data(layoutJSON.utf8)) else {
                return nil
            }
            let caches = try KVCacheSerializer.deserialize(chunks: chunks, layout: layout)
            // The engine's block cache is KVCacheSimple-only; every layer
            // must downcast or we refuse the whole block.
            let simple = caches.compactMap { $0 as? KVCacheSimple }
            guard simple.count == caches.count else { return nil }
            return simple
        } catch {
            logger.warning("loadBlock decrypt failed for \(blockHash.dbkvHexString, privacy: .public): \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Paths

    private func fileURL(_ blockHash: Data) -> URL {
        dir.appendingPathComponent("\(blockHash.dbkvHexString).\(EncryptedKVStore.fileExtension)")
    }
}
