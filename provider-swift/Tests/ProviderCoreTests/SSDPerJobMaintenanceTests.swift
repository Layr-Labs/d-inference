// Copyright © 2026 Eigen Labs.
//
// Per-job write-behind maintenance for the SSD prefix cache. The serial
// consumer settles a donation with an opportunistic TTL sweep and INDEX-ONLY
// box-wide budget enforcement; the whole-root filesystem walk (unloaded model
// roots, crash temps, external reconcile) belongs to the 60 s periodic task
// alone. Live-isolated: the production factory over an isolated test root,
// real DBK3 files, real MLX arrays — no mocks.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Full-attention-only layout: replay bound 0, `.direct` strategy.
private let perJobLayerKinds: [CBv2LayerKind] = [
    CBv2LayerKind(attention: .full, headDim: 8, kvHeads: 2, queryHeads: 4)
]

private func perJobTempRoot(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("ssd-per-job-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func perJobSnapshots(tokenCount: Int, seed: Float = 1)
    -> [(keys: MLXArray, values: MLXArray, offset: Int)?]
{
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    let shape = [1, 2, tokenCount, 8]
    let count = shape.reduce(1, *)
    let base = MLXArray(0 ..< count).reshaped(shape).asType(.float16)
    let keys = (base * seed).asType(.float16)
    let values = (base * (seed + 0.5)).asType(.float16)
    eval(keys, values)
    return [(keys: keys, values: values, offset: tokenCount)]
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
}

/// Seed `count` owned (header-readable) DBK3 files under an UNLOADED model
/// directory of `root`, all carrying the same mtime.
private func seedUnloadedBlocks(
    root: URL, modelKey: String, count: Int, modifiedAt: Int64
) throws -> [URL] {
    let modelRoot = root.appendingPathComponent(modelKey, isDirectory: true)
    try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
    let kek = SymmetricKey(size: .bits256)
    let chunk = Data(repeating: 7, count: 64)
    let touch = Date(timeIntervalSince1970: TimeInterval(modifiedAt))
    var urls: [URL] = []
    urls.reserveCapacity(count)
    for i in 0 ..< count {
        var tag = Data(repeating: 0x5a, count: 16)
        tag[0] = UInt8(truncatingIfNeeded: i)
        tag[1] = UInt8(truncatingIfNeeded: i >> 8)
        let tagHex = SSDLookupKeys.hex(tag)
        let url = SSDBlockStore.fileURL(root: modelRoot, tag16Hex: tagHex)
        let metadata = SSDBlockMetadata(
            lookupTag: tagHex + tagHex,
            weightHash: "unloaded-weights",
            layoutEpoch: "layout",
            blockSize: 8,
            layerCount: 1,
            chunks: [.init(layerIndex: 0, tensor: 0, shape: [1, 1, 1, 1], dtype: "float16")],
            chunkPlaintextSizes: [chunk.count],
            createdAt: modifiedAt)
        _ = try SSDBlockStore.write(to: url, metadata: metadata, chunks: [chunk], kekKey: kek)
        try FileManager.default.setAttributes([.modificationDate: touch], ofItemAtPath: url.path)
        urls.append(url)
    }
    return urls
}

private final class PerJobClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64
    init(_ now: Int64) { self._now = now }
    var now: Int64 { lock.withLock { _now } }
    func advance(_ seconds: Int64) { lock.withLock { _now += seconds } }
}

private final class PerJobBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes = Int.max
    var bytes: Int {
        get { lock.withLock { _bytes } }
        set { lock.withLock { _bytes = newValue } }
    }
}

/// The write-behind refuses every write under max(20 GiB, 5% of capacity)
/// free (`SSDPrefixCachePolicy.lowDiskFloorBytes`). On a nearly full volume
/// donation-dependent tests cannot observe anything, so they skip with the
/// reason instead of failing on `blocksWritten == 0`.
private var lowDiskGuardPermitsWrites: Bool {
    let probe = FileManager.default.temporaryDirectory
    guard let free = PrefixCachePolicy.volumeFreeBytes(at: probe),
        let capacity = try? probe.resourceValues(forKeys: [.volumeTotalCapacityKey])
            .volumeTotalCapacity
    else { return true }
    return free >= SSDPrefixCachePolicy.lowDiskFloorBytes(volumeCapacityBytes: capacity)
}

private final class ConstructionFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SSDPrefixCacheConstructionFailure] = []
    func append(_ failure: SSDPrefixCacheConstructionFailure) {
        lock.withLock { values.append(failure) }
    }
    var snapshot: [SSDPrefixCacheConstructionFailure] { lock.withLock { values } }
}

