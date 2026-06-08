import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// P3 tests for the orchestration actor: RAM hit, full SSD round-trip
// (store -> flush -> clear RAM -> lookup hits SSD), the MB-1 model-
// binding guard on the SSD path, the capability gate, and miss.

private let H = 2, D = 4

private func attnCaches(layers: Int, tokens: Int) -> [any KVCache] {
    (0..<layers).map { l in
        let c = KVCacheSimple()
        let k = MLXArray((0..<(H * tokens * D)).map { Float($0 + l * 7) }, [1, H, tokens, D])
        let v = MLXArray((0..<(H * tokens * D)).map { Float($0 + l * 7) + 100 }, [1, H, tokens, D])
        _ = c.update(keys: k, values: v)
        eval(c.innerState())
        return c
    }
}

private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-mgr-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func binding(model: String, layers: Int = 2) -> PrefixCacheModelBinding {
    PrefixCacheModelBinding(
        modelHash: model, modelDtype: "float32", modelArch: "Llama", vocabSize: 1000,
        numLayers: layers, kvHeads: H, headDim: D
    )
}

private func makeManager(
    model: String, layers: Int = 2, ssd: Bool, dir: URL? = nil
) -> (PrefixCacheManager, URL) {
    let cacheDir = dir ?? tmpDir()
    let mgr = PrefixCacheManager(
        binding: binding(model: model, layers: layers),
        ram: PrefixCacheRAM(),
        index: ssd ? PrefixCacheIndex(fileURL: cacheDir.appendingPathComponent("index.json")) : nil,
        kek: ssd ? KVCacheKEK(wrapper: InMemoryKeyWrappingService(),
                              storage: InMemoryWrappedKEKStorage(identifier: UUID().uuidString)) : nil,
        cacheDir: ssd ? cacheDir : nil,
        ssdEnabled: ssd,
        boundaries: [4, 8],  // small checkpoints for testing
        now: { 1000 },
        modelKey: "test-model"
    )
    return (mgr, cacheDir)
}

// A prompt whose first 8 tokens are a stable checkpoint.
private func prompt(_ n: Int) -> [Int] { Array(0..<n) }

// Lock-guarded incrementing clock for a @Sendable `now` closure in tests.
private final class MonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Int64
    init(start: Int64) { t = start }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ by: Int64) { lock.lock(); t += by; lock.unlock() }
}

@Test
func managerRamHitRoundtrip() async {
    let (mgr, _) = makeManager(model: "m", ssd: false)
    let tokens = prompt(10)  // checkpoints 4 and 8 apply

    #expect(await mgr.lookup(tokens: tokens) == nil)  // cold

    await mgr.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))

    let hit = await mgr.lookup(tokens: tokens)
    #expect(hit?.tier == .ram)
    #expect(hit?.tokenCount == 8)
    #expect(hit?.caches.count == 2)
    let stats = await mgr.snapshotStats()
    #expect(stats.ramHits == 1)
    #expect(stats.stores == 1)
}

@Test
func managerLongestCheckpointWins() async {
    let (mgr, _) = makeManager(model: "m", ssd: false)
    let tokens = prompt(10)
    await mgr.store(tokens: tokens, checkpointLength: 4, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 4)))
    await mgr.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))

    let hit = await mgr.lookup(tokens: tokens)
    #expect(hit?.tokenCount == 8, "longest cached checkpoint (8) should win over 4")
}

@Test
func managerFullSSDRoundtrip() async throws {
    let (mgr, _) = makeManager(model: "m", ssd: true)
    #expect(await mgr.isSSDEnabled == true)
    let tokens = prompt(10)

    await mgr.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    let written = await mgr.flushToSSD()
    #expect(written == 1, "one RAM entry should flush to SSD")

    // Drop RAM so the next lookup must come from SSD.
    await mgr.clearRAM()

    let hit = await mgr.lookup(tokens: tokens)
    #expect(hit?.tier == .ssd, "after clearing RAM, lookup must hit SSD")
    #expect(hit?.tokenCount == 8)
    #expect(hit?.caches.count == 2)

    // SSD hit promotes back into RAM.
    let hit2 = await mgr.lookup(tokens: tokens)
    #expect(hit2?.tier == .ram, "SSD hit should have promoted into RAM")

    let stats = await mgr.snapshotStats()
    #expect(stats.ssdHits == 1)
    #expect(stats.ssdFlushes == 1)
}

