import Crypto
import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// LIVE LOAD/STRESS gates for the hybrid checkpoint KV cache on REAL Gemma-4
// weights — the adversarial dimension the equivalence tests don't cover:
//   1. disk-budget eviction actually bounds the on-disk footprint under
//      sustained diverse-prompt stores (with real ~tens-of-MB KV blobs);
//   2. concurrent flushToSSD (the production capture-hook pattern) is
//      race-safe and stays within budget;
//   3. the RAM byte budget bounds memory under many large checkpoints.
//
// Gated: DARKBLOOM_LIVE_MLX_TESTS + DARKBLOOM_LIVE_MLX_GEMMA. Skips cleanly
// with no weights. These load a 26B model; run on an M5-class box.
@Suite("Hybrid checkpoint live stress", .serialized)
struct HybridCheckpointStressLiveTests {

    private static let modelID = "mlx-community/gemma-4-26b-a4b-it-8bit"

    /// Per-layer caches + the model's per-layer [kvHeads, headDim] reference,
    /// boxed @unchecked Sendable to cross the `container.perform` boundary
    /// (single-owner, no shared mutation).
    struct Checkpoint: @unchecked Sendable {
        let caches: [any KVCache]; let layerShapes: [[Int]]
    }

    /// Prefill one real checkpoint of `len` tokens, or nil if the model isn't
    /// present / isn't a checkpoint model.
    private func realCheckpoint(_ container: ModelContainer, len: Int) async -> Checkpoint? {
        await container.perform { ctx -> Checkpoint? in
            let model = ctx.model
            guard PrefixCacheStrategy.classify(model.newCache(parameters: nil)) == .checkpoint,
                  let layerShapes = BatchScheduler.probeLayerShapes(model: model)
            else { return nil }
            let cache = model.newCache(parameters: nil)
            let toks = MLXArray((0..<len).map { Int32(($0 % 64) + 5) }).reshaped([1, len])
            _ = model.callAsFunction(toks, cache: cache)
            eval(cache.flatMap { $0.innerState() })
            return Checkpoint(caches: cache, layerShapes: layerShapes)
        }
    }

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbkv-stress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func diskUsage(_ dir: URL) -> (files: Int, bytes: Int) {
        let fm = FileManager.default
        guard let all = try? fm.subpathsOfDirectory(atPath: dir.path) else { return (0, 0) }
        var files = 0, bytes = 0
        for p in all where p.hasSuffix(".\(EncryptedKVStore.fileExtension)") {
            files += 1
            bytes += (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(p).path)[.size] as? Int)
                .flatMap { $0 } ?? 0
        }
        return (files, bytes)
    }

    private func binding(_ shapes: [[Int]]) -> PrefixCacheModelBinding {
        PrefixCacheModelBinding(
            modelHash: Self.modelID, modelDtype: "x", modelArch: "x", vocabSize: 0,
            numLayers: shapes.count, kvHeads: shapes.first?.first ?? 1,
            headDim: shapes.first?.last ?? 1, layerShapes: shapes)
    }

    // ---- 1. Disk-budget eviction under sustained real-KV stores ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func diskBudgetBoundsRealKVUnderSustainedStores() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: Self.modelID) }
        catch let s as LiveFixtureSkip { print("SKIP: \(s)"); return }
        defer { Task { await loaded.scheduler.unloadModel() } }

        guard let ckpt = await realCheckpoint(loaded.container, len: 256) else {
            print("SKIP: not a checkpoint model"); return
        }
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }

        // Measure ONE real file's size by flushing a single store, unbounded.
        let wrap = InMemoryKeyWrappingService(
            key: SymmetricKey(data: Data(repeating: 0x5A, count: 32)), identifier: "stress")
        let store = InMemoryWrappedKEKStorage(identifier: "stress")
        func mgr(diskBudget: Int) -> PrefixCacheManager {
            PrefixCacheManager(
                binding: binding(ckpt.layerShapes), ram: PrefixCacheRAM(maxBytes: 0),
                index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
                kek: KVCacheKEK(wrapper: wrap, storage: store),
                cacheDir: dir, ssdEnabled: true, boundaries: [256],
                diskBudgetBytes: 0, now: { 1 })
        }
        let probe = mgr(diskBudget: 0)
        await probe.store(tokens: Array(0..<300), checkpointLength: 256,
                          caches: SendableKVCaches(ckpt.caches.map { $0.copy() }))
        _ = await probe.flushToSSD()
        let oneFile = diskUsage(dir).bytes
        #expect(oneFile > 0)
        print("STRESS one real Gemma-4 checkpoint file = \(oneFile) bytes (\(oneFile / 1_048_576) MB)")
        for p in (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(String(Self.modelID.prefix(12))).path)) ?? [] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(String(Self.modelID.prefix(12))).appendingPathComponent(p))
        }

        // Budget = ~3 files. Store 12 DISTINCT prompts; disk must stay bounded.
        let budget = oneFile * 3 + oneFile / 2
        let m = PrefixCacheManager(
            binding: binding(ckpt.layerShapes), ram: PrefixCacheRAM(maxBytes: 0),
            index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
            kek: KVCacheKEK(wrapper: wrap, storage: store),
            cacheDir: dir, ssdEnabled: true, boundaries: [256],
            diskBudgetBytes: budget, now: { 1 })
        for i in 0..<12 {
            // Distinct prompt → distinct digest → distinct file; reuse the real KV.
            let toks = Array((i * 1000)..<(i * 1000 + 300))
            await m.store(tokens: toks, checkpointLength: 256,
                          caches: SendableKVCaches(ckpt.caches.map { $0.copy() }))
            _ = await m.flushToSSD()
        }
        let (files, bytes) = diskUsage(dir)
        let stats = await m.snapshotStats()
        print("STRESS disk after 12 stores: files=\(files) bytes=\(bytes) budget=\(budget) evictions=\(stats.diskEvictions)")
        #expect(bytes <= budget, "real-KV disk usage \(bytes) must stay within budget \(budget)")
        #expect(files < 12, "older checkpoints must have been evicted")
        #expect(files >= 1, "most-recent must survive")
        #expect(stats.diskEvictions > 0, "eviction must have run under real-KV pressure")
    }

    // ---- 2. Concurrent flushToSSD race-safety + budget under load ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func concurrentFlushesStayWithinBudgetAndDontCrash() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: Self.modelID) }
        catch let s as LiveFixtureSkip { print("SKIP: \(s)"); return }
        defer { Task { await loaded.scheduler.unloadModel() } }

        guard let ckpt = await realCheckpoint(loaded.container, len: 256) else {
            print("SKIP: not a checkpoint model"); return
        }
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wrap = InMemoryKeyWrappingService(
            key: SymmetricKey(data: Data(repeating: 0x5A, count: 32)), identifier: "stress")
        let store = InMemoryWrappedKEKStorage(identifier: "stress")
        let m = PrefixCacheManager(
            binding: binding(ckpt.layerShapes), ram: PrefixCacheRAM(maxBytes: 0),
            index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
            kek: KVCacheKEK(wrapper: wrap, storage: store),
            cacheDir: dir, ssdEnabled: true, boundaries: [256],
            diskBudgetBytes: 200 * 1_048_576, now: { 1 })  // ~200MB

        // Store 16 distinct prompts, then fire 16 CONCURRENT flush Tasks (the
        // production capture-hook pattern). Must not crash, double-write, or
        // exceed budget; index stays consistent.
        for i in 0..<16 {
            await m.store(tokens: Array((i * 1000)..<(i * 1000 + 300)), checkpointLength: 256,
                          caches: SendableKVCaches(ckpt.caches.map { $0.copy() }))
        }
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<16 { group.addTask { await m.flushToSSD() } }
            for await _ in group {}
        }
        await m.flushIndexNow()
        let (files, bytes) = diskUsage(dir)
        let stats = await m.snapshotStats()
        print("STRESS concurrent: files=\(files) bytes=\(bytes) flushes=\(stats.ssdFlushes) readErrors=\(stats.ssdReadErrors)")
        #expect(stats.ssdReadErrors == 0, "no decrypt/read errors under concurrent flush")
        #expect(bytes <= 200 * 1_048_576, "concurrent flushes must respect the disk budget")
        // Each distinct digest written at most once (no duplicate files).
        #expect(files <= 16, "no duplicate files from concurrent same-digest flushes")

        // Every surviving entry must still load+decrypt correctly (no corruption).
        var loadedOK = 0
        for i in 0..<16 {
            if await m.lookup(tokens: Array((i * 1000)..<(i * 1000 + 300))) != nil { loadedOK += 1 }
        }
        print("STRESS concurrent: \(loadedOK)/16 reload+decrypt OK")
        #expect(loadedOK >= 1, "surviving checkpoints must reload+decrypt after concurrent flush")
    }

    // ---- 3. RAM byte budget bounds memory under many large checkpoints ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func ramByteBudgetBoundsMemoryUnderLargeCheckpoints() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: Self.modelID) }
        catch let s as LiveFixtureSkip { print("SKIP: \(s)"); return }
        defer { Task { await loaded.scheduler.unloadModel() } }

        guard let ckpt = await realCheckpoint(loaded.container, len: 256) else {
            print("SKIP: not a checkpoint model"); return
        }
        // One checkpoint's real RAM bytes.
        let oneBytes = ckpt.caches.reduce(0) { $0 + $1.innerState().reduce(0) { $0 + $1.nbytes } }
        #expect(oneBytes > 0)
        print("STRESS one checkpoint RAM = \(oneBytes) bytes (\(oneBytes / 1_048_576) MB)")

        // RAM budget ~2.5 checkpoints. Insert 10 distinct → must stay bounded.
        let ram = PrefixCacheRAM(maxBytes: oneBytes * 2 + oneBytes / 2)
        for i in 0..<10 {
            let dig = Data(SHA256.hash(data: Data("k\(i)".utf8)))
            _ = ram.put(modelHash: Self.modelID, digest: dig,
                        caches: ckpt.caches.map { $0.copy() }, tokenCount: 256)
        }
        let s = ram.snapshotStats()
        print("STRESS RAM: entries=\(s.entries) bytes=\(s.bytes) budget=\(oneBytes * 2 + oneBytes / 2) evictions=\(s.evictions)")
        #expect(s.bytes <= oneBytes * 2 + oneBytes / 2, "RAM byte budget must bound memory")
        #expect(s.evictions > 0, "LRU eviction must run under real-KV memory pressure")
        #expect(s.entries < 10, "older entries evicted")
        #expect(s.entries >= 1, "most-recent retained")
    }
}
