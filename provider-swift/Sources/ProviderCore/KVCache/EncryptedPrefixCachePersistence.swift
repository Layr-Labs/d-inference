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

public final class EncryptedPrefixCachePersistence: PrefixCachePersistence, PrefixCacheOwner, @unchecked Sendable {
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
    /// Phase 3: when accountant != nil, this is set to 0 (unbounded) so the
    /// two budgets never fight — accountant is sole authority.
    private let diskBudgetBytes: Int
    private let sweepLock = NSLock()
    private var bytesSinceSweep = 0
    /// Bytes written since the last usage push to the accountant.
    /// Accumulates under sweepLock; pushed when >= threshold.
    private var bytesSincePush = 0

    /// Set true by `close()` on model unload (BatchScheduler.stopCurrentEngine),
    /// BEFORE the accountant deregisters this owner. Once closed, every disk
    /// mutator (saveBlock, loadBlock's drop-on-mismatch, sweep, evictForGlobal
    /// Budget, usage pushes) is a no-op, so a stale engine step that finishes
    /// after unload — `EngineCore.stop()` does not fence an in-flight
    /// `engineQueue` step — or a late accountant eviction signal cannot mutate
    /// files in a `kv/<modelKey>` dir a freshly-reloaded same-modelKey owner may
    /// now hold. Mirrors PrefixCacheManager's `closed` latch (checkpoint tier).
    /// saveBlock/loadBlock are synchronous (PrefixCachePersistence contract), so
    /// no async drain is needed: a check-and-bail closes the window; an
    /// already-executing synchronous saveBlock just completes one content-
    /// addressed write (reclaimed by the new owner's sweep). Guarded by sweepLock.
    private var closed = false

    /// Phase 3: global disk accountant (process-wide, shared across models).
    /// nil ⇒ today's per-model behavior (backward compat).
    private let accountant: GlobalDiskAccountant?
    /// 12-char modelKey (sha256(modelId)[:12]) for accountant registration.
    /// Exposed as public so BatchScheduler can register this owner.
    public let modelKey: String
    /// Accountant registration token (set by BatchScheduler after
    /// register, cleared on deregister). Usage pushes must pass this token so
    /// stale detached Tasks (from an older load) are NO-OP.
    /// Thread-safe: reads are atomic (Optional is a value type), writes are
    /// guarded by sweepLock (setAccountantToken is always called on the same
    /// executor as register/deregister, so no race on the accountant itself).
    private var accountantToken: AccountantToken?

    public init(
        kekKey: SymmetricKey, dir: URL, binding: PrefixCacheModelBinding,
        diskBudgetBytes: Int = 0,
        accountant: GlobalDiskAccountant? = nil,
        modelKey: String = ""
    ) {
        self.kekKey = kekKey
        self.dir = dir
        self.binding = binding
        // Phase 3: when accountant != nil, set diskBudgetBytes to 0 (unbounded)
        // so the two budgets never fight — accountant is sole authority.
        self.diskBudgetBytes = accountant != nil ? 0 : max(0, diskBudgetBytes)
        self.accountant = accountant
        self.modelKey = modelKey
    }

    // MARK: - PrefixCachePersistence