@Suite("SSD prefix cache: per-job write-behind maintenance", .serialized)
struct SSDPerJobMaintenanceTests {

    @Test(
        "a donation settles index-only; the periodic walk alone reclaims unloaded roots",
        .enabled(if: lowDiskGuardPermitsWrites, "volume below the write-behind low-disk floor"))
    func donationSettlesWithoutWholeRootWalk() async throws {
        let root = perJobTempRoot("factory")
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
        }
        let blockSize = PrefixCachePolicy.blockSize
        let environment = [
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
            SSDPrefixCachePolicy.minEffectiveTokensFlag: "\(blockSize)",
        ]
        #expect(SSDPrefixCacheFactory.cacheRootDirectory(environment: environment) == root)
        let capability = PrefixCachePolicy.prefixReuseCapability(
            layerKinds: perJobLayerKinds, backendSelection: .contiguous)
        #expect(capability.isSupported)
        let failures = ConstructionFailures()
        let made = await SSDPrefixCacheFactory.make(
            modelId: "per-job-model",
            promptContractID: String(repeating: "b", count: 64),
            weightHash: String(repeating: "a", count: 64),
            layerKinds: perJobLayerKinds,
            prefixReuseCapability: capability,
            kvBudget: nil,
            environment: environment,
            onConstructionFailure: { failures.append($0) })
        let cache = try #require(made, "factory refused: \(failures.snapshot)")
        defer { cache.close() }

        // The factory starts the periodic walk, whose first pass runs at once.
        // Stop it and wait for the task to EXIT (a cancel alone lets a pass
        // that was about to start run once more) so the files seeded below are
        // only ever visible to the per-job path.
        await SSDWholeRootMaintainer.shared.stopPeriodicMaintenanceForTesting(root: root)

        let seededCount = 1_000
        let expiredAt =
            Int64(Date().timeIntervalSince1970) - 2 * SSDPrefixCachePolicy.defaultTTLSeconds
        let seedStarted = ContinuousClock.now
        let seeded = try seedUnloadedBlocks(
            root: root, modelKey: "aaaaaaaaaaaa", count: seededCount, modifiedAt: expiredAt)
        let seedMs = milliseconds(since: seedStarted)

        var ready = false
        for _ in 0 ..< 500 where !ready {
            ready = cache.prefixCacheV2Capability() != nil
            if !ready { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(ready, "startup scan never became ready")

        // Three whole blocks clear the lowered floor (bound 0 + blockSize).
        let tokens = Array(0 ..< 3 * blockSize)
        let donateStarted = ContinuousClock.now
        cache.donate(
            tokens: tokens,
            snapshots: perJobSnapshots(tokenCount: tokens.count),
            layerKinds: perJobLayerKinds,
            cacheSalt: nil)
        await cache.waitForWritesForTesting()
        let settleMs = milliseconds(since: donateStarted)
        #expect(cache.index.count == 3)
        #expect(cache.stats().blocksWritten == 3)

        // The per-job path is index-only: an unloaded model's expired bytes are
        // not the write-behind consumer's business ...
        let removed = seeded.filter { !FileManager.default.fileExists(atPath: $0.path) }
        #expect(
            removed.isEmpty,
            "per-job maintenance walked the whole root: \(removed.count)/\(seededCount) unloaded files removed")
        print(
            "[ssd-per-job] settle=\(String(format: "%.1f", settleMs)) ms with \(seededCount) unloaded files on disk (seeding took \(String(format: "%.0f", seedMs)) ms)")

        // ... and the periodic walk — now the ONLY walk — still reclaims them,
        // leaving the active model's fresh blocks alone.
        let presentBeforeWalk = seeded.filter { FileManager.default.fileExists(atPath: $0.path) }.count
        let result = SSDWholeRootMaintainer.shared.maintain(
            root: root,
            ttlSeconds: SSDPrefixCachePolicy.defaultTTLSeconds,
            nowSeconds: Int64(Date().timeIntervalSince1970),
            budgetBytes: Int.max)
        print(
            "[ssd-per-job] periodic walk: present=\(presentBeforeWalk) seen=\(result.filesSeen) ttlExpired=\(result.ttlExpired) budgetEvicted=\(result.budgetEvicted) temps=\(result.tempFilesRemoved)")
        #expect(presentBeforeWalk == seededCount)
        #expect(result.ttlExpired == seededCount)
        #expect(seeded.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(cache.index.count == 3)
    }

