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
        now: { 1000 }
    )
    return (mgr, cacheDir)
}

// A prompt whose first 8 tokens are a stable checkpoint.
private func prompt(_ n: Int) -> [Int] { Array(0..<n) }

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
    // Stronger MB-1: force the index to point model B at A's file (as a
    // symlink/collision would), and confirm the metadata equality guard
    // — not the crypto — rejects it.
    let dir = tmpDir()
    let kekStorage = InMemoryWrappedKEKStorage(identifier: "mb1b")
    let wrapper = InMemoryKeyWrappingService(key: .init(data: Data(repeating: 3, count: 32)), identifier: "mb1b")
    let indexURL = dir.appendingPathComponent("index.json")
    let tokens = prompt(10)

    // Write A's file + index entry.
    let mgrA = PrefixCacheManager(
        binding: binding(model: "modelA"), ram: PrefixCacheRAM(),
        index: PrefixCacheIndex(fileURL: indexURL),
        kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
        cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    await mgrA.store(tokens: tokens, checkpointLength: 8, caches: SendableKVCaches(attnCaches(layers: 2, tokens: 8)))
    _ = await mgrA.flushToSSD()
    try await mgrA.indexSaveForTest()

    // Build B's index entry pointing at A's actual file, under the
    // digest B would compute for the same tokens (digests are model-
    // independent, so they collide — exactly the symlink/collision case
    // MB-1's metadata guard exists to catch).
    let bIndex = PrefixCacheIndex(fileURL: dir.appendingPathComponent("indexB.json"))
    let aRel = try locateDBKV(in: dir)
    let bDigest = PrefixDigest.digest(tokens: tokens, length: 8).dbkvHexString
    bIndex.record(PrefixIndexEntry(
        modelHash: "modelB", digestHex: bDigest, tokenCount: 8,
        relativePath: aRel, fileBytes: 0, createdAt: 1000, lastHitAt: 1000
    ))

    let mgrB = PrefixCacheManager(
        binding: binding(model: "modelB"), ram: PrefixCacheRAM(),
        index: bIndex, kek: KVCacheKEK(wrapper: wrapper, storage: kekStorage),
        cacheDir: dir, ssdEnabled: true, boundaries: [4, 8], now: { 1000 }
    )
    let hit = await mgrB.lookup(tokens: tokens)
    #expect(hit == nil, "MB-1 metadata guard must reject A's file served to model B")
    let stats = await mgrB.snapshotStats()
    #expect(stats.modelMismatches == 1, "the mismatch must be counted by the MB-1 guard")
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

private func locateDBKV(in dir: URL) throws -> String {
    let fm = FileManager.default
    let subdirs = try fm.contentsOfDirectory(atPath: dir.path)
    for sub in subdirs {
        let subPath = dir.appendingPathComponent(sub)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: subPath.path, isDirectory: &isDir), isDir.boolValue else { continue }
        let files = try fm.contentsOfDirectory(atPath: subPath.path)
        if let f = files.first(where: { $0.hasSuffix(EncryptedKVStore.fileExtension) }) {
            return "\(sub)/\(f)"
        }
    }
    throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no .darkbloom-kv file found"])
}

// Test-only helper to persist the index (the manager saves on flush, but
// tests that build a second instance want an explicit save point).
extension PrefixCacheManager {
    func indexSaveForTest() async throws {
        // flushToSSD already calls index.save(); this is a no-op hook kept
        // for clarity in restart-style tests.
    }
}
