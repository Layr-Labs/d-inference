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
public struct EntryValue: Sendable {
    let modelKey: String
    let digestHex: String
    let fileBytes: Int
    let score: Double
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

    // MARK: - Init

    public init(
        kvRoot: URL,
        configuredCeiling: Int = 0,
        tickSeconds: Int = 30,
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
        // Ensure kvRoot exists.
        try? FileManager.default.createDirectory(at: kvRoot, withIntermediateDirectories: true)
    }

    // MARK: - Registration

    public func register(modelKey: String, owner: PrefixCacheOwner) async -> AccountantToken {
        let token = AccountantToken(id: UUID())
        registry[token.id] = (modelKey, owner)
        runningTotals[modelKey] = 0
        valueSummaries[modelKey] = []

        // Start the tick watchdog on first register (pattern: BatchScheduler.startPendingTimeoutWatchdog).
        if tickTask == nil {
            startTick()
        }

        logger.info("registered model \(modelKey, privacy: .public)")
        return token
    }

    public func deregister(_ token: AccountantToken) async {
        guard let (modelKey, _) = registry.removeValue(forKey: token.id) else { return }
        // Flip ownership to unowned (accountant will scan it on next tick).
        // Do NOT delete the dir — it holds reusable files for a restart.
        runningTotals.removeValue(forKey: modelKey)
        valueSummaries.removeValue(forKey: modelKey)
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
    public func updateUsage(modelKey: String, totalBytes: Int, valueSummary: [EntryValue]) async {
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
    private func enforceIfOverBudget() async {
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
            if let (_, owner) = registry.values.first(where: { $0.modelKey == modelKey }) {
                // OWNED: signal the owner.
                let freed = await owner.evictForGlobalBudget(targetBytesToFree: bytesForModel)
                runningTotals[modelKey] = max(0, (runningTotals[modelKey] ?? 0) - freed)
                total -= freed
                logger.info("signaled owned model \(modelKey, privacy: .public) to free \(bytesForModel) → freed \(freed)")
            } else {
                // UNOWNED: accountant directly deletes files.
                let freed = await evictUnownedEntries(modelKey: modelKey, entries: entries)
                unownedBytes = max(0, unownedBytes - freed)
                total -= freed
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

        // BUG-2-FIX(b): Load the transient index and enumerate ALL its entries
        // (not by modelKey, which is the dir name, NOT the index's modelHash).
        // The index is per-dir, so all its entries belong to this dir's model.
        let indexURL = modelDir.appendingPathComponent("index.json")
        let index = PrefixCacheIndex(fileURL: indexURL)
        let allIndexEntries = index.allEntries()

        for entry in entries {
            // BUG-2-FIX(a): resolve file path for BOTH layouts.
            // Checkpoint tier: files nested under <modelHash[:12]>/<digest>.darkbloom-kv
            // Engine tier: files flat under <modelKey>/<blockHash>.darkbloom-kv
            // Try nested first (if an index entry has relativePath, use it),
            // else fall back to flat (engine tier has no index entries).
            let fileURL: URL
            if let indexEntry = allIndexEntries.first(where: { $0.digestHex == entry.digestHex }),
               !indexEntry.relativePath.isEmpty {
                // Checkpoint tier: relativePath is modelDirComponent/digestHex.darkbloom-kv
                fileURL = modelDir.appendingPathComponent(indexEntry.relativePath)
            } else {
                // Engine tier: flat file directly under modelDir.
                fileURL = modelDir.appendingPathComponent("\(entry.digestHex)\(suffix)")
            }

            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int {
                freed += size
            }
            try? fm.removeItem(at: fileURL)

            // BUG-2-FIX(b): Use the entry's OWN modelHash (from the index) to remove it.
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
        // BUG-2-FIX(a): check nested subdirs too (checkpoint tier).
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
    /// BUG-2-FIX(a): Handles BOTH layouts: flat (engine) and nested (checkpoint).
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

            // BUG-2-FIX(a): UNOWNED dir. Load its index (if present) to get all entries.
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
                // BUG-2-FIX(b): query index by relativePath or digestHex (not by modelKey).
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

                unownedValues.append(EntryValue(
                    modelKey: modelKey, digestHex: digestHex, fileBytes: size, score: score
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
    /// (checkpoint) layouts. BUG-2-FIX(a): recursive scan for checkpoint tier.
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
}
