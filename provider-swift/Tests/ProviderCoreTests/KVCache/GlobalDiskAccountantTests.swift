import Foundation
import Testing
@testable import ProviderCore

// Phase 3 tests for the global disk accountant: bookkeeping, over-budget
// signals to owners, unowned dir reclaim, effective ceiling, nil-accountant
// backward compat. MODEL-FREE (no MLX, deterministic via injected closures).

// MARK: - Fake owner

private actor FakeOwner: PrefixCacheOwner {
    var evictionCalls: [(targetBytesToFree: Int, returnFreed: Int)] = []

    func evictForGlobalBudget(targetBytesToFree: Int) async -> Int {
        let freed = targetBytesToFree  // Fake: always free the exact target.
        evictionCalls.append((targetBytesToFree, freed))
        return freed
    }

    func snapshotCalls() -> [(targetBytesToFree: Int, returnFreed: Int)] { evictionCalls }
}

/// Lock-guarded Int so a @Sendable closure can read a value the test mutates
/// between accountant ticks (can't capture a plain `var` in a Sendable closure).
private final class MutableIntHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int
    init(_ initial: Int) { v = initial }
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ newValue: Int) { lock.lock(); v = newValue; lock.unlock() }
}

// MARK: - Helpers

private func tmpKVRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-accountant-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeFakeKVDir(at kvRoot: URL, modelKey: String, files: [(digestHex: String, bytes: Int)]) {
    let modelDir = kvRoot.appendingPathComponent(modelKey, isDirectory: true)
    try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    for (digestHex, bytes) in files {
        let url = modelDir.appendingPathComponent("\(digestHex).\(EncryptedKVStore.fileExtension)")
        let data = Data(repeating: 0, count: bytes)
        try? data.write(to: url)
    }
}

// MARK: - Tests

@Test
func accountantRegisterUpdateDeregisterBookkeeping() async {
    let kvRoot = tmpKVRoot()
    let accountant = GlobalDiskAccountant(kvRoot: kvRoot, configuredCeiling: 10000)
    let owner1 = FakeOwner()
    let owner2 = FakeOwner()

    // Register two models.
    let token1 = await accountant.register(modelKey: "model1", owner: owner1)
    let token2 = await accountant.register(modelKey: "model2", owner: owner2)

    // Push usage for both.
    await accountant.updateUsage(modelKey: "model1", totalBytes: 1000, valueSummary: [])
    await accountant.updateUsage(modelKey: "model2", totalBytes: 2000, valueSummary: [])

    // Global total should be 3000 (under ceiling, no evictions).
    let calls1 = await owner1.snapshotCalls()
    let calls2 = await owner2.snapshotCalls()
    #expect(calls1.isEmpty, "no evictions when under budget")
    #expect(calls2.isEmpty, "no evictions when under budget")

    // Deregister model1 (flips to unowned).
    await accountant.deregister(token1)

    // Push usage for model2 again (still under ceiling).
    await accountant.updateUsage(modelKey: "model2", totalBytes: 2500, valueSummary: [])
    let calls2b = await owner2.snapshotCalls()
    #expect(calls2b.isEmpty, "still under budget after deregister")

    // Deregister model2.
    await accountant.deregister(token2)

    try? FileManager.default.removeItem(at: kvRoot)
}