    @Test("oldest() is the sorted LRU head, ties broken by tag")
    func oldestMatchesSortedHead() throws {
        let index = SSDBlockIndex()
        #expect(index.oldest() == nil)
        var tags: [Data] = []
        for i in 0 ..< 64 {
            var tag = Data(repeating: UInt8(truncatingIfNeeded: 255 - i), count: 16)
            tag[15] = UInt8(truncatingIfNeeded: i &* 37)
            tags.append(tag)
        }
        // Shuffled insertion; eight entries share every lastAccess value so
        // the tie-break is exercised on each step.
        for (i, tag) in tags.shuffled().enumerated() {
            index.insert(tag16: tag, fileBytes: 1 + i, lastAccess: Int64(100 + i % 8))
        }
        var sorted = index.oldestEntries()
        for _ in 0 ..< 24 {
            let head = try #require(sorted.first)
            let oldest = try #require(index.oldest())
            #expect(oldest.tag16 == head.tag16)
            #expect(oldest.lastAccess == head.lastAccess)
            #expect(oldest.fileBytes == head.fileBytes)
            index.remove(tag16: head.tag16)
            sorted.removeFirst()
        }
        #expect(index.oldestEntries().map(\.tag16) == sorted.map(\.tag16))
    }

    private func makeDirectCache(
        dir: URL,
        clock: PerJobClock,
        diskBudget: SSDDiskBudget,
        budget: PerJobBudget
    ) -> SSDPrefixCache {
        let config = SSDPrefixCache.Config(
            modelId: dir.lastPathComponent,
            promptContractID: "contract",
            weightHash: "weights",
            blockSize: 8,
            adoptionBoundTokens: 0,
            layoutEpoch: SSDBlockStore.layoutEpoch(blockSize: 8, layerKinds: perJobLayerKinds),
            root: dir,
            ttlSeconds: 900,
            minEffectiveTokens: 8,
            maxStageBytes: 1 << 30,
            maxStageMillis: 1_000_000,
            nowSeconds: { clock.now })
        return SSDPrefixCache(
            config: config,
            kekKey: SymmetricKey(size: .bits256),
            kvBudget: nil,
            diskBudget: diskBudget,
            maxWriteBytesPerDay: 0,
            strictFsync: false,
            diskBudgetBytes: { budget.bytes })
    }

    @Test(
        "the consumer's budget enforcement is box-wide across loaded stores",
        .enabled(if: lowDiskGuardPermitsWrites, "volume below the write-behind low-disk floor"))
    func perJobEnforceIsBoxWide() async throws {
        let root = perJobTempRoot("box-wide")
        defer { try? FileManager.default.removeItem(at: root) }
        let dirA = root.appendingPathComponent("aaaaaaaaaaaa", isDirectory: true)
        let dirB = root.appendingPathComponent("bbbbbbbbbbbb", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: dirA)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: dirB)
        let clock = PerJobClock(10_000)
        let diskBudget = SSDDiskBudget()
        let budget = PerJobBudget()
        let a = makeDirectCache(dir: dirA, clock: clock, diskBudget: diskBudget, budget: budget)
        let b = makeDirectCache(dir: dirB, clock: clock, diskBudget: diskBudget, budget: budget)
        defer {
            a.close()
            b.close()
        }

        a.donate(
            tokens: Array(0 ..< 64),
            snapshots: perJobSnapshots(tokenCount: 64, seed: 1),
            layerKinds: perJobLayerKinds,
            cacheSalt: nil)
        await a.waitForWritesForTesting()
        #expect(a.index.count == 8)
        let perBlock = a.index.totalBytes / 8

        // The second store's job lands eight strictly newer blocks against an
        // eight-block box-wide budget: the consumer's enforcement must evict
        // the OTHER store's blocks, not its own.
        budget.bytes = perBlock * 8
        clock.advance(60)
        b.donate(
            tokens: Array(1_000 ..< 1_064),
            snapshots: perJobSnapshots(tokenCount: 64, seed: 2),
            layerKinds: perJobLayerKinds,
            cacheSalt: nil)
        await b.waitForWritesForTesting()
        #expect(b.index.count == 8)
        #expect(a.index.count == 0, "the older store's blocks are the box-wide LRU victims")
        #expect(diskBudget.totalBytes <= perBlock * 8)
        #expect(diskBudget.evictionCount == 8)
    }
}

// MARK: - Review fix (S6): box-wide enforcement plans once and unlinks in batches

