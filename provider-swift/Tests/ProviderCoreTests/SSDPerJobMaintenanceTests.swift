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
