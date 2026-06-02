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
    /// Per-layer reference KV shape `[kvHeads, headDim]` captured from the
    /// live `model.newCache()`. REQUIRED for heterogeneous models (e.g.
    /// Gemma-4 interleaves sliding `[8,256]` and full `[2,512]` layers); the
    /// scalar `kvHeads`/`headDim` above cannot describe them and would make
    /// the load-time shape guard reject the model's own files. nil ⇒ fall
    /// back to the scalar check (uniform models / older callers / tests).
    public let layerShapes: [[Int]]?

    public init(
        modelHash: String, modelDtype: String, modelArch: String, vocabSize: Int,
        numLayers: Int, kvHeads: Int, headDim: Int, layerShapes: [[Int]]? = nil
    ) {
        self.modelHash = modelHash
        self.modelDtype = modelDtype
        self.modelArch = modelArch
        self.vocabSize = vocabSize
        self.numLayers = numLayers
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.layerShapes = layerShapes
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
    public var diskEvictions = 0
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
    /// On-disk budget (bytes) for this model's persisted checkpoints. After
    /// each flush, LRU entries (file + index entry together) are evicted to
    /// stay under it, so the SSD tier and index.json are both bounded under
    /// sustained diverse traffic. 0 = unbounded (not recommended in prod).
    private let diskBudgetBytes: Int
    private let now: @Sendable () -> Int64

    private var stats = PrefixCacheManagerStats()

    /// Digests currently being written by an in-flight flushToSSD. The
    /// capture hook fires one detached `Task { store; flushToSSD }` per
    /// checkpoint, so multiple flushToSSD run concurrently on this actor and
    /// interleave at the `await` inside the write loop. Without this guard
    /// two of them can both pass the "already persisted?" check for the same
    /// digest and redundantly serialize+encrypt+fsync the same (large) blob.
    /// Actor-isolated, so check-and-insert before the await is atomic.
    private var inFlightWrites: Set<String> = []
    /// Writes accumulated since the last index.save(), to amortize the O(N)
    /// full-index re-encode + atomic write + fsync away from every flush.
    private var unsavedWrites = 0
    /// Save the index after this many new writes (or on shutdown/idle flush).
    private static let saveCoalesceThreshold = 8

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
        diskBudgetBytes: Int = 0,
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
        self.diskBudgetBytes = max(0, diskBudgetBytes)
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
            // Truncated/corrupt header (e.g. crash mid-write): drop BOTH the
            // index entry AND the unusable file, so it can't linger on disk
            // (leaking + escaping the budget) and be re-read every lookup.
            try? FileManager.default.removeItem(at: fileURL)
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            return nil
        }
        // The model-dir path is reconstructed from THIS model's binding, so a
        // mismatching file here is genuinely stale/wrong for this model (e.g.
        // a weight change under the same id) — drop the file too, not just the
        // index entry, so it can't linger and escape the disk budget.
        guard meta.modelHash == binding.modelHash else {
            stats.modelMismatches += 1
            logger.warning("MB-1: prefix file model mismatch — dropping entry \(entry.digestHex, privacy: .public)")
            try? FileManager.default.removeItem(at: fileURL)
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            return nil
        }
        guard meta.numLayers == binding.numLayers,
              meta.kvHeads == binding.kvHeads,
              meta.headDim == binding.headDim else {
            stats.shapeMismatches += 1
            try? FileManager.default.removeItem(at: fileURL)
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
            try? FileManager.default.removeItem(at: fileURL)
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
            // Per-layer shape validation for heterogeneous models (Gemma-4);
            // fall back to the scalar check when no per-layer reference.
            if let layerShapes = binding.layerShapes {
                try KVCacheSerializer.validateLayout(layout, layerShapes: layerShapes)
            } else {
                try KVCacheSerializer.validateLayout(
                    layout, kvHeads: binding.kvHeads, headDim: binding.headDim)
            }
            caches = try KVCacheSerializer.deserialize(chunks: chunks, layout: layout)
        } catch {
            stats.ssdReadErrors += 1
            logger.warning("SSD prefix read failed for \(entry.digestHex, privacy: .public): \(String(describing: error))")
            // Drop BOTH the index entry AND the unusable file (corrupt,
            // truncated, KEK-unwrap failure) so it can't linger on disk
            // forever consuming the budget and being re-read every lookup.
            try? FileManager.default.removeItem(at: fileURL)
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
            // Skip entries already persisted OR being written right now by a
            // concurrent flush (reentrancy: the dedup check + the write are
            // separated by an await, so without the in-flight set two flushes
            // would both serialize+encrypt+fsync the same large blob).
            if index.entry(modelHash: binding.modelHash, digestHex: digestHex) != nil { continue }
            if inFlightWrites.contains(digestHex) { continue }
            // Only serialize SSD-capable stacks (defensive; ssdEnabled
            // should already guarantee this for the model).
            guard KVCacheSerializer.areSupported(snap.caches) else { continue }

            inFlightWrites.insert(digestHex)
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
            inFlightWrites.remove(digestHex)
        }

        if written > 0 {
            stats.ssdFlushes += written
            enforceDiskBudget(index: index, cacheDir: cacheDir)
            // Coalesce the O(N) full-index re-encode + atomic write + fsync:
            // saving on EVERY flush head-of-line-blocks lookups on this actor
            // and is amplified by concurrent flushes. Save once per
            // threshold; flushIndexNow() forces a save on idle/shutdown.
            unsavedWrites += written
            if unsavedWrites >= Self.saveCoalesceThreshold {
                // Only reset on a successful save; a transient I/O failure
                // (ENOSPC/EACCES) must keep the counter so the next flush —
                // or teardown — retries rather than dropping durability.
                if (try? index.save()) != nil { unsavedWrites = 0 }
            }
        }
        return written
    }

    /// Force-persist the index if there are unsaved writes (call on idle /
    /// before teardown so coalesced entries aren't lost). The in-memory RAM
    /// tier already serves them this session; this is durability across
    /// restart for the entries written since the last coalesced save.
    public func flushIndexNow() {
        guard ssdEnabled, let index else { return }
        if unsavedWrites > 0 || index.isDirty {
            // Only clear the unsaved counter if the save actually succeeded;
            // otherwise a transient ENOSPC/EACCES would silently lose
            // durability tracking and leave entries permanently unpersisted.
            if (try? index.save()) != nil { unsavedWrites = 0 }
        }
    }

    /// Reconcile the on-disk `.darkbloom-kv` files with the index, ONCE at
    /// startup. Two directions, both needed for crash-consistency:
    ///   • files present but NOT in the index (orphans from a crash inside
    ///     the save-coalescing window, or a corrupt/missing index.json) are
    ///     re-indexed by reading their plaintext metadata header (no decrypt)
    ///     and validating model + prefix-hash binding — so they count toward
    ///     the disk budget AND are reusable instead of leaking forever;
    ///   • index entries whose file is missing are dropped.
    /// Files that fail header read / model-mismatch / prefix-hash mismatch
    /// are deleted (unusable). Best-effort; never throws. Call ONCE right
    /// after construction, before any flush/lookup, from the async setup path.
    public func reconcileWithDisk() {
        guard ssdEnabled, let index, let cacheDir else { return }
        let modelDir = cacheDir.appendingPathComponent(modelDirComponent, isDirectory: true)
        let fm = FileManager.default
        let suffix = ".\(EncryptedKVStore.fileExtension)"

        // Drop index entries whose backing file vanished.
        for entry in index.entries(modelHash: binding.modelHash) {
            let url = modelDir.appendingPathComponent("\(entry.digestHex)\(suffix)")
            if !fm.fileExists(atPath: url.path) {
                index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            }
        }

        // Re-index (or delete) on-disk files.
        guard let names = try? fm.contentsOfDirectory(atPath: modelDir.path) else {
            flushIndexNow(); return
        }
        for name in names where name.hasSuffix(suffix) && !name.contains(".\(EncryptedKVStore.tempInfix)") {
            let digestHex = String(name.dropLast(suffix.count))
            if index.entry(modelHash: binding.modelHash, digestHex: digestHex) != nil { continue }
            let url = modelDir.appendingPathComponent(name)
            // Validate via the unauthenticated metadata header (cheap; the
            // real decrypt-time MB-1 + prefix-hash + AAD checks still gate
            // any later serve). Re-index only files that match this model
            // and whose stored prefix hash equals the filename digest.
            guard let meta = try? EncryptedKVStore.readMetadataOnly(from: url),
                  meta.modelHash == binding.modelHash,
                  meta.numLayers == binding.numLayers,
                  meta.kvHeads == binding.kvHeads,
                  meta.headDim == binding.headDim,
                  meta.tokenPrefixHash == digestHex
            else {
                try? fm.removeItem(at: url)  // foreign / corrupt / mislabeled
                continue
            }
            let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            index.record(PrefixIndexEntry(
                modelHash: binding.modelHash, digestHex: digestHex,
                tokenCount: meta.tokenCount,
                relativePath: "\(modelDirComponent)/\(name)",
                fileBytes: bytes ?? 0, createdAt: meta.createdAt, lastHitAt: now()))
        }
        // Apply the budget to the reconciled set, then persist.
        enforceDiskBudget(index: index, cacheDir: cacheDir)
        flushIndexNow()
    }

    /// Evict least-recently-hit checkpoints (file + index entry together)
    /// until this model's on-disk usage is within `diskBudgetBytes`. Without
    /// this, sustained diverse-prompt traffic grows the SSD cache and
    /// index.json without bound and can fill the volume. 0 budget = no cap.
    private func enforceDiskBudget(index: PrefixCacheIndex, cacheDir: URL) {
        guard diskBudgetBytes > 0 else { return }
        var total = index.bytes(modelHash: binding.modelHash)
        guard total > diskBudgetBytes else { return }
        for entry in index.entriesLRUFirst(modelHash: binding.modelHash) {
            if total <= diskBudgetBytes { break }
            let url = cacheDir.appendingPathComponent(
                "\(modelDirComponent)/\(entry.digestHex).\(EncryptedKVStore.fileExtension)")
            try? FileManager.default.removeItem(at: url)
            index.remove(modelHash: binding.modelHash, digestHex: entry.digestHex)
            // The RAM tier keeps its own byte/entry LRU budget; a now-stale
            // RAM copy just serves from memory (no SSD file needed), so we
            // don't force-evict it here — only the on-disk footprint is bounded.
            total -= max(0, entry.fileBytes)
            stats.diskEvictions += 1
        }
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