/// An evictable store that counts what enforcement asks of it. Entries are
/// (lastAccess, bytes) keyed by tag; `undeletable` models a file the unlink
/// cannot remove (left in place, like `unlinkVictim`'s `.undeletable`).
private final class CountingEvictableStore: SSDEvictableStore, @unchecked Sendable {
    let evictionRoot: URL
    private let lock = NSLock()
    private var entries: [Data: (lastAccess: Int64, fileBytes: Int)]
    private(set) var snapshotCalls = 0
    private(set) var evictCalls = 0
    private(set) var evictedTags: [Data] = []
    var undeletable: Set<Data> = []

    init(root: URL, entries: [(tag16: Data, lastAccess: Int64, fileBytes: Int)]) {
        evictionRoot = root
        self.entries = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.tag16, (lastAccess: $0.lastAccess, fileBytes: $0.fileBytes)) })
    }

    var diskBytesOnDisk: Int { lock.withLock { entries.values.reduce(0) { $0 + $1.fileBytes } } }
    var count: Int { lock.withLock { entries.count } }

    func oldestEntries() -> [(tag16: Data, lastAccess: Int64, fileBytes: Int)] {
        lock.withLock {
            snapshotCalls += 1
            return entries
                .map { (tag16: $0.key, lastAccess: $0.value.lastAccess, fileBytes: $0.value.fileBytes) }
                .sorted {
                    $0.lastAccess != $1.lastAccess
                        ? $0.lastAccess < $1.lastAccess
                        : $0.tag16.lexicographicallyPrecedes($1.tag16)
                }
        }
    }

    func evictEntries(_ victims: [Data], freeing targetBytes: Int) -> (freedBytes: Int, evicted: Int) {
        lock.withLock {
            evictCalls += 1
            var freed = 0
            var evicted = 0
            for tag in victims where freed < targetBytes {
                guard !undeletable.contains(tag), let entry = entries.removeValue(forKey: tag) else { continue }
                freed += entry.fileBytes
                evicted += 1
                evictedTags.append(tag)
            }
            return (freed, evicted)
        }
    }

    func reconcileExternalRemovals() {}
    func performExternalDestructiveChange(_ body: () -> Void) -> Bool {
        body()
        return true
    }
}

private func enforceTag(_ store: UInt8, _ i: Int) -> Data {
    var tag = Data(repeating: 0, count: 16)
    tag[0] = store
    tag[1] = UInt8(truncatingIfNeeded: i >> 8)
    tag[2] = UInt8(truncatingIfNeeded: i)
    return tag
}

/// `SSDDiskBudget.enforce` used to pick one victim per pass — a full
/// `oldest()` scan of EVERY registered index plus one epoch-record read per
/// unlink, all under the budget lock on the serial write-behind consumer.
/// A budget drop (free-disk/2 clamp after a large download) forced ~n/2
/// evictions in one call: O(victims × entries), seconds with every model's
/// ready receipt waiting. Now: one sorted snapshot per store per pass, a
/// global oldest-first merge, one batched bracket per store.
@Suite("SSD prefix cache: batched box-wide budget enforcement (SSDPerJob)")
struct SSDPerJobEnforceBatchTests {

    @Test("a budget drop is planned from ONE snapshot per store and unlinked in ONE batch per store, globally oldest-first")
    func enforcePlansOnceAndKeepsGlobalLRU() {
        let root = perJobTempRoot("enforce-batch")
        defer { try? FileManager.default.removeItem(at: root) }
        // Two stores, 1,000 × 1 KiB each, interleaved recency (A at even
        // seconds, B at odd): the global LRU order alternates stores.
        let a = CountingEvictableStore(
            root: root.appendingPathComponent("a"),
            entries: (0 ..< 1_000).map { (enforceTag(0xa, $0), Int64(2 * $0), 1_024) })
        let b = CountingEvictableStore(
            root: root.appendingPathComponent("b"),
            entries: (0 ..< 1_000).map { (enforceTag(0xb, $0), Int64(2 * $0 + 1), 1_024) })
        let budget = SSDDiskBudget()
        budget.register(a)
        budget.register(b)

        // Budget halves: the 1,000 globally-oldest entries go — 500 from
        // each store, exactly entries 0..<500, in oldest-first order.
        #expect(budget.enforce(budgetBytes: 1_000 * 1_024) == 1_000)
        #expect(budget.totalBytes == 1_000 * 1_024)
        #expect(budget.evictionCount == 1_000)
        #expect(a.count == 500 && b.count == 500)
        #expect(a.evictedTags == (0 ..< 500).map { enforceTag(0xa, $0) })
        #expect(b.evictedTags == (0 ..< 500).map { enforceTag(0xb, $0) })
        #expect(a.snapshotCalls == 1 && b.snapshotCalls == 1, "one snapshot per store, not one per victim")
        #expect(a.evictCalls == 1 && b.evictCalls == 1, "one batch per store, not one bracket per victim")

        // Under budget: no snapshot, no bracket.
        #expect(budget.enforce(budgetBytes: 1_000 * 1_024) == 0)
        #expect(a.snapshotCalls == 1 && a.evictCalls == 1)
    }

