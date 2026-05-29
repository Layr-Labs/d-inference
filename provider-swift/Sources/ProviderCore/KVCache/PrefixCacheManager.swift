/// PrefixCacheManager — orchestrates the three-tier prefix KV cache
/// (design §4, phase P3). One manager per loaded model, owned by the
/// BatchScheduler (the BatchScheduler wiring itself is the next step and
/// is NOT in this file — this is the standalone, fully-testable
/// orchestration layer).
///
/// Tiers, in lookup order:
///   1. RAM  — decrypted `[any KVCache]` (PrefixCacheRAM), keyed by
///             (modelHash, checkpoint digest).
///   2. SSD  — encrypted `.darkbloom-kv` files (EncryptedKVStore),
///             located via PrefixCacheIndex; promoted to RAM on hit.
///   3. miss — caller runs a cold prefill.
///
/// EXACT-CHECKPOINT (design §4.4): lookup matches only when the incoming
/// prompt's prefix is byte-identical to a cached checkpoint boundary
/// (PrefixDigest). The longest matching checkpoint wins.
///
/// MB-1 model-binding guard (design §8.1.1): the RAM tier is keyed by
/// modelHash (structural). The SSD tier additionally verifies
/// `metadata.modelHash == binding.modelHash` AND the architectural shape
/// (numLayers/kvHeads/headDim) BEFORE unwrapping/decrypting — because a
/// structurally-valid cache file from the wrong model decrypts cleanly
/// (the AAD is the file's own metadata). On mismatch the entry is
/// dropped and the caller falls through to cold prefill.
///
/// PCR-1 (Sendable across the actor boundary): `lookup` returns and
/// `store` accepts the non-Sendable `[any KVCache]` via `sending` — the
/// caches handed out are fresh copies/reconstructions (no aliasing of
/// actor-isolated state), and stored caches are sent in (caller gives up
/// the region), so region-based isolation makes this sound.
///
/// SSD capability: only models whose layer caches are
/// KVCacheSerializer-supported (KVCacheSimple/RotatingKVCache — Gemma-4,
/// GPT-OSS, pure-attention) get the SSD tier. Hybrid recurrent models
/// (Qwen3.5/Next) run RAM-tier only; `ssdEnabled = false` disables the
/// SSD read/flush paths for them.

import Foundation
import MLXLMCommon
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "prefix-cache-manager")

// MARK: - Model binding

public struct PrefixCacheModelBinding: Sendable {
    public let modelHash: String
    public let modelDtype: String
    public let modelArch: String
    public let vocabSize: Int
    public let numLayers: Int
    public let kvHeads: Int
    public let headDim: Int

    public init(
        modelHash: String, modelDtype: String, modelArch: String, vocabSize: Int,
        numLayers: Int, kvHeads: Int, headDim: Int
    ) {
        self.modelHash = modelHash
        self.modelDtype = modelDtype
        self.modelArch = modelArch
        self.vocabSize = vocabSize
        self.numLayers = numLayers
        self.kvHeads = kvHeads
        self.headDim = headDim
    }
}

// MARK: - Result

/// `@unchecked Sendable` is justified, NOT a sidestep: the `caches`
/// handed out are always FRESH — RAM hits return `copy()` of the stored
/// caches, SSD hits are freshly deserialized — and the manager never
/// retains a reference to them after returning. A lookup result has a
/// single owner (the requesting inference task), so there is no shared
/// mutable state to race on. (`sending` would be the pure-Swift-6 way,
/// but values produced via the actor-isolated `PrefixCacheRAM` are
/// inferred into the actor's region and can't be `sending`-returned;
/// the whole KV subsystem traffics in non-Sendable MLXArrays, so this
/// matches the existing `UncheckedSendable*` idiom in the codebase.)
public struct PrefixLookupResult: @unchecked Sendable {
    /// One cache per layer, ready to seed a batch row. Caller owns these.
    public let caches: [any KVCache]
    /// Prompt tokens covered by the snapshot — caller skips prefill on
    /// `tokens[0..<tokenCount]`.
    public let tokenCount: Int
    /// Which tier served it (telemetry).
    public let tier: PrefixCacheTier
}

/// Ownership-transfer box for handing freshly-extracted caches INTO the
/// manager. The caller (BatchScheduler) extracts caches via
/// `extractBatched` and transfers ownership — it MUST NOT mutate them
/// after boxing. `@unchecked Sendable` for the same reason as
/// `PrefixLookupResult`: single-owner, no shared mutable state.
public struct SendableKVCaches: @unchecked Sendable {
    public let caches: [any KVCache]
    public init(_ caches: [any KVCache]) { self.caches = caches }
}

public enum PrefixCacheTier: String, Sendable {
    case ram, ssd, miss
}

// MARK: - Stats

public struct PrefixCacheManagerStats: Sendable, Equatable {
    public var ramHits = 0
    public var ssdHits = 0
    public var misses = 0
    public var stores = 0
    public var ssdFlushes = 0
    public var modelMismatches = 0
    public var shapeMismatches = 0
    public var prefixHashMismatches = 0
    public var ssdReadErrors = 0
}