@Test
func accountantOverBudgetSignalsOwner() async {
    let kvRoot = tmpKVRoot()
    let ceiling = 5000
    let accountant = GlobalDiskAccountant(kvRoot: kvRoot, configuredCeiling: ceiling)
    let owner1 = FakeOwner()
    let owner2 = FakeOwner()

    _ = await accountant.register(modelKey: "model1", owner: owner1)
    _ = await accountant.register(modelKey: "model2", owner: owner2)

    // Push usage totaling 6000 (over ceiling 5000).
    // Model1 has lower-score entries than model2.
    let summary1 = [
        EntryValue(modelKey: "model1", digestHex: "a", fileBytes: 1000, score: 0.1, fileURL: nil),
        EntryValue(modelKey: "model1", digestHex: "b", fileBytes: 2000, score: 0.2, fileURL: nil),
    ]
    let summary2 = [
        EntryValue(modelKey: "model2", digestHex: "c", fileBytes: 3000, score: 0.5, fileURL: nil),
    ]
    await accountant.updateUsage(modelKey: "model1", totalBytes: 3000, valueSummary: summary1)
    await accountant.updateUsage(modelKey: "model2", totalBytes: 3000, valueSummary: summary2)

    // Accountant should evict LOWEST-score entries first: model1's "a" (score 0.1).
    // Target to free = 6000 - 5000 = 1000.
    let calls1 = await owner1.snapshotCalls()
    let calls2 = await owner2.snapshotCalls()
    #expect(calls1.count == 1, "model1 should be signaled to evict")
    #expect(calls1.first?.targetBytesToFree == 1000, "model1 should free 1000 bytes")
    #expect(calls2.isEmpty, "model2 has higher-score entries, not chosen")

    try? FileManager.default.removeItem(at: kvRoot)
}

@Test
func accountantUnownedDirReclaim() async {
    let kvRoot = tmpKVRoot()
    let ceiling = 2000
    // Injected fake free-bytes probe (always returns 10000).
    let accountant = GlobalDiskAccountant(
        kvRoot: kvRoot, configuredCeiling: ceiling, tickSeconds: 1,
        freeBytes: { _ in 10000 }
    )

    // Create an UNOWNED dir (no registered owner) with files totaling 3000 bytes.
    makeFakeKVDir(at: kvRoot, modelKey: "unowned1", files: [
        ("aaa", 1000),
        ("bbb", 2000),
    ])

    // Trigger a tick (scan unowned dirs).
    await accountant.tick()

    // Accountant should have deleted files to get under ceiling (2000).
    let modelDir = kvRoot.appendingPathComponent("unowned1", isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
    let totalBytes = files.reduce(0) { accum, name in
        let url = modelDir.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return accum + size
    }
    #expect(totalBytes <= ceiling, "unowned dir should be evicted to stay under ceiling")

    try? FileManager.default.removeItem(at: kvRoot)
}

@Test
func accountantEffectiveCeilingConfiguredVsDerived() async {
    let kvRoot = tmpKVRoot()

    // Explicit ceiling (configuredCeiling > 0): used as global cap.
    let accountant1 = GlobalDiskAccountant(kvRoot: kvRoot, configuredCeiling: 8000)
    let owner1 = FakeOwner()
    _ = await accountant1.register(modelKey: "model1", owner: owner1)
    let summary1 = [
        EntryValue(modelKey: "model1", digestHex: "x", fileBytes: 5000, score: 0.1, fileURL: nil),
    ]
    await accountant1.updateUsage(modelKey: "model1", totalBytes: 9000, valueSummary: summary1)
    let calls1 = await owner1.snapshotCalls()
    #expect(!calls1.isEmpty, "explicit ceiling should enforce budget")

    // Derived ceiling (configuredCeiling = 0): min(10GiB, free/2).
    // Injected freeBytes returns 4000, so derived = min(10GiB, 2000) = 2000.
    let accountant2 = GlobalDiskAccountant(
        kvRoot: tmpKVRoot(), configuredCeiling: 0, tickSeconds: 30,
        freeBytes: { _ in 4000 }
    )
    let owner2 = FakeOwner()
    _ = await accountant2.register(modelKey: "model2", owner: owner2)
    let summary2 = [
        EntryValue(modelKey: "model2", digestHex: "y", fileBytes: 1500, score: 0.1, fileURL: nil),
    ]
    await accountant2.updateUsage(modelKey: "model2", totalBytes: 3000, valueSummary: summary2)
    let calls2 = await owner2.snapshotCalls()
    #expect(!calls2.isEmpty, "derived ceiling (free/2) should enforce budget")

    try? FileManager.default.removeItem(at: kvRoot)
}

@Test
func accountantGloballyLowestScoreAcrossTwoModels() async {
    let kvRoot = tmpKVRoot()
    let ceiling = 5000
    let accountant = GlobalDiskAccountant(kvRoot: kvRoot, configuredCeiling: ceiling)
    let owner1 = FakeOwner()
    let owner2 = FakeOwner()

    _ = await accountant.register(modelKey: "model1", owner: owner1)
    _ = await accountant.register(modelKey: "model2", owner: owner2)

    // Model1 has one low-score entry (0.05), model2 has one slightly-higher (0.1).
    // Total = 6000 (over ceiling 5000). Accountant should pick model1's entry first.
    let summary1 = [
        EntryValue(modelKey: "model1", digestHex: "a", fileBytes: 3000, score: 0.05, fileURL: nil),
    ]
    let summary2 = [
        EntryValue(modelKey: "model2", digestHex: "b", fileBytes: 3000, score: 0.1, fileURL: nil),
    ]
    await accountant.updateUsage(modelKey: "model1", totalBytes: 3000, valueSummary: summary1)
    await accountant.updateUsage(modelKey: "model2", totalBytes: 3000, valueSummary: summary2)

    let calls1 = await owner1.snapshotCalls()
    let calls2 = await owner2.snapshotCalls()
    #expect(calls1.count == 1, "model1 has the globally lowest score, should be signaled")
    // The global over-budget delta is 1000 (6000-5000), but eviction is
    // whole-file: the lowest-score victim is model1's single 3000-byte entry,
    // and you can't free a fraction of a file — so the owner is asked to free
    // that entry's full 3000 bytes (which satisfies the 1000 target).
    #expect(calls1.first?.targetBytesToFree == 3000,
            "owner is asked to free the chosen victim entry's full size (3000)")
    #expect(calls2.isEmpty, "model2's entry has higher score, not chosen")

    try? FileManager.default.removeItem(at: kvRoot)
}