    @Test("an undeletable oldest entry is skipped, a store with nothing deletable is excluded, and the call still terminates under budget")
    func undeletableVictimsDoNotWedge() {
        let root = perJobTempRoot("enforce-undeletable")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = CountingEvictableStore(
            root: root.appendingPathComponent("a"),
            entries: (0 ..< 10).map { (enforceTag(0xa, $0), Int64($0), 1_024) })
        a.undeletable = [enforceTag(0xa, 0)]
        let b = CountingEvictableStore(
            root: root.appendingPathComponent("b"),
            entries: (0 ..< 10).map { (enforceTag(0xb, $0), Int64(100 + $0), 1_024) })
        let budget = SSDDiskBudget()
        budget.register(a)
        budget.register(b)

        // 20 entries against a 12-entry budget: pass 1 plans A's 0..7,
        // frees 1..7 (0 is undeletable); pass 2 re-plans A's 0 alone, frees
        // nothing → A excluded; pass 3 takes B's oldest. Never a wedge.
        #expect(budget.enforce(budgetBytes: 12 * 1_024) == 8)
        #expect(budget.totalBytes <= 12 * 1_024)
        #expect(a.count == 3)
        #expect(b.count == 9)
        #expect(b.evictedTags == [enforceTag(0xb, 0)])
        #expect(a.evictCalls == 2 && b.evictCalls == 1)

        // Nothing deletable anywhere: returns (over budget) instead of
        // spinning.
        let stuck = CountingEvictableStore(
            root: root.appendingPathComponent("stuck"),
            entries: (0 ..< 5).map { (enforceTag(0xc, $0), Int64($0), 1_024) })
        stuck.undeletable = Set((0 ..< 5).map { enforceTag(0xc, $0) })
        let stuckBudget = SSDDiskBudget()
        stuckBudget.register(stuck)
        #expect(stuckBudget.enforce(budgetBytes: 2 * 1_024) == 0)
        #expect(stuck.count == 5)
        #expect(stuck.evictCalls == 1)
    }

    @Test("a real store unlinks a 600-victim plan in 3 brackets of 256, not 600")
    func realStoreBatchesBrackets() throws {
        let root = perJobTempRoot("enforce-real")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("aaaaaaaaaaaa", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: dir)
        let config = SSDPrefixCache.Config(
            modelId: "batch-model",
            promptContractID: "contract",
            weightHash: "weights",
            blockSize: 8,
            adoptionBoundTokens: 0,
            layoutEpoch: SSDBlockStore.layoutEpoch(blockSize: 8, layerKinds: perJobLayerKinds),
            root: dir,
            ttlSeconds: 900,
            minEffectiveTokens: 8,
            maxStageBytes: 1 << 30,
            maxStageMillis: 1_000_000,
            nowSeconds: { 10_000 })
        let budget = SSDDiskBudget()
        let cache = SSDPrefixCache(
            config: config,
            kekKey: SymmetricKey(size: .bits256),
            kvBudget: nil,
            diskBudget: budget,
            maxWriteBytesPerDay: 0,
            strictFsync: false,
            diskBudgetBytes: { Int.max })
        defer { cache.close() }

        // 700 indexed regular files (the path guard checks the pathname
        // grammar and a no-follow regular-file status, not the format).
        let payload = Data(repeating: 1, count: 512)
        var urls: [URL] = []
        for i in 0 ..< 700 {
            let tag = enforceTag(0xd, i)
            let url = SSDBlockStore.fileURL(root: dir, tag16Hex: SSDLookupKeys.hex(tag))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: url)
            cache.index.insert(tag16: tag, fileBytes: payload.count, lastAccess: Int64(i))
            urls.append(url)
        }
        let bracketsBefore = cache.destructiveBracketsOpenedForTesting

        #expect(budget.enforce(budgetBytes: 100 * payload.count) == 600)
        #expect(cache.index.count == 100)
        #expect(cache.index.totalBytes == 100 * payload.count)
        #expect(
            cache.destructiveBracketsOpenedForTesting - bracketsBefore
                == 600 / SSDPrefixCache.evictionBracketVictims + 1)
        // The 600 oldest files are gone, the 100 newest remain.
        #expect(urls.prefix(600).allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(urls.suffix(100).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(cache.stats().evictions == 600)
    }
}