// MARK: - Manager

public actor PrefixCacheManager {

    private let binding: PrefixCacheModelBinding
    private let ram: PrefixCacheRAM
    private let index: PrefixCacheIndex?
    private let kek: KVCacheKEK?
    private let cacheDir: URL?
    private let ssdEnabled: Bool
    private let boundaries: [Int]
    private let now: @Sendable () -> Int64

    private var stats = PrefixCacheManagerStats()

    /// 12-char model-hash prefix used as the per-model SSD subdirectory.
    private var modelDirComponent: String {
        String(binding.modelHash.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }

    public init(
        binding: PrefixCacheModelBinding,
        ram: PrefixCacheRAM,
        index: PrefixCacheIndex? = nil,
        kek: KVCacheKEK? = nil,
        cacheDir: URL? = nil,
        ssdEnabled: Bool,
        boundaries: [Int] = PrefixDigest.defaultCheckpoints,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.binding = binding
        self.ram = ram
        self.index = index
        self.kek = kek
        self.cacheDir = cacheDir
        // SSD requires all three backing pieces; otherwise RAM-only.
        self.ssdEnabled = ssdEnabled && index != nil && kek != nil && cacheDir != nil
        self.boundaries = boundaries
        self.now = now
    }

    public var isSSDEnabled: Bool { ssdEnabled }
    public func snapshotStats() -> PrefixCacheManagerStats { stats }

    // MARK: - Lookup

    /// Find the longest cached checkpoint whose prefix is byte-identical
    /// to `tokens`. RAM first, then SSD (with the MB-1 guard). Returns
    /// fresh, caller-owned caches via `sending`, or nil on miss.
    public func lookup(tokens: [Int]) async -> PrefixLookupResult? {
        let checkpoints = PrefixDigest.checkpoints(tokens: tokens, boundaries: boundaries)
        guard !checkpoints.isEmpty else {
            stats.misses += 1
            return nil
        }

        // RAM tier: longest checkpoint first.
        for cp in checkpoints.reversed() {
            if let hit = ram.get(modelHash: binding.modelHash, digest: cp.digest) {
                stats.ramHits += 1
                return PrefixLookupResult(caches: hit.caches, tokenCount: hit.tokenCount, tier: .ram)
            }
        }

        // SSD tier.
        if ssdEnabled, let result = await loadFromSSD(tokens: tokens) {
            stats.ssdHits += 1
            return result
        }

        stats.misses += 1
        return nil
    }

    private func loadFromSSD(tokens: [Int]) async -> PrefixLookupResult? {
        guard let index, let kek, let cacheDir else { return nil }
        guard let entry = index.findLongestCheckpoint(
            modelHash: binding.modelHash, tokens: tokens, boundaries: boundaries
        ) else { return nil }

        // Path safety: the on-disk index JSON is plaintext and NOT
        // authenticated, so a tampered entry.relativePath could contain
        // "../" and escape cacheDir (an out-of-sandbox read). The path is
        // written deterministically by flushToSSD, so reconstruct it from
        // the trusted model binding + the index key (entry.digestHex, which
        // findLongestCheckpoint already matched against a computed pure-hex
        // digest) instead of trusting the stored path.
        let relPath = "\(modelDirComponent)/\(entry.digestHex).\(EncryptedKVStore.fileExtension)"
        let fileURL = cacheDir.appendingPathComponent(relPath)

        // MB-1: validate metadata BEFORE unwrap/decrypt. A wrong-model
        // file decrypts cleanly (AAD is its own metadata), so the cipher
        // can't catch this — the equality check must.
        let meta: EncryptedKVStoreMetadata
        do {
            meta = try EncryptedKVStore.readMetadataOnly(from: fileURL)
        } catch {
            stats.ssdReadErrors += 1
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            return nil
        }
        guard meta.modelHash == binding.modelHash else {
            stats.modelMismatches += 1
            logger.warning("MB-1: prefix file model mismatch — dropping entry \(entry.digestHex, privacy: .public)")
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            return nil
        }
        guard meta.numLayers == binding.numLayers,
              meta.kvHeads == binding.kvHeads,
              meta.headDim == binding.headDim else {
            stats.shapeMismatches += 1
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            return nil
        }
        // Prefix binding: the file authenticates under its OWN metadata, so
        // a stale/corrupt index entry (or a same-model file at the wrong
        // path) would otherwise decrypt cleanly and return KV for a
        // DIFFERENT prompt prefix. Require the file's prefix hash to match
        // the index entry's digest, or drop it and cold-prefill.
        guard meta.tokenPrefixHash == entry.digestHex else {
            stats.prefixHashMismatches += 1
            logger.warning("SSD prefix-hash mismatch (index stale/corrupt) — dropping \(entry.digestHex, privacy: .public)")
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            return nil
        }

        // Decrypt + deserialize.
        let caches: [any KVCache]
        do {
            let (readMeta, chunks) = try await EncryptedKVStore.read(from: fileURL, kek: kek)
            guard let layoutJSON = readMeta.metaState.first,
                  let layout = try? JSONDecoder().decode(
                    KVCacheLayout.self, from: Data(layoutJSON.utf8)) else {
                throw KVCacheSerializerError.reconstructionFailed("missing/invalid layout in metaState")
            }
            // Bind the actual KV tensor shapes (not just the metadata
            // integers) to the live model before seeding attention.
            try KVCacheSerializer.validateLayout(
                layout, kvHeads: binding.kvHeads, headDim: binding.headDim)
            caches = try KVCacheSerializer.deserialize(chunks: chunks, layout: layout)
        } catch {
            stats.ssdReadErrors += 1
            logger.warning("SSD prefix read failed for \(entry.digestHex, privacy: .public): \(String(describing: error))")
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            return nil
        }

        // Promote to RAM for the next hit, and bump index recency.
        if let digestData = Data(hex: entry.digestHex) {
            ram.put(
                modelHash: binding.modelHash, digest: digestData,
                caches: caches.map { $0.copy() }, tokenCount: entry.tokenCount
            )
        }
        index.touch(modelHash: binding.modelHash, digestHex: entry.digestHex, now: now())

        return PrefixLookupResult(caches: caches, tokenCount: entry.tokenCount, tier: .ssd)
    }

    // MARK: - Store

    /// Store a freshly-extracted snapshot in the RAM tier, keyed by the
    /// checkpoint digest of `tokens[0..<checkpointLength]`. SSD
    /// persistence happens later via `flushToSSD` (write-back).
    public func store(tokens: [Int], checkpointLength: Int, caches: SendableKVCaches) {
        guard checkpointLength > 0, checkpointLength <= tokens.count else { return }
        let digest = PrefixDigest.digest(tokens: tokens, length: checkpointLength)
        ram.put(
            modelHash: binding.modelHash, digest: digest,
            caches: caches.caches, tokenCount: checkpointLength
        )
        stats.stores += 1
    }

    // MARK: - Flush (write-back to SSD)

    /// Serialize RAM-tier entries for this model that aren't already on
    /// SSD, encrypt them, and record them in the index. Best-effort: a
    /// per-entry failure is logged and skipped. No-op when SSD disabled.
    /// Returns the number of entries newly written.
    @discardableResult
    public func flushToSSD() async -> Int {
        guard ssdEnabled, let index, let kek, let cacheDir else { return 0 }

        var written = 0
        for snap in ram.entriesForFlush(modelHash: binding.modelHash) {
            let digestHex = snap.key.digest.dbkvHexString
            // Skip entries already persisted.
            if index.entry(modelHash: binding.modelHash, digestHex: digestHex) != nil { continue }
            // Only serialize SSD-capable stacks (defensive; ssdEnabled
            // should already guarantee this for the model).
            guard KVCacheSerializer.areSupported(snap.caches) else { continue }

            do {
                let (chunks, layout) = try KVCacheSerializer.serialize(snap.caches)
                let layoutJSON = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
                let relativePath = "\(modelDirComponent)/\(digestHex).\(EncryptedKVStore.fileExtension)"
                let fileURL = cacheDir.appendingPathComponent(relativePath)
                let meta = EncryptedKVStoreMetadata(
                    modelHash: binding.modelHash,
                    modelDtype: binding.modelDtype,
                    modelArch: binding.modelArch,
                    vocabSize: binding.vocabSize,
                    numLayers: binding.numLayers,
                    kvHeads: binding.kvHeads,
                    headDim: binding.headDim,
                    tokenCount: snap.tokenCount,
                    tokenPrefixHash: digestHex,
                    kvCacheClass: "mixed",
                    metaState: [layoutJSON],
                    chunkPlaintextSizes: chunks.map { $0.count },
                    createdAt: now()
                )
                try await EncryptedKVStore.write(to: fileURL, metadata: meta, chunks: chunks, kek: kek)

                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileBytes = (attrs?[.size] as? Int) ?? 0
                index.record(PrefixIndexEntry(
                    modelHash: binding.modelHash, digestHex: digestHex,
                    tokenCount: snap.tokenCount, relativePath: relativePath,
                    fileBytes: fileBytes, createdAt: now(), lastHitAt: now()
                ))
                written += 1
            } catch {
                logger.warning("flushToSSD: failed to persist \(digestHex, privacy: .public): \(String(describing: error))")
            }
        }

        if written > 0 {
            stats.ssdFlushes += written
            try? index.save()
        }
        return written
    }

    // MARK: - Clear

    public func clearRAM() {
        ram.clear(modelHash: binding.modelHash)
    }
}

// MARK: - Hex decode

extension Data {
    /// Decode a lowercase/uppercase hex string. Returns nil on odd
    /// length or a non-hex character.
    init?(hex: String) {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self = Data(bytes)
    }
}