@Test
func accountantOwnedVsUnownedMix() async {
    let kvRoot = tmpKVRoot()
    let ceiling = 4000
    let accountant = GlobalDiskAccountant(
        kvRoot: kvRoot, configuredCeiling: ceiling, tickSeconds: 1,
        freeBytes: { _ in 10000 }
    )

    // One OWNED model.
    let owner1 = FakeOwner()
    _ = await accountant.register(modelKey: "owned1", owner: owner1)
    let summary1 = [
        EntryValue(modelKey: "owned1", digestHex: "x", fileBytes: 2000, score: 0.2, fileURL: nil),
    ]
    await accountant.updateUsage(modelKey: "owned1", totalBytes: 2000, valueSummary: summary1)

    // One UNOWNED dir with files totaling 3000 bytes (lower score than owned).
    makeFakeKVDir(at: kvRoot, modelKey: "unowned1", files: [
        ("aaa", 1500),
        ("bbb", 1500),
    ])

    // Trigger tick to scan unowned dirs.
    await accountant.tick()

    // Total = 2000 (owned) + 3000 (unowned) = 5000 > ceiling 4000.
    // Accountant should evict UNOWNED files first (assumed lower score in degraded summary).
    let modelDir = kvRoot.appendingPathComponent("unowned1", isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
    let unownedBytes = files.reduce(0) { accum, name in
        let url = modelDir.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return accum + size
    }
    // The owned model should NOT be signaled (higher score).
    let calls1 = await owner1.snapshotCalls()
    #expect(calls1.isEmpty || unownedBytes < 3000, "unowned dir should be evicted before owned model")

    try? FileManager.default.removeItem(at: kvRoot)
}

@Test
func accountantTickRecomputesCeilingAndScansUnowned() async {
    let kvRoot = tmpKVRoot()
    // Injected freeBytes starts at 8000, then drops (simulating disk fill).
    // A lock-guarded holder so the @Sendable freeBytes closure can read a
    // value the test mutates between ticks (can't capture a plain `var`).
    let freeHolder = MutableIntHolder(8000)
    let accountant = GlobalDiskAccountant(
        kvRoot: kvRoot, configuredCeiling: 0, tickSeconds: 1,
        freeBytes: { _ in freeHolder.value }
    )

    // Create an unowned dir with 2000 bytes.
    makeFakeKVDir(at: kvRoot, modelKey: "unowned1", files: [
        ("x", 2000),
    ])

    // First tick: derived ceiling = min(10GiB, 8000/2) = 4000. Unowned 2000 < 4000, no eviction.
    await accountant.tick()
    let modelDir = kvRoot.appendingPathComponent("unowned1", isDirectory: true)
    let files1 = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
    #expect(files1.count > 0, "unowned dir should NOT be evicted when under ceiling")

    // Drop freeBytes to 4000 → derived ceiling = min(10GiB, 2000) = 2000.
    freeHolder.set(4000)
    // Unowned 2000 == 2000, should be at the edge (no eviction yet).
    await accountant.tick()
    let files2 = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
    #expect(files2.count > 0, "unowned dir at ceiling edge should still be present")

    // Drop freeBytes to 2000 → derived ceiling = min(10GiB, 1000) = 1000.
    freeHolder.set(2000)
    // Unowned 2000 > 1000, should evict.
    await accountant.tick()
    let files3 = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
    let totalBytes = files3.reduce(0) { accum, name in
        let url = modelDir.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return accum + size
    }
    #expect(totalBytes <= 1000, "unowned dir should be evicted to stay under recomputed ceiling")

    try? FileManager.default.removeItem(at: kvRoot)
}

// MARK: - REAL LAYOUT TESTS

/// Helper: create a CHECKPOINT-tier unowned dir with NESTED layout:
/// kvRoot/<modelKey>/<modelHash[:12]>/<digest>.darkbloom-kv + index.json
private func makeNestedCheckpointDir(
    at kvRoot: URL, modelKey: String, modelHash: String,
    files: [(digestHex: String, bytes: Int, hitCount: Int, lastHitAt: Int64)]
) {
    let modelDir = kvRoot.appendingPathComponent(modelKey, isDirectory: true)
    let modelHashShort = String(modelHash.prefix(12))
    let nestedDir = modelDir.appendingPathComponent(modelHashShort, isDirectory: true)
    try? FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)

    // Write files at the nested depth.
    for (digestHex, bytes, _, _) in files {
        let url = nestedDir.appendingPathComponent("\(digestHex).\(EncryptedKVStore.fileExtension)")
        let data = Data(repeating: 0, count: bytes)
        try? data.write(to: url)
    }

    // Build a real index.json keyed by the REAL modelHash (not modelKey).
    let indexURL = modelDir.appendingPathComponent("index.json")
    let index = PrefixCacheIndex(fileURL: indexURL)
    for (digestHex, bytes, hitCount, lastHitAt) in files {
        let relativePath = "\(modelHashShort)/\(digestHex).\(EncryptedKVStore.fileExtension)"
        let entry = PrefixIndexEntry(
            modelHash: modelHash, digestHex: digestHex, tokenCount: 1024,
            relativePath: relativePath, fileBytes: bytes,
            createdAt: lastHitAt, lastHitAt: lastHitAt, hitCount: hitCount
        )
        index.record(entry)
    }
    try? index.save()
}