    public func saveBlock(blockHash: Data, layerCaches: [KVCacheSimple]) {
        // Closed (model unloaded): a stale engine step must not write into a dir
        // a reloaded same-modelKey owner may now hold.
        guard !isClosed() else { return }
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
            // When accountant != nil, push usage to the accountant
            // (debounced) so enforceIfOverBudget can signal evictForGlobalBudget.
            // Otherwise (nil-accountant backward compat) use the local sweep.
            if let accountant {
                pushUsageToAccountantIfNeeded(addedBytes: written ?? 0, accountant: accountant)
            } else {
                enforceDiskBudgetIfNeeded(addedBytes: written ?? 0)
            }
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
            removeUnusableBlockFile(url)  // refresh accountant
            return nil
        }
        guard meta.modelHash == binding.modelHash,
              meta.numLayers == binding.numLayers,
              meta.kvHeads == binding.kvHeads,
              meta.headDim == binding.headDim else {
            logger.warning("MB-1: block file model/shape mismatch — dropping \(blockHash.dbkvHexString, privacy: .public)")
            removeUnusableBlockFile(url)  // refresh accountant
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

    /// Debounce-push usage to the accountant so engine-tier bytes
    /// are visible and enforceIfOverBudget can signal evictForGlobalBudget.
    /// Triggered by saveBlock (synchronous, no actor hops allowed), so the
    /// push is fire-and-forget. Scans the dir and builds an mtime-LRU summary
    /// (mirroring tick's degraded scoring for unowned dirs).
    /// Capture accountantToken under the lock and pass it to the
    /// detached push so stale Tasks (from an older load) are NO-OP.
    private func pushUsageToAccountantIfNeeded(addedBytes: Int, accountant: GlobalDiskAccountant) {
        sweepLock.lock()
        bytesSincePush += max(0, addedBytes)
        // Debounce threshold. When an accountant is attached, diskBudgetBytes is
        // forced to 0 (the accountant is the sole budget authority), so a
        // `diskBudgetBytes/8` debounce is unavailable — and a 64 MiB constant
        // would leave the FIRST ~64 MiB of every engine model (and any model
        // that never reaches 64 MiB) INVISIBLE to the global budget. Use a
        // small fixed 1 MiB cadence instead: the push is cheap (a dir scan + a
        // detached actor call) and prompt visibility matters more than debounce
        // savings. Without an accountant, keep the per-model `diskBudgetBytes/8`.
        let threshold = diskBudgetBytes > 0 ? diskBudgetBytes / 8 : 1 * 1024 * 1024
        let trigger = bytesSincePush >= threshold
        // Capture the token while holding the lock.
        let token = accountantToken
        sweepLock.unlock()
        guard trigger, let token else { return }

        let (total, summary) = buildUsageSnapshot()
        // Fire-and-forget push (saveBlock is synchronous on the engine step loop).
        // Pass the token so stale detached Tasks are NO-OP.
        Task.detached { [accountant, token, total, summary] in
            await accountant.updateUsage(token: token, totalBytes: total, valueSummary: summary)
        }
        // Reset the debounce counter after push.
        sweepLock.lock()
        bytesSincePush = 0
        sweepLock.unlock()
    }

    /// Scan the flat dir for `.darkbloom-kv` files → (totalBytes, mtime-LRU
    /// value summary). Shared by the debounced saveBlock push and the immediate
    /// post-eviction / post-registration publish.
    private func buildUsageSnapshot() -> (Int, [EntryValue]) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return (0, []) }
        var total = 0
        var summary: [EntryValue] = []
        let suffix = ".\(EncryptedKVStore.fileExtension)"
        let nowEpoch = Int64(Date().timeIntervalSince1970)
        for u in entries where u.lastPathComponent.hasSuffix(suffix) {
            let digestHex = String(u.lastPathComponent.dropLast(suffix.count))
            let v = try? u.resourceValues(forKeys: Set(keys))
            let size = v?.fileSize ?? 0
            total += size
            let mtime = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let age = Double(nowEpoch) - mtime
            let score = size > 0 ? (1.0 / max(1.0, age)) / Double(size) : 0.0
            summary.append(EntryValue(
                modelKey: modelKey, digestHex: digestHex, fileBytes: size, score: score, fileURL: nil))
        }
        return (total, summary)
    }

    /// Push CURRENT usage to the accountant immediately (no debounce). Called
    /// after a global-budget eviction (so runningTotals/valueSummaries reflect
    /// the post-eviction state — otherwise the accountant keeps re-selecting
    /// already-deleted ghosts and cascades the dir to empty) and right after
    /// registration (so a reloaded model's pre-existing flat files are accounted
    /// immediately, not invisible until a saveBlock crosses the debounce).
    /// Pass the token so stale Tasks are NO-OP.
    public func publishUsageNow() async {
        guard let accountant, let token = accountantToken else { return }
        let (total, summary) = buildUsageSnapshot()
        resetBytesSincePush()
        await accountant.updateUsage(token: token, totalBytes: total, valueSummary: summary)
    }

    /// Reset the debounce counter under the lock (sync — NSLock can't be held
    /// across an await, so callers in async contexts call this before/after).
    private func resetBytesSincePush() {
        sweepLock.lock(); bytesSincePush = 0; sweepLock.unlock()
    }

    /// Remove an unusable engine-tier block file (corrupt header
    /// or model/shape mismatch) discovered during loadBlock, and refresh the
    /// accountant so the deleted bytes stop being counted. This is the engine-tier
    /// analog of the checkpoint tier's dropUnusableSSDFile: tick() skips
    /// registered (owned) dirs, so without this push the accountant keeps the stale
    /// byte total until a later saveBlock crosses the debounce or the model reloads.
    /// loadBlock is synchronous (PrefixCachePersistence contract — no actor hops),
    /// so the push is fire-and-forget, token-scoped (stale Tasks are NO-OP), and the
    /// snapshot is rebuilt AFTER the removal so it reflects the smaller footprint.
    private func removeUnusableBlockFile(_ url: URL) {
        // Closed: a reloaded same-modelKey owner may now hold this dir, so a
        // stale loadBlock must not delete its files (cross-owner mutation).
        guard !isClosed() else { return }
        try? FileManager.default.removeItem(at: url)
        guard let accountant else { return }
        sweepLock.lock()
        let token = accountantToken
        sweepLock.unlock()
        guard let token else { return }
        let (total, summary) = buildUsageSnapshot()  // post-removal footprint
        Task.detached { [accountant, token, total, summary] in
            await accountant.updateUsage(token: token, totalBytes: total, valueSummary: summary)
        }
    }

    /// Store the accountant token (called by BatchScheduler after
    /// register). Thread-safe via sweepLock.
    public func setAccountantToken(_ token: AccountantToken?) {
        sweepLock.lock()
        accountantToken = token
        sweepLock.unlock()
    }

    /// Mark this owner closed on model unload. BatchScheduler must call this
    /// BEFORE `accountant.deregister(token)` so no disk mutation slips through
    /// between deregistration and the dir being handed to a reloaded owner.
    /// Idempotent; thread-safe via sweepLock.
    public func close() {
        sweepLock.lock()
        closed = true
        sweepLock.unlock()
    }

    /// Snapshot of the closed flag under the lock.
    private func isClosed() -> Bool {
        sweepLock.lock(); defer { sweepLock.unlock() }
        return closed
    }

    /// Evict oldest `.darkbloom-kv` files (by modification time) until the
    /// directory is within `diskBudgetBytes`. Best-effort.
    private func sweep() {
        sweepLock.lock()
        defer { sweepLock.unlock() }
        // Closed: don't delete files in a dir a reloaded owner may hold. (Read
        // `closed` directly — we already hold sweepLock, so isClosed() would
        // deadlock on the non-recursive NSLock.)
        guard !closed else { return }
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

    // MARK: - Phase 3: Global disk accountant integration

    /// PrefixCacheOwner conformance: evict oldest files (by mtime) to free at
    /// least `targetBytesToFree`. Returns bytes freed. Called by the global
    /// disk accountant when the process-wide disk budget is exceeded. Reuses
    /// the sweep loop body (mtime-LRU eviction). No locking needed: the
    /// accountant is the sole caller and serializes all evictions.
    public func evictForGlobalBudget(targetBytesToFree: Int) async -> Int {
        // Closed: a late accountant eviction signal (the accountant should have
        // deregistered this owner, but a signal already in flight could still
        // land) must not delete files in a dir a reloaded owner may now hold.
        guard !isClosed() else { return 0 }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return 0 }

        var files: [(url: URL, size: Int, mtime: Date)] = []
        let suffix = ".\(EncryptedKVStore.fileExtension)"
        for u in entries where u.lastPathComponent.hasSuffix(suffix) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let size = v?.fileSize ?? 0
            files.append((u, size, v?.contentModificationDate ?? .distantPast))
        }

        var freed = 0
        for f in files.sorted(by: { $0.mtime < $1.mtime }) {
            if freed >= targetBytesToFree { break }
            if (try? fm.removeItem(at: f.url)) != nil { freed += f.size }
        }

        // Reconcile the accountant with the post-eviction state.
        // The accountant (since the round-1 double-subtract fix) recomputes
        // globalTotal() after signaling and relies on the owner having refreshed
        // its runningTotals/valueSummaries. The checkpoint tier does this via
        // notifyAccountant(); the engine tier MUST too, or its stale summary
        // makes the accountant re-select already-deleted ghosts and cascade the
        // whole dir to empty (then stay phantom-over-budget).
        if freed > 0 { await publishUsageNow() }
        logger.info("engine prefix cache evicted for global budget: freed \(freed) (target \(targetBytesToFree))")
        return freed
    }

    // MARK: - Paths

    private func fileURL(_ blockHash: Data) -> URL {
        dir.appendingPathComponent("\(blockHash.dbkvHexString).\(EncryptedKVStore.fileExtension)")
    }
}
