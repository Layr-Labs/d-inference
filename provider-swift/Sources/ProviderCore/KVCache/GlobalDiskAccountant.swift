/// GlobalDiskAccountant — process-wide SSD disk budget shared across all
/// loaded model prefix cache managers. Phase 3 of the "20GB/model bookmark
/// cache" (issue #266): enforces a GLOBAL disk ceiling (not per-model), so
/// N models don't multiply the budget and fill the volume.
///
/// Design:
///   • Each PrefixCacheManager registers itself on load (receives an opaque
///     token) and deregisters on unload; registry tracks OWNED model dirs.
///   • After every byte-changing op (flush/persist/eviction), the manager
///     pushes its current total + value summary to the accountant via
///     `updateUsage` (cheap O(this-model-entries) push, no tree walk).
///   • Periodic tick (30s): re-read free disk, recompute ceiling, scan
///     kvRoot for unowned dirs (no live actor), sum their bytes + build
///     degraded value summaries, then enforce the global budget.
///   • Budget enforcement: when global total > ceiling, merge ALL value
///     summaries (owned + unowned), sort ASCENDING by benefit-per-byte
///     score (Phase-1 semantics), evict lowest-score entries. For OWNED
///     models: signal the owner actor (which evicts on its own executor).
///     For UNOWNED dirs: the accountant directly deletes files (no actor
///     holds them) and rmdir when empty.
///   • effectiveCeiling: explicit DARKBLOOM_PREFIX_CACHE_DISK_GB (>0) used
///     as a global cap; else min(10GiB, freeBytes/2) recomputed on tick.
///   • nil accountant ⇒ today's per-model behavior (backward compat).
///
/// Concurrency ground truth:
///   • MULTIPLE PrefixCacheManager actors run concurrently (multi-model).
///     The accountant MUST be a shared actor.
///   • PrefixCacheIndex is a NON-synchronized final class owned by ONE
///     manager actor. The accountant MUST NOT call index.remove/save on a
///     LIVE model's files — that races the owner's in-flight flush/persist.
///     Instead: SIGNAL the owner via evictForGlobalBudget, which runs on
///     the owner's executor (auto-serialized).
///   • Direct filesystem deletion is allowed ONLY for UNOWNED dirs (no
///     live actor → no race).
///   • modelKey (sha256(modelId)[:12], the DIR name) ≠ index modelHash
///     (weight-derived bindingId). Map dirs↔owners by modelKey ONLY.

import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "global-disk-accountant")

// MARK: - PrefixCacheOwner protocol

/// Protocol that PrefixCacheManager conforms to so the accountant can
/// signal it to free disk bytes. The manager evicts on its own executor
/// (actor-isolated, auto-serialized vs flush/lookup/load).
public protocol PrefixCacheOwner: Sendable {
    /// Evict lowest-score entries to free at least `targetBytesToFree`.
    /// Returns the number of bytes actually freed (may be >= target if
    /// entry boundaries overshoot).
    func evictForGlobalBudget(targetBytesToFree: Int) async -> Int
}

// MARK: - Value summary

/// Per-entry value data for benefit-per-byte scoring (Phase-1 semantics).
/// Aggregated across all models (owned + unowned) during enforcement.
/// Added `fileURL` so evictUnownedEntries can delete the
/// discovered file directly instead of re-deriving from the untrusted
/// index relativePath (path-traversal defense).
public struct EntryValue: Sendable {
    let modelKey: String
    let digestHex: String
    let fileBytes: Int
    let score: Double
    let fileURL: URL?  // Discovered file path from the tick scan, or nil for owned.
}

// MARK: - Registration token

/// Opaque handle returned by `register`, passed to `deregister`.
public struct AccountantToken: Sendable, Hashable {
    fileprivate let id: UUID
}

// MARK: - GlobalDiskAccountant