@Test
func managerEnforcesDiskBudgetWithEviction() async throws {
    // Partner-stability gate: the checkpoint SSD tier must bound on-disk
    // usage under sustained diverse-prompt traffic, evicting low-value
    // checkpoints (file + index entry) rather than growing forever. (As of
    // TB-016 eviction is benefit-per-byte, not pure LRU; for these fixtures
    // the lowest-benefit entries coincide with the least-recently-hit ones.)
    let dir = tmpDir()
    let ext = EncryptedKVStore.fileExtension
    func fileCount() throws -> Int {
        try FileManager.default
            .contentsOfDirectory(at: dir.appendingPathComponent("m"),
                                 includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasSuffix(".\(ext)") }.count
    }
    func totalBytes() throws -> Int {
        try FileManager.default
            .contentsOfDirectory(at: dir.appendingPathComponent("m"),
                                 includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasSuffix(".\(ext)") }
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // First, measure one checkpoint file's size with an unbounded manager.
    let probe = PrefixCacheManager(
        binding: binding(model: "m"), ram: PrefixCacheRAM(),
        index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("probe.json")),
        kek: KVCacheKEK(wrapper: InMemoryKeyWrappingService(),
                        storage: InMemoryWrappedKEKStorage(identifier: "probe")),
        cacheDir: dir, ssdEnabled: true, boundaries: [8], diskBudgetBytes: 0, now: { 1 })
    await probe.store(tokens: Array(0..<10), checkpointLength: 8,
                      caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    _ = await probe.flushToSSD()
    let oneFile = try totalBytes()
    #expect(oneFile > 0)
    // Clear the probe's files so the budgeted run starts clean.
    try FileManager.default.removeItem(at: dir.appendingPathComponent("m"))

    // Budgeted manager: hold ~2 files. now() increments so LRU order is
    // well-defined (earlier stores are less-recently-hit).
    let clock = MonotonicClock(start: 100)
    let budget = oneFile * 2 + oneFile / 2  // 2.5 files
    let mgr = PrefixCacheManager(
        binding: binding(model: "m"), ram: PrefixCacheRAM(),
        index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
        kek: KVCacheKEK(wrapper: InMemoryKeyWrappingService(),
                        storage: InMemoryWrappedKEKStorage(identifier: "budget")),
        cacheDir: dir, ssdEnabled: true, boundaries: [8],
        diskBudgetBytes: budget, now: { clock.value })

    // Store + flush 5 DISTINCT prompts (distinct digests → distinct files).
    for i in 0..<5 {
        clock.advance(10)
        let toks = Array((i * 100)..<(i * 100 + 10))
        await mgr.store(tokens: toks, checkpointLength: 8,
                        caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
        _ = await mgr.flushToSSD()
    }

    let bytes = try totalBytes()
    let files = try fileCount()
    #expect(bytes <= budget, "on-disk bytes \(bytes) must stay within budget \(budget)")
    #expect(files < 5, "older checkpoints must have been evicted (got \(files))")
    #expect(files >= 1, "the most-recent checkpoint(s) must survive")
    let stats = await mgr.snapshotStats()
    #expect(stats.diskEvictions > 0, "eviction must have run")
}

@Test
func managerCoalescesIndexSavesButFlushIndexNowForces() async throws {
    // index.save() is O(N) (full re-encode + atomic write + fsync) and must
    // NOT run on every flush (it head-of-line-blocks lookups on the actor).
    // A handful of flushes below the coalesce threshold leave index.json
    // unwritten; flushIndexNow() forces durability (called on teardown).
    let dir = tmpDir()
    let indexURL = dir.appendingPathComponent("index.json")
    func mgr() -> PrefixCacheManager {
        PrefixCacheManager(
            binding: binding(model: "m"), ram: PrefixCacheRAM(),
            index: PrefixCacheIndex(fileURL: indexURL),
            kek: KVCacheKEK(wrapper: InMemoryKeyWrappingService(),
                            storage: InMemoryWrappedKEKStorage(identifier: "coalesce")),
            cacheDir: dir, ssdEnabled: true, boundaries: [8], now: { 1000 })
    }
    let m = mgr()
    // Two distinct writes (< threshold 8) → files written, index NOT yet saved.
    for i in 0..<2 {
        await m.store(tokens: Array((i * 50)..<(i * 50 + 10)), checkpointLength: 8,
                      caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
        _ = await m.flushToSSD()
    }
    #expect(!FileManager.default.fileExists(atPath: indexURL.path),
            "index.json must NOT be written before the coalesce threshold")

    await m.flushIndexNow()
    #expect(FileManager.default.fileExists(atPath: indexURL.path),
            "flushIndexNow must force the index to disk")
}

@Test
func managerSSDPersistsAcrossManagerInstances() async throws {
    // Simulate a restart: flush with one manager, then a fresh manager
    // (same dir) must find the entry on SSD.
    let dir = tmpDir()
    let model = "m"
    let kekStorage = InMemoryWrappedKEKStorage(identifier: "shared-restart")
    let wrapper = InMemoryKeyWrappingService(key: .init(data: Data(repeating: 7, count: 32)), identifier: "shared")

    func mgr() -> PrefixCacheManager {
        PrefixCacheManager(
            binding: binding(model: model),
            ram: PrefixCacheRAM(),
            index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
            kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
            cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
        )
    }

    let tokens = prompt(10)
    let writer = mgr()
    await writer.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    _ = await writer.flushToSSD()
    try await writer.indexSaveForTest()

    // Fresh manager, fresh RAM — only SSD + index on disk remain.
    let reader = mgr()
    let hit = await reader.lookup(tokens: tokens)
    #expect(hit?.tier == .ssd, "a fresh manager must load the prefix from SSD")
    #expect(hit?.tokenCount == 8)
}

@Test
func managerReconcileReindexesOrphanFilesAndDropsMissing() async throws {
    // Crash-consistency: index save-coalescing means a crash can leave a
    // .darkbloom-kv file on disk that index.json never recorded (orphan).
    // reconcileWithDisk (run at load) must re-index such orphans so they
    // (a) become reusable and (b) count toward the disk budget instead of
    // leaking — and must drop index entries whose file vanished.
    let dir = tmpDir()
    let kekStorage = InMemoryWrappedKEKStorage(identifier: "reconcile")
    let wrapper = InMemoryKeyWrappingService(key: .init(data: Data(repeating: 4, count: 32)), identifier: "reconcile")
    let indexURL = dir.appendingPathComponent("index.json")
    func mgr() -> PrefixCacheManager {
        PrefixCacheManager(
            binding: binding(model: "m"), ram: PrefixCacheRAM(),
            index: PrefixCacheIndex(fileURL: indexURL),
            kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
            cacheDir: dir, ssdEnabled: true, boundaries: [8], now: { 1000 })
    }
    let tokens = prompt(10)

    // Write + persist a checkpoint, then DELETE index.json to simulate a
    // crash inside the coalescing window (file fsynced, index not yet saved).
    let writer = mgr()
    await writer.store(tokens: tokens, checkpointLength: 8,
                       caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    _ = await writer.flushToSSD()
    await writer.flushIndexNow()
    let kvFile = dir.appendingPathComponent("m/\(PrefixDigest.digest(tokens: tokens, length: 8).dbkvHexString).\(EncryptedKVStore.fileExtension)")
    #expect(FileManager.default.fileExists(atPath: kvFile.path), "precondition: KV file written")
    try FileManager.default.removeItem(at: indexURL)  // orphan the file

    // Fresh manager reconciles at load → re-indexes the orphan → it serves.
    let reader = mgr()
    await reader.reconcileWithDisk()
    let hit = await reader.lookup(tokens: tokens)
    #expect(hit?.tier == .ssd, "reconcile must re-index the orphan file so it serves from SSD")
    #expect(hit?.tokenCount == 8)

    // Reverse: delete the file, reconcile again → stale index entry dropped,
    // lookup is a clean miss (no crash, no dangling entry).
    try FileManager.default.removeItem(at: kvFile)
    await reader.clearRAM()
    let reader2 = mgr()
    await reader2.reconcileWithDisk()
    #expect(await reader2.lookup(tokens: tokens) == nil, "missing-file entry must be dropped, lookup is a clean miss")
}

@Test
func managerMB1RejectsCrossModelFile() async throws {
    // Write a file under model A, then point a model-B manager at the
    // SAME dir/index and confirm the MB-1 guard refuses A's file.
    let dir = tmpDir()
    let kekStorage = InMemoryWrappedKEKStorage(identifier: "mb1")
    let wrapper = InMemoryKeyWrappingService(key: .init(data: Data(repeating: 9, count: 32)), identifier: "mb1")
    let indexURL = dir.appendingPathComponent("index.json")

    let tokens = prompt(10)
    let mgrA = PrefixCacheManager(
        binding: binding(model: "modelA"), ram: PrefixCacheRAM(),
        index: PrefixCacheIndex(fileURL: indexURL),
        kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
        cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    await mgrA.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    _ = await mgrA.flushToSSD()
    try await mgrA.indexSaveForTest()

    // Model B, same backing store. The index entry exists, but the file's
    // metadata.modelHash == "modelA" != "modelB" → MB-1 must reject.
    let mgrB = PrefixCacheManager(
        binding: binding(model: "modelB"), ram: PrefixCacheRAM(),
        index: PrefixCacheIndex(fileURL: indexURL),
        kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
        cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    // modelB has no entries of its own; index is model-scoped so B sees nothing.
    let hit = await mgrB.lookup(tokens: tokens)
    #expect(hit == nil, "model B must not load model A's prefix (index is model-scoped)")
}

@Test
func managerMB1RejectsTamperedModelHashInIndex() async throws {
    // MB-1: two model ids that COLLIDE in the 12-char model-dir prefix share
    // an on-disk cache directory, so model B's deterministic path resolves
    // to model A's file. The metadata equality guard — not the crypto — must
    // reject it. (loadFromSSD reconstructs the path from the binding, so a
    // cross-dir pointer in the index can no longer be forged; the residual
    // way a wrong-model file lands at B's path is this dir-prefix collision.)
    let dir = tmpDir()
    let kekStorage = InMemoryWrappedKEKStorage(identifier: "mb1b")
    let wrapper = InMemoryKeyWrappingService(key: .init(data: Data(repeating: 3, count: 32)), identifier: "mb1b")
    let indexURL = dir.appendingPathComponent("index.json")
    let tokens = prompt(10)
    let modelA = "samedir01234A", modelB = "samedir01234B"  // share the 12-char modelDirComponent

    let mgrA = PrefixCacheManager(
        binding: binding(model: modelA), ram: PrefixCacheRAM(),
        index: PrefixCacheIndex(fileURL: indexURL),
        kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
        cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    await mgrA.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    _ = await mgrA.flushToSSD()

    // Model B references the same digest; its deterministic path (shared
    // dir) resolves to A's file. relativePath is ignored by loadFromSSD.
    let bIndex = PrefixCacheIndex(fileURL: dir.appendingPathComponent("indexB.json"))
    let digest = PrefixDigest.digest(tokens: tokens, length: 8).dbkvHexString
    bIndex.record(PrefixIndexEntry(
        modelHash: modelB, digestHex: digest, tokenCount: 8,
        relativePath: "ignored", fileBytes: 0, createdAt: 1000, lastHitAt: 1000
    ))

    let mgrB = PrefixCacheManager(
        binding: binding(model: modelB), ram: PrefixCacheRAM(),
        index: bIndex, kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
        cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    let hit = await mgrB.lookup(tokens: tokens)
    #expect(hit == nil, "MB-1 metadata guard must reject A's file served to model B")
    let stats = await mgrB.snapshotStats()
    #expect(stats.modelMismatches == 1, "the mismatch must be counted by the MB-1 guard")
}

@Test
func managerRejectsStaleIndexPrefixHashMismatch() async throws {
    // Same model + same shape, but the index entry's digest does NOT match
    // the file's actual prefix hash (stale/corrupt index, or a file moved
    // under the wrong digest). The prefix-hash guard must drop it and
    // cold-prefill rather than serve a different prompt's KV.
    let dir = tmpDir()
    let kekStorage = InMemoryWrappedKEKStorage(identifier: "ph")
    let wrapper = InMemoryKeyWrappingService(key: .init(data: Data(repeating: 5, count: 32)), identifier: "ph")
    let indexURL = dir.appendingPathComponent("index.json")

    // mgrA writes a real file for tokensA@8 + its index entry.
    let tokensA = prompt(10)
    let tokensB = Array(100..<110)
    let mgrA = PrefixCacheManager(
        binding: binding(model: "m"), ram: PrefixCacheRAM(),
        index: PrefixCacheIndex(fileURL: indexURL),
        kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
        cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    await mgrA.store(tokens: tokensA, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    _ = await mgrA.flushToSSD()

    // On-disk swap: copy A's file to B's digest path WITHIN the same model
    // dir, so B's deterministic path resolves to a file whose actual
    // tokenPrefixHash is A's. (loadFromSSD reconstructs the path from the
    // digest, so this same-dir swap — not a cross-file index pointer — is
    // the residual way a wrong-prefix file reaches the load.)
    let ext = EncryptedKVStore.fileExtension
    let aDigest = PrefixDigest.digest(tokens: tokensA, length: 8).dbkvHexString
    let bDigest = PrefixDigest.digest(tokens: tokensB, length: 8).dbkvHexString
    let aFile = dir.appendingPathComponent("m/\(aDigest).\(ext)")
    let bFile = dir.appendingPathComponent("m/\(bDigest).\(ext)")
    try FileManager.default.copyItem(at: aFile, to: bFile)

    let bIndex = PrefixCacheIndex(fileURL: dir.appendingPathComponent("indexB.json"))
    bIndex.record(PrefixIndexEntry(
        modelHash: "m", digestHex: bDigest, tokenCount: 8,
        relativePath: "ignored", fileBytes: 0, createdAt: 1000, lastHitAt: 1000
    ))

    let mgrB = PrefixCacheManager(
        binding: binding(model: "m"), ram: PrefixCacheRAM(),
        index: bIndex, kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
        cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    let hit = await mgrB.lookup(tokens: tokensB)
    #expect(hit == nil, "stale-index prefix-hash mismatch must be rejected")
    let stats = await mgrB.snapshotStats()
    #expect(stats.prefixHashMismatches == 1, "the mismatch must be counted")
}

@Test
func managerIgnoresMaliciousIndexRelativePath() async throws {
    // The on-disk index JSON is plaintext and unauthenticated, so a tampered
    // entry.relativePath could contain "../" and escape the cache dir. The
    // manager must reconstruct the path deterministically from the trusted
    // binding + digest and IGNORE the stored relativePath — so a poisoned
    // path neither escapes the sandbox nor breaks a legitimate hit.
    let dir = tmpDir()
    let kekStorage = InMemoryWrappedKEKStorage(identifier: "trav")
    let wrapper = InMemoryKeyWrappingService(key: .init(data: Data(repeating: 6, count: 32)), identifier: "trav")
    let indexURL = dir.appendingPathComponent("index.json")
    let tokens = prompt(10)

    // Write a real file + index entry at the deterministic in-sandbox path.
    let mgrA = PrefixCacheManager(
        binding: binding(model: "m"), ram: PrefixCacheRAM(),
        index: PrefixCacheIndex(fileURL: indexURL),
        kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
        cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    await mgrA.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    _ = await mgrA.flushToSSD()

    // Poisoned index: same model/digest/tokenCount, but relativePath tries to
    // escape the cache dir entirely.
    let digest = PrefixDigest.digest(tokens: tokens, length: 8).dbkvHexString
    let poison = PrefixCacheIndex(fileURL: dir.appendingPathComponent("poison.json"))
    poison.record(PrefixIndexEntry(
        modelHash: "m", digestHex: digest, tokenCount: 8,
        relativePath: "../../../../../../etc/shadow", fileBytes: 0, createdAt: 1000, lastHitAt: 1000
    ))

    let mgrB = PrefixCacheManager(
        binding: binding(model: "m"), ram: PrefixCacheRAM(),
        index: poison, kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
        cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    // The deterministic path resolves to the real in-sandbox file → hit; the
    // poisoned relativePath is never touched.
    let hit = await mgrB.lookup(tokens: tokens)
    #expect(hit != nil, "manager must serve from the deterministic in-sandbox path, ignoring relativePath")
    #expect(await mgrB.snapshotStats().ssdReadErrors == 0, "must not attempt the escaped path")
}

@Test
func managerSSDDisabledWhenBackingMissing() async {
    // ssdEnabled requested but no index/kek/dir → manager is RAM-only.
    let mgr = PrefixCacheManager(
        binding: binding(model: "m"), ram: PrefixCacheRAM(),
        index: nil, kek: nil, cacheDir: nil, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    #expect(await mgr.isSSDEnabled == false, "SSD must be disabled without index/kek/dir")
    let written = await mgr.flushToSSD()
    #expect(written == 0)
}

@Test
func managerMissOnShortPrompt() async {
    let (mgr, _) = makeManager(model: "m", ssd: false)
    // Prompt shorter than the smallest checkpoint (4) → no checkpoints.
    let hit = await mgr.lookup(tokens: [1, 2])
    #expect(hit == nil)
    #expect(await mgr.snapshotStats().misses == 1)
}

// MARK: - helpers

// Test-only helper to persist the index (the manager saves on flush, but
// tests that build a second instance want an explicit save point).
extension PrefixCacheManager {
    func indexSaveForTest() async throws {
        // Index saves are now COALESCED (every N writes) to keep the O(N)
        // re-encode off the hot path; restart-style tests must force the
        // durability barrier that production calls on teardown.
        await flushIndexNow()
    }
}

// MARK: - Per-tenant scope isolation (TB-007 checkpoint tier)

// Production flow: lookup(scope:) records the request's scope, then the
// capture-hook store() recovers it. These tests mirror that order (lookup then
// store) so store() stamps the right scope.

@Test
func managerScopedRamHitSameScope() async {
    let (mgr, _) = makeManager(model: "m", ssd: false)
    let tokens = prompt(10)
    _ = await mgr.lookup(tokens: tokens, scope: "tenant-A")  // cold miss, records scope
    await mgr.store(tokens: tokens, checkpointLength: 8,
                    caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    // Same scope ⇒ hit.
    let hit = await mgr.lookup(tokens: tokens, scope: "tenant-A")
    #expect(hit?.tier == .ram)
    #expect(hit?.tokenCount == 8)
}

@Test
func managerScopedRamMissDifferentScope() async {
    let (mgr, _) = makeManager(model: "m", ssd: false)
    let tokens = prompt(10)
    _ = await mgr.lookup(tokens: tokens, scope: "tenant-A")
    await mgr.store(tokens: tokens, checkpointLength: 8,
                    caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    // Different scope, identical tokens ⇒ MISS (cross-tenant isolation).
    let miss = await mgr.lookup(tokens: tokens, scope: "tenant-B")
    #expect(miss == nil, "tenant B must not hit tenant A's scoped checkpoint")
    // Unscoped lookup of the same tokens also misses a scoped entry.
    let unscopedMiss = await mgr.lookup(tokens: tokens, scope: "")
    #expect(unscopedMiss == nil, "unscoped lookup must not hit a scoped checkpoint")
}

@Test
func managerUnscopedAndScopedDoNotCross() async {
    let (mgr, _) = makeManager(model: "m", ssd: false)
    let tokens = prompt(10)
    // Store UNSCOPED (legacy behavior).
    await mgr.store(tokens: tokens, checkpointLength: 8,
                    caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    #expect(await mgr.lookup(tokens: tokens, scope: "") != nil, "unscoped hits unscoped")
    #expect(await mgr.lookup(tokens: tokens, scope: "tenant-A") == nil,
            "a scoped lookup must not hit the unscoped checkpoint")
}

@Test
func managerScopedSSDRoundtripAndIsolation() async throws {
    let (mgr, _) = makeManager(model: "m", ssd: true)
    let tokens = prompt(10)
    _ = await mgr.lookup(tokens: tokens, scope: "tenant-A")   // records scope
    await mgr.store(tokens: tokens, checkpointLength: 8,
                    caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    _ = await mgr.flushToSSD()
    // Wipe RAM so the next hit must come from SSD (decrypt path).
    await mgr.clearRAM()
    // Same scope ⇒ SSD hit.
    let hit = await mgr.lookup(tokens: tokens, scope: "tenant-A")
    #expect(hit?.tier == .ssd, "same-scope lookup should reload from SSD")
    // Different scope ⇒ SSD miss (the scoped digest never matches B's index key).
    let miss = await mgr.lookup(tokens: tokens, scope: "tenant-B")
    #expect(miss == nil, "tenant B must not reload tenant A's SSD checkpoint")
    let stats = await mgr.snapshotStats()
    #expect(stats.ssdReadErrors == 0)
}
