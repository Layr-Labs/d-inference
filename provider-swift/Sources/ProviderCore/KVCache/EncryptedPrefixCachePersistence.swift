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
    // The crypto/path properties are immutable after init. The only mutable
    // state is the disk-budget bookkeeping (`bytesSinceSweep`), guarded by
    // `sweepLock` — so @unchecked Sendable remains sound (all shared mutable
    // access is serialized through the lock).
    private let kekKey: SymmetricKey
    private let dir: URL
    private let binding: PrefixCacheModelBinding

    /// On-disk byte budget for this model's `.darkbloom-kv` files. When a
    /// save pushes the directory over budget, the oldest files are evicted.
    /// 0 = unlimited (no sweep). Without this the cache grows until the
    /// volume fills, which breaks later cache writes and model downloads.
    private let diskBudgetBytes: Int
    private let sweepLock = NSLock()
    private var bytesSinceSweep = 0

    public init(
        kekKey: SymmetricKey, dir: URL, binding: PrefixCacheModelBinding,
        diskBudgetBytes: Int = 0
    ) {
        self.kekKey = kekKey
        self.dir = dir
        self.binding = binding
        self.diskBudgetBytes = max(0, diskBudgetBytes)
    }

    // MARK: - PrefixCachePersistence

    public func saveBlock(blockHash: Data, layerCaches: [KVCacheSimple]) {
        let caches = layerCaches as [any KVCache]
        guard KVCacheSerializer.areSupported(caches) else { return }

        do {
            let (chunks, layout) = try KVCacheSerializer.serialize(caches)
            // If this block alone exceeds the disk budget, the sweep would
            // delete it immediately after writing — skip the expensive
            // encrypt+fsync+rename rather than churn (write-then-delete).
            // (chunkBytes is plaintext; the file is slightly larger, so a
            // file at/under budget still passes and is handled by the sweep.)
            if diskBudgetBytes > 0 {
                let chunkBytes = chunks.reduce(0) { $0 + $1.count }
                if chunkBytes > diskBudgetBytes { return }
            }
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
            let url = fileURL(blockHash)
            try EncryptedKVStore.writeSync(to: url, metadata: meta, chunks: chunks, kekKey: kekKey)
            let written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            enforceDiskBudgetIfNeeded(addedBytes: written ?? 0)
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
        // collision). This check detects an on-disk rename — the file at
        // path <blockHash> must claim to be <blockHash> (saveBlock writes
        // tokenPrefixHash == the file's own name). The substantive content
        // binding is the GCM AAD (bytes <-> metadata) plus the shape
        // validation below (bytes <-> live model); this guard closes the
        // path<->claim gap on top of those.
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
            // Bind the actual KV tensor shapes to the live model before
            // seeding attention (metadata integers alone don't bind bytes).
            try KVCacheSerializer.validateLayout(
                layout, kvHeads: binding.kvHeads, headDim: binding.headDim)
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

    // MARK: - Disk budget (LRU sweep)

    /// Accumulate the just-written bytes and trigger a full scan+evict only
    /// once we've added a meaningful fraction of the budget since the last
    /// sweep — amortizing the directory scan over many writes rather than
    /// scanning on every block. No-op when the budget is unlimited (0).
    private func enforceDiskBudgetIfNeeded(addedBytes: Int) {
        guard diskBudgetBytes > 0 else { return }
        sweepLock.lock()
        bytesSinceSweep += max(0, addedBytes)
        let trigger = bytesSinceSweep >= max(addedBytes, diskBudgetBytes / 8)
        sweepLock.unlock()
        guard trigger else { return }
        sweep()
    }

    /// Evict oldest `.darkbloom-kv` files (by modification time) until the
    /// directory is within `diskBudgetBytes`. Best-effort.
    private func sweep() {
        sweepLock.lock()
        defer { sweepLock.unlock() }
        bytesSinceSweep = 0
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: Int, mtime: Date)] = []
        var total = 0
        let suffix = ".\(EncryptedKVStore.fileExtension)"
        for u in entries where u.lastPathComponent.hasSuffix(suffix) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let size = v?.fileSize ?? 0
            files.append((u, size, v?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > diskBudgetBytes else { return }

        for f in files.sorted(by: { $0.mtime < $1.mtime }) {
            if total <= diskBudgetBytes { break }
            if (try? fm.removeItem(at: f.url)) != nil { total -= f.size }
        }
        logger.info("prefix cache disk sweep: now \(total) bytes (budget \(self.diskBudgetBytes))")
    }

    // MARK: - Paths

    private func fileURL(_ blockHash: Data) -> URL {
        dir.appendingPathComponent("\(blockHash.dbkvHexString).\(EncryptedKVStore.fileExtension)")
    }
}