@Test
func accountantUnownedCheckpointTierNestedLayout() async {
    // tick() must scan NESTED files (checkpoint tier).
    // evictUnownedEntries must use the entry's OWN modelHash, not modelKey.
    let kvRoot = tmpKVRoot()
    let ceiling = 2000
    let accountant = GlobalDiskAccountant(
        kvRoot: kvRoot, configuredCeiling: ceiling, tickSeconds: 1,
        freeBytes: { _ in 10000 }
    )

    let modelKey = "abc123456789"
    let modelHash = "sha256:fedcba9876543210"
    // Create checkpoint-tier unowned dir: 3000 bytes total, over ceiling.
    // Entry "low" has hitCount=0 (lowest score), entry "high" has hitCount=10.
    makeNestedCheckpointDir(at: kvRoot, modelKey: modelKey, modelHash: modelHash, files: [
        ("low", 1500, 0, 1000),
        ("high", 1500, 10, 2000),
    ])

    // Trigger tick: should scan nested files, sum 3000, evict lowest-score ("low").
    await accountant.tick()

    let modelDir = kvRoot.appendingPathComponent(modelKey, isDirectory: true)
    let modelHashShort = String(modelHash.prefix(12))
    let nestedDir = modelDir.appendingPathComponent(modelHashShort, isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: nestedDir.path)) ?? []

    #expect(!files.contains("low.\(EncryptedKVStore.fileExtension)"),
            "lowest-score checkpoint file should be evicted")
    #expect(files.contains("high.\(EncryptedKVStore.fileExtension)"),
            "higher-score checkpoint file should remain")

    // Verify the index.json was updated (entry removed).
    let indexURL = modelDir.appendingPathComponent("index.json")
    let index = PrefixCacheIndex(fileURL: indexURL)
    #expect(index.entry(modelHash: modelHash, digestHex: "low") == nil,
            "index entry for evicted file should be removed")
    #expect(index.entry(modelHash: modelHash, digestHex: "high") != nil,
            "index entry for kept file should remain")

    try? FileManager.default.removeItem(at: kvRoot)
}