public actor GlobalDiskAccountant {

    // MARK: - Configuration

    /// Root directory: ~/Library/Caches/darkbloom/kv (parent of all <modelKey> dirs).
    private let kvRoot: URL
    /// Explicit DARKBLOOM_PREFIX_CACHE_DISK_GB (>0) used as global cap;
    /// 0 = derive from free disk (min(10GiB, free/2)) on each tick.
    private let configuredCeiling: Int
    /// Tick interval (seconds) for scanning unowned dirs + enforcing budget.
    private let tickSeconds: Int

    // MARK: - Test seams (injected Sendable closures)

    /// Returns current epoch seconds (wall clock in prod, fake in tests).
    private let now: @Sendable () -> Int64
    /// Returns free bytes on the volume containing `url` (statvfs in prod).
    private let freeBytes: @Sendable (URL) -> Int

    // MARK: - State

    /// Registered owners: token.id → (modelKey, owner).
    private var registry: [UUID: (modelKey: String, owner: PrefixCacheOwner)] = [:]
    /// Track the CURRENT active token per modelKey. Set on register,
    /// cleared on deregister ONLY IF the deregistered token is still active.
    /// Usage updates are scoped to the active token: a stale token's push is
    /// ignored (NO-OP), so a detached Task from an earlier load can't clobber
    /// a newer load's runningTotals/valueSummaries.
    private var activeToken: [String: UUID] = [:]
    /// Per-model running total (bytes), pushed by updateUsage.
    private var runningTotals: [String: Int] = [:]
    /// Per-model value summaries, pushed by updateUsage.
    private var valueSummaries: [String: [EntryValue]] = [:]
    /// Bytes from unowned dirs (no live actor), updated on tick.
    private var unownedBytes: Int = 0
    /// Unowned dir value summaries (degraded: mtime-LRU), updated on tick.
    private var unownedValueSummaries: [EntryValue] = []

    /// Tick task (started lazily on first register, cancelled on shutdown).
    private var tickTask: Task<Void, Never>?
    /// Reentrancy guard for enforceIfOverBudget. Without this,
    /// concurrent updateUsage calls can interleave at the owner-eviction await,
    /// both targeting the same owner with stale runningTotals → over-eviction.
    private var isEnforcing = false
    private var enforceRequested = false

    // MARK: - Init

    public init(
        kvRoot: URL,
        configuredCeiling: Int = 0,
        tickSeconds: Int = 30,
        sweepOnInit: Bool = false,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        freeBytes: @escaping @Sendable (URL) -> Int = { url in
            // Production: statvfs to read free disk.
            var stat = statvfs()
            guard statvfs(url.path, &stat) == 0 else { return 0 }
            return Int(stat.f_bavail) * Int(stat.f_bsize)
        }
    ) {
        self.kvRoot = kvRoot
        self.configuredCeiling = max(0, configuredCeiling)
        self.tickSeconds = max(1, tickSeconds)
        self.now = now
        self.freeBytes = freeBytes
        // Startup sweep: wipe ALL on-disk KV under kvRoot. Restart warmth is
        // intentionally OFF — a clean unload purges each model's dir, but a jetsam
        // SIGKILL (the "invisible OOM") can't run a clean purge, so any per-model
        // dirs present at process start are stale crash leftovers. Done here in
        // init (synchronously, before any owner registers) so it can never race a
        // live owner's files. Production passes sweepOnInit: true; tests default
        // off so they don't wipe their own fixtures.
        let fm = FileManager.default
        if sweepOnInit, let entries = try? fm.contentsOfDirectory(
            at: kvRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in entries { try? fm.removeItem(at: url) }
        }
        // Ensure kvRoot exists (and re-create it if the sweep removed it).
        try? fm.createDirectory(at: kvRoot, withIntermediateDirectories: true)
    }

    // MARK: - Registration

    public func register(modelKey: String, owner: PrefixCacheOwner) async -> AccountantToken {
        let token = AccountantToken(id: UUID())
        registry[token.id] = (modelKey, owner)
        // Mark this token as the active owner for the modelKey.
        activeToken[modelKey] = token.id
        runningTotals[modelKey] = 0
        valueSummaries[modelKey] = []

        // A prior deregister left this model's files on disk; a tick
        // may have folded them into unowned*. Drop that stale share now so
        // register + updateUsage don't double-count it (owned + unowned) until
        // the next tick. The subtraction is exact (EntryValue carries fileBytes).
        let staleBytes = unownedValueSummaries
            .filter { $0.modelKey == modelKey }
            .reduce(0) { $0 + $1.fileBytes }
        if staleBytes > 0 {
            unownedBytes = max(0, unownedBytes - staleBytes)
            unownedValueSummaries.removeAll { $0.modelKey == modelKey }
            logger.info("register: dropped stale unowned accounting for \(modelKey, privacy: .public) (\(staleBytes) bytes)")
        }

        // Start the tick watchdog on first register (pattern: BatchScheduler.startPendingTimeoutWatchdog).
        if tickTask == nil {
            startTick()
        }

        logger.info("registered model \(modelKey, privacy: .public)")
        return token
    }

    public func deregister(_ token: AccountantToken) async {
        guard let (modelKey, _) = registry.removeValue(forKey: token.id) else { return }
        // Clear activeToken ONLY if this token is still the active one.
        // If a newer reload already registered a fresh token, leave activeToken as-is.
        if activeToken[modelKey] == token.id {
            activeToken.removeValue(forKey: modelKey)
        }
        // Clear runningTotals/valueSummaries ONLY if this token was
        // active. If superseded, the newer owner already set them — leave intact.
        if activeToken[modelKey] == nil {
            runningTotals.removeValue(forKey: modelKey)
            valueSummaries.removeValue(forKey: modelKey)
        }
        logger.info("deregistered model \(modelKey, privacy: .public)")

        // Stop tick if no more registered models (no work to do).
        if registry.isEmpty {
            tickTask?.cancel()
            tickTask = nil
        }
    }

    // MARK: - Usage tracking

    /// Called by PrefixCacheManager after each byte-changing op (flush,
    /// persist, eviction). Cheap O(this-model-entries) push, no tree walk.
    /// ModelKey-only signature kept for back-compat (engine-tier
    /// calls from EncryptedPrefixCachePersistence), but usage updates from a
    /// stale registration (e.g. detached Task from an older load) are NO-OP:
    /// we only accept updates for the CURRENT active token. Callers that can
    /// pass a token should use updateUsage(token:totalBytes:valueSummary:).
    public func updateUsage(modelKey: String, totalBytes: Int, valueSummary: [EntryValue]) async {
        // NO-OP if no active registration for this modelKey (all owners unloaded).
        guard activeToken[modelKey] != nil else { return }
        runningTotals[modelKey] = max(0, totalBytes)
        valueSummaries[modelKey] = valueSummary
        await enforceIfOverBudget()
    }

    /// Token-scoped usage update. Only accepts the update if the
    /// token is still the active owner for its modelKey — stale tokens (from a
    /// superseded load or a detached Task that outlived the unload) are NO-OP.
    public func updateUsage(token: AccountantToken, totalBytes: Int, valueSummary: [EntryValue]) async {
        guard let (modelKey, _) = registry[token.id] else { return }
        guard activeToken[modelKey] == token.id else { return }
        runningTotals[modelKey] = max(0, totalBytes)
        valueSummaries[modelKey] = valueSummary
        await enforceIfOverBudget()
    }

    // MARK: - Budget enforcement

    /// Recompute the effective ceiling from config or live free disk.
    /// Explicit DARKBLOOM_PREFIX_CACHE_DISK_GB (>0) used as global cap;
    /// else min(10GiB, free/2) recomputed on each call.
    private func effectiveCeiling() -> Int {
        if configuredCeiling > 0 {
            return configuredCeiling
        }
        let free = freeBytes(kvRoot)
        let tenGiB = 10 * 1024 * 1024 * 1024
        return min(tenGiB, free / 2)
    }

    /// Global total = sum of owned model totals + unowned bytes.
    private func globalTotal() -> Int {
        let owned = runningTotals.values.reduce(0, +)
        return owned + max(0, unownedBytes)
    }

    /// Check if global total > ceiling; if so, evict lowest-score entries
    /// across ALL models (owned + unowned) until within budget.
    /// Guarded against reentrancy across the owner-eviction await.
    private func enforceIfOverBudget() async {
        // If already enforcing, set the requested flag and return.
        // The in-flight pass will re-run once if any concurrent caller arrived.
        if isEnforcing {
            enforceRequested = true
            return
        }
        isEnforcing = true
        defer { isEnforcing = false }

        repeat {
            enforceRequested = false
            await enforceOnce()
        } while enforceRequested
    }

    /// Single enforcement pass (factored out for the reentrancy guard loop).
    private func enforceOnce() async {
        let ceiling = effectiveCeiling()
        var total = globalTotal()
        guard total > ceiling else { return }

        logger.info("global disk budget exceeded: \(total) > \(ceiling) — enforcing")

        // Merge ALL value summaries (owned + unowned) into one list.
        var allEntries: [EntryValue] = []
        for (_, summary) in valueSummaries {
            allEntries.append(contentsOf: summary)
        }
        allEntries.append(contentsOf: unownedValueSummaries)

        // Sort ASCENDING by score (lowest = evict first).
        allEntries.sort { $0.score < $1.score }

        // Walk accumulating fileBytes until freed >= (total - ceiling).
        let target = total - ceiling
        var chosen: [String: [EntryValue]] = [:]  // modelKey → entries
        var accum = 0
        for entry in allEntries {
            if accum >= target { break }
            chosen[entry.modelKey, default: []].append(entry)
            accum += entry.fileBytes
        }

        // For each modelKey with chosen entries:
        //   • OWNED: signal the owner actor.
        //   • UNOWNED: the accountant directly deletes files.
        for (modelKey, entries) in chosen {
            let bytesForModel = entries.reduce(0) { $0 + $1.fileBytes }
            // Resolve the owner via activeToken[modelKey],
            // NOT registry.values.first(where:). During a reload window two
            // tokens can be registered for the same modelKey; the first-match
            // lookup has undefined iteration order and could return the STALE
            // owner — a closed checkpoint manager (frees 0, budget stays
            // violated) or, worse, a stale engine-tier owner that direct-deletes
            // files in the dir the ACTIVE owner is using (cross-actor race).
            if let activeID = activeToken[modelKey], let (_, owner) = registry[activeID] {
                // OWNED by the ACTIVE token: signal it. The owner's
                // evictForGlobalBudget calls notifyAccountant()/publishUsageNow()
                // at the end (reentrant on this actor), which sets
                // runningTotals[modelKey] + valueSummaries[modelKey] to the fresh
                // post-eviction state from its live index. So we must NOT also
                // subtract `freed` here — that would double-count. Recompute
                // `total` from the reconciled running totals instead.
                _ = await owner.evictForGlobalBudget(targetBytesToFree: bytesForModel)
                total = globalTotal()
                logger.info("signaled owned model \(modelKey, privacy: .public) to free \(bytesForModel) → total now \(total)")
            } else if registry.contains(where: { $0.value.modelKey == modelKey }) {
                // STALE-ONLY: a registry entry exists for this modelKey but it is
                // NOT the active token (mid-reload: the active owner deregistered
                // and a fresh one hasn't claimed yet, or a superseded token lingers).
                // A live owner object still holds this dir, so the accountant must
                // NOT direct-delete (forbidden cross-actor mutation). Skip this
                // round; the ~30s tick (or the next updateUsage-driven enforce)
                // re-evaluates once ownership settles.
                logger.info("skipping model \(modelKey, privacy: .public): registered but not the active token (reload window)")
            } else {
                // UNOWNED: no registry entry at all → accountant directly deletes.
                let freed = await evictUnownedEntries(modelKey: modelKey, entries: entries)
                unownedBytes = max(0, unownedBytes - freed)
                total -= freed
                // Prune the just-evicted digests from the cached
                // unowned summary so a between-tick re-enforce (updateUsage →
                // enforceIfOverBudget) cannot re-count their phantom bytes.
                // The summary is otherwise only rebuilt on the 30s tick.
                let evicted = Set(entries.map { $0.digestHex })
                unownedValueSummaries.removeAll {
                    $0.modelKey == modelKey && evicted.contains($0.digestHex)
                }
                logger.info("deleted unowned model \(modelKey, privacy: .public) files: freed \(freed)")
            }
        }

        logger.info("global disk enforcement complete: now \(total) (ceiling \(ceiling))")
    }

    /// Directly delete files for unowned dirs (no live actor holds them).
    /// Returns bytes freed. When a dir has no .darkbloom-kv left, rmdir it.
    /// Handles BOTH layouts: flat (engine tier) and nested (checkpoint tier).
    private func evictUnownedEntries(modelKey: String, entries: [EntryValue]) async -> Int {
        let modelDir = kvRoot.appendingPathComponent(modelKey, isDirectory: true)
        let fm = FileManager.default
        let suffix = ".\(EncryptedKVStore.fileExtension)"
        var freed = 0

        // Load the transient index and enumerate ALL its entries
        // (not by modelKey, which is the dir name, NOT the index's modelHash).
        // The index is per-dir, so all its entries belong to this dir's model.
        let indexURL = modelDir.appendingPathComponent("index.json")
        let index = PrefixCacheIndex(fileURL: indexURL)
        let allIndexEntries = index.allEntries()

        for entry in entries {
            // Use the fileURL discovered by tick's collectKVFiles
            // instead of re-deriving from the untrusted index relativePath.
            // This closes the path-traversal hole: the URL comes from a real
            // directory walk, never from index.json (which is plaintext and
            // NOT authenticated). Fallback to the old logic only for entries
            // from owned summaries (where fileURL is nil).
            let fileURL: URL
            if let discovered = entry.fileURL {
                fileURL = discovered
            } else {
                // Fallback (owned-summary entries or legacy tests): reconstruct
                // from digestHex. Try nested first (checkpoint tier).
                if let indexEntry = allIndexEntries.first(where: { $0.digestHex == entry.digestHex }),
                   !indexEntry.relativePath.isEmpty {
                    fileURL = modelDir.appendingPathComponent(indexEntry.relativePath)
                } else {
                    fileURL = modelDir.appendingPathComponent("\(entry.digestHex)\(suffix)")
                }
            }

            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int {
                freed += size
            }
            try? fm.removeItem(at: fileURL)

            // Use the entry's OWN modelHash (from the index) to remove it.
            // For engine-tier entries (not in index), we skip index removal.
            if let indexEntry = allIndexEntries.first(where: { $0.digestHex == entry.digestHex }) {
                index.remove(modelHash: indexEntry.modelHash, digestHex: entry.digestHex)
            }
        }

        // Persist the updated index if dirty.
        if index.isDirty {
            try? index.save()
        }

        // If the dir has no more .darkbloom-kv files (at any depth), rmdir it.
        // Check nested subdirs too (checkpoint tier).
        let hasFiles = checkForKVFiles(in: modelDir, fm: fm, suffix: suffix)
        if !hasFiles {
            try? fm.removeItem(at: modelDir)
            logger.info("removed empty unowned dir \(modelKey, privacy: .public)")
        }

        return freed
    }

    /// Recursively check if a directory tree contains any .darkbloom-kv files.
    private func checkForKVFiles(in dir: URL, fm: FileManager, suffix: String) -> Bool {
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return false
        }
        for item in contents {
            if item.lastPathComponent.hasSuffix(suffix) && !item.lastPathComponent.contains(".\(EncryptedKVStore.tempInfix)") {
                return true
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                if checkForKVFiles(in: item, fm: fm, suffix: suffix) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Periodic tick

    private func startTick() {
        let interval = Duration.seconds(tickSeconds)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.tick()
            }
        }
    }

    /// Periodic tick: re-read free disk, recompute ceiling, scan kvRoot for
    /// unowned dirs, sum their bytes + build degraded value summaries, then
    /// enforce the global budget. Internal for testing (called by tick task in prod).
    /// Handles BOTH layouts: flat (engine) and nested (checkpoint).
    func tick() async {
        let fm = FileManager.default
        let suffix = ".\(EncryptedKVStore.fileExtension)"

        // Scan kvRoot for all <modelKey> dirs.
        guard let modelDirs = try? fm.contentsOfDirectory(
            at: kvRoot, includingPropertiesForKeys: [], options: [.skipsHiddenFiles]
        ) else { return }

        var unownedTotal = 0
        var unownedValues: [EntryValue] = []

        for modelDir in modelDirs where modelDir.hasDirectoryPath {
            let modelKey = modelDir.lastPathComponent

            // If this dir is OWNED (in registry), trust the running total
            // (don't re-sum — that would race the owner's in-flight flush).
            if registry.values.contains(where: { $0.modelKey == modelKey }) {
                continue
            }

            // UNOWNED dir. Load its index (if present) to get all entries.
            let indexURL = modelDir.appendingPathComponent("index.json")
            let index = PrefixCacheIndex(fileURL: indexURL)
            let allIndexEntries = index.allEntries()

            // Scan for KV files at BOTH depths:
            // - FLAT (engine tier): <modelDir>/*.darkbloom-kv
            // - NESTED (checkpoint tier): <modelDir>/<modelHash[:12]>/*.darkbloom-kv
            let kvFiles = collectKVFiles(in: modelDir, fm: fm, suffix: suffix)

            for (fileURL, relativePath) in kvFiles {
                let name = fileURL.lastPathComponent
                let digestHex = String(name.dropLast(suffix.count))
                let v = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = v?.fileSize ?? 0
                unownedTotal += size

                // Build degraded value summary: try index entry first, else mtime-LRU.
                // Query index by relativePath or digestHex (not by modelKey).
                let score: Double
                if let entry = allIndexEntries.first(where: { $0.digestHex == digestHex }) {
                    // Use the index's benefit-per-byte score.
                    score = PrefixCacheIndex.benefitScore(
                        entry, now: now(),
                        prefillCostPerToken: 1.0,  // default (manager-specific values not known here)
                        halfLifeSeconds: 86400.0
                    )
                } else {
                    // Degraded: mtime-LRU (older = lower score = evict first).
                    let mtime = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    let age = Double(now()) - mtime
                    // Score inversely proportional to age (older = lower).
                    score = size > 0 ? (1.0 / max(1.0, age)) / Double(size) : 0.0
                }

                // Thread the discovered fileURL through EntryValue.
                unownedValues.append(EntryValue(
                    modelKey: modelKey, digestHex: digestHex, fileBytes: size, score: score, fileURL: fileURL
                ))
            }
        }

        unownedBytes = unownedTotal
        unownedValueSummaries = unownedValues

        logger.info("tick: owned=\(self.runningTotals.values.reduce(0, +)), unowned=\(unownedTotal), ceiling=\(self.effectiveCeiling())")
        await enforceIfOverBudget()
    }

    /// Collect all .darkbloom-kv files at any depth under `dir`, returning
    /// (fileURL, relativePath from dir). Handles both flat (engine) and nested
    /// (checkpoint) layouts via a recursive scan for the checkpoint tier.
    private func collectKVFiles(in dir: URL, fm: FileManager, suffix: String) -> [(URL, String)] {
        var results: [(URL, String)] = []
        guard let contents = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for item in contents {
            let name = item.lastPathComponent
            // Check if it's a .darkbloom-kv file (flat, engine tier).
            if name.hasSuffix(suffix), !name.contains(".\(EncryptedKVStore.tempInfix)") {
                let rel = item.lastPathComponent
                results.append((item, rel))
                continue
            }
            // Check if it's a directory (checkpoint tier: recurse one level).
            let v = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if v?.isDirectory == true {
                // Recurse one level only (checkpoint files are at depth 2).
                guard let nestedContents = try? fm.contentsOfDirectory(
                    at: item, includingPropertiesForKeys: [],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for nestedItem in nestedContents {
                    let nestedName = nestedItem.lastPathComponent
                    if nestedName.hasSuffix(suffix), !nestedName.contains(".\(EncryptedKVStore.tempInfix)") {
                        let rel = "\(name)/\(nestedName)"
                        results.append((nestedItem, rel))
                    }
                }
            }
        }
        return results
    }

    // MARK: - Shutdown

    public func shutdown() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Test introspection

    /// Last-reported OWNED usage (bytes) for a model, or nil if not registered.
    /// Test-only seam: regression tests assert that an owner's usage push
    /// actually reached the accountant (e.g. the engine tier's saveBlock →
    /// pushUsageToAccountantIfNeeded path). Not used in production.
    public func _usageForTest(modelKey: String) -> Int? {
        runningTotals[modelKey]
    }
}