@Test
func accountantUnownedEngineTierFlatLayout() async {
    // tick() must scan FLAT files (engine tier, no index).
    let kvRoot = tmpKVRoot()
    let ceiling = 1000
    let accountant = GlobalDiskAccountant(
        kvRoot: kvRoot, configuredCeiling: ceiling, tickSeconds: 1,
        freeBytes: { _ in 10000 }
    )

    let modelKey = "xyz987654321"
    // Create engine-tier unowned dir: flat files, NO index.json.
    makeFakeKVDir(at: kvRoot, modelKey: modelKey, files: [
        ("block1", 800),
        ("block2", 700),
    ])

    // Trigger tick: should scan flat files, sum 1500, evict oldest (mtime-LRU).
    await accountant.tick()

    let modelDir = kvRoot.appendingPathComponent(modelKey, isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
    let totalBytes = files.reduce(0) { accum, name in
        let url = modelDir.appendingPathComponent(name)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return accum + size
    }

    #expect(totalBytes <= ceiling, "engine-tier unowned dir should be evicted to stay under ceiling")

    try? FileManager.default.removeItem(at: kvRoot)
}

@Test
func accountantRegisteredEngineTierNotDeleted() async {
    // A REGISTERED engine-tier owner's live dir must NEVER be
    // directly deleted by tick — only signaled via evictForGlobalBudget.
    let kvRoot = tmpKVRoot()
    let ceiling = 1000
    let accountant = GlobalDiskAccountant(
        kvRoot: kvRoot, configuredCeiling: ceiling, tickSeconds: 1,
        freeBytes: { _ in 10000 }
    )

    let modelKey = "registered123"
    // Fake owner standing in for EncryptedPrefixCachePersistence.
    let owner = FakeOwner()
    let token = await accountant.register(modelKey: modelKey, owner: owner)

    // Create files on disk for this registered model (2000 bytes, over ceiling).
    makeFakeKVDir(at: kvRoot, modelKey: modelKey, files: [
        ("block1", 1000),
        ("block2", 1000),
    ])

    // Push usage to accountant.
    let summary = [
        EntryValue(modelKey: modelKey, digestHex: "block1", fileBytes: 1000, score: 0.1, fileURL: nil),
        EntryValue(modelKey: modelKey, digestHex: "block2", fileBytes: 1000, score: 0.2, fileURL: nil),
    ]
    await accountant.updateUsage(modelKey: modelKey, totalBytes: 2000, valueSummary: summary)

    // Trigger tick: should NOT directly delete files (registered owner).
    await accountant.tick()

    // Verify the owner was signaled (not directly deleted).
    let calls = await owner.snapshotCalls()
    #expect(!calls.isEmpty, "registered owner should be signaled to evict")

    // Verify files still exist (accountant doesn't touch them directly).
    let modelDir = kvRoot.appendingPathComponent(modelKey, isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
    #expect(files.count == 2, "registered owner's files should NOT be directly deleted by accountant")

    await accountant.deregister(token)
    try? FileManager.default.removeItem(at: kvRoot)
}
