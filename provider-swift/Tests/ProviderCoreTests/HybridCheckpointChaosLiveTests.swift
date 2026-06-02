import Crypto
import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// CHAOS / failure-injection gates on REAL Gemma-4 KV: a partner box WILL hit
// corrupt files, wrong keys, and crash-mid-flush. The cache must DEGRADE to
// a clean cold miss (never crash, hang, or serve garbage) and self-heal.
//
// Gated: DARKBLOOM_LIVE_MLX_TESTS + DARKBLOOM_LIVE_MLX_GEMMA. Skips cleanly.
@Suite("Hybrid checkpoint chaos", .serialized)
struct HybridCheckpointChaosLiveTests {

    private static let modelID = "mlx-community/gemma-4-26b-a4b-it-8bit"

    struct Checkpoint: @unchecked Sendable { let caches: [any KVCache]; let layerShapes: [[Int]] }

    private func realCheckpoint(_ c: ModelContainer, len: Int) async -> Checkpoint? {
        await c.perform { ctx -> Checkpoint? in
            let m = ctx.model
            guard PrefixCacheStrategy.classify(m.newCache(parameters: nil)) == .checkpoint,
                  let shapes = BatchScheduler.probeLayerShapes(model: m) else { return nil }
            let cache = m.newCache(parameters: nil)
            _ = m.callAsFunction(MLXArray((0..<len).map { Int32(($0 % 64) + 5) }).reshaped([1, len]), cache: cache)
            eval(cache.flatMap { $0.innerState() })
            return Checkpoint(caches: cache, layerShapes: shapes)
        }
    }

    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbkv-chaos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func binding(_ s: [[Int]]) -> PrefixCacheModelBinding {
        PrefixCacheModelBinding(modelHash: Self.modelID, modelDtype: "x", modelArch: "x",
            vocabSize: 0, numLayers: s.count, kvHeads: s.first?.first ?? 1, headDim: s.first?.last ?? 1, layerShapes: s)
    }
    private func modelDir(_ dir: URL) -> URL {
        dir.appendingPathComponent(String(Self.modelID.prefix(12)), isDirectory: true)
    }
    private func kvFiles(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: modelDir(dir), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".\(EncryptedKVStore.fileExtension)") }
    }

    /// Make a manager with a stable shared KEK + storage (matches production:
    /// one persisted KEK shared by writer and reader).
    private func mgr(dir: URL, shapes: [[Int]], wrap: InMemoryKeyWrappingService,
                     store: InMemoryWrappedKEKStorage, boundaries: [Int] = [256]) -> PrefixCacheManager {
        PrefixCacheManager(
            binding: binding(shapes), ram: PrefixCacheRAM(maxBytes: 0),
            index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
            kek: KVCacheKEK(wrapper: wrap, storage: store),
            cacheDir: dir, ssdEnabled: true, boundaries: boundaries, diskBudgetBytes: 0, now: { 1 })
    }

    // Persist one real checkpoint and return (dir, shared wrap key bytes, the prompt).
    private func writeOne(_ container: ModelContainer, _ ckpt: Checkpoint, dir: URL,
                          wrap: InMemoryKeyWrappingService, store: InMemoryWrappedKEKStorage) async -> [Int] {
        let prompt = Array(0..<300).map { ($0 % 64) + 5 }
        let w = mgr(dir: dir, shapes: ckpt.layerShapes, wrap: wrap, store: store)
        await w.store(tokens: prompt, checkpointLength: 256, caches: SendableKVCaches(ckpt.caches.map { $0.copy() }))
        _ = await w.flushToSSD()
        await w.flushIndexNow()
        return prompt
    }

    // ---- 1. Truncated file → clean cold miss, no crash, entry dropped ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func truncatedFileDegradesToColdMiss() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: Self.modelID) }
        catch let s as LiveFixtureSkip { print("SKIP: \(s)"); return }
        defer { Task { await loaded.scheduler.unloadModel() } }
        guard let ckpt = await realCheckpoint(loaded.container, len: 256) else { print("SKIP: not checkpoint"); return }
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wrap = InMemoryKeyWrappingService(key: SymmetricKey(data: Data(repeating: 1, count: 32)), identifier: "c")
        let store = InMemoryWrappedKEKStorage(identifier: "c")
        let prompt = await writeOne(loaded.container, ckpt, dir: dir, wrap: wrap, store: store)

        // Truncate the real KV file to 100 bytes (simulates a crash mid-write).
        let file = kvFiles(dir).first!
        try Data(repeating: 0, count: 100).write(to: file)

        let reader = mgr(dir: dir, shapes: ckpt.layerShapes, wrap: wrap, store: store)
        let hit = await reader.lookup(tokens: prompt)   // must NOT crash
        let stats = await reader.snapshotStats()
        print("CHAOS truncated: hit=\(hit == nil ? "nil(cold)" : "SERVED!") ssdReadErrors=\(stats.ssdReadErrors) filesLeft=\(kvFiles(dir).count)")
        #expect(hit == nil, "a truncated file must degrade to a cold miss, never serve garbage")
        #expect(!FileManager.default.fileExists(atPath: file.path), "the unusable file must be dropped")
    }

    // ---- 2. Wrong KEK (can't decrypt) → cold miss, no crash ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func wrongKekDegradesToColdMiss() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: Self.modelID) }
        catch let s as LiveFixtureSkip { print("SKIP: \(s)"); return }
        defer { Task { await loaded.scheduler.unloadModel() } }
        guard let ckpt = await realCheckpoint(loaded.container, len: 256) else { print("SKIP: not checkpoint"); return }
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wrapA = InMemoryKeyWrappingService(key: SymmetricKey(data: Data(repeating: 2, count: 32)), identifier: "A")
        let storeA = InMemoryWrappedKEKStorage(identifier: "A")
        let prompt = await writeOne(loaded.container, ckpt, dir: dir, wrap: wrapA, store: storeA)

        // Reader with a DIFFERENT KEK (storage cleared) — decrypt must fail.
        let wrapB = InMemoryKeyWrappingService(key: SymmetricKey(data: Data(repeating: 9, count: 32)), identifier: "A")
        let reader = mgr(dir: dir, shapes: ckpt.layerShapes, wrap: wrapB, store: InMemoryWrappedKEKStorage(identifier: "B"))
        let hit = await reader.lookup(tokens: prompt)  // must NOT crash
        let stats = await reader.snapshotStats()
        print("CHAOS wrongKEK: hit=\(hit == nil ? "nil(cold)" : "SERVED!") ssdReadErrors=\(stats.ssdReadErrors)")
        #expect(hit == nil, "an undecryptable file must degrade to a cold miss")
        #expect(stats.ssdReadErrors >= 1, "decrypt failure must be counted, not crash")
    }

    // ---- 3. SIGKILL-mid-flush sim: file present, index.json gone →
    // reconcile re-indexes the REAL encrypted file and serves it ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func orphanFileReindexedAndServesAfterCrash() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: Self.modelID) }
        catch let s as LiveFixtureSkip { print("SKIP: \(s)"); return }
        defer { Task { await loaded.scheduler.unloadModel() } }
        guard let ckpt = await realCheckpoint(loaded.container, len: 256) else { print("SKIP: not checkpoint"); return }
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wrap = InMemoryKeyWrappingService(key: SymmetricKey(data: Data(repeating: 3, count: 32)), identifier: "c")
        let store = InMemoryWrappedKEKStorage(identifier: "c")
        let prompt = await writeOne(loaded.container, ckpt, dir: dir, wrap: wrap, store: store)

        // Simulate crash inside the save-coalescing window: file fsynced,
        // index.json never persisted.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("index.json"))
        #expect(kvFiles(dir).count == 1, "the real KV file is on disk")

        let reader = mgr(dir: dir, shapes: ckpt.layerShapes, wrap: wrap, store: store)
        await reader.reconcileWithDisk()
        let hit = await reader.lookup(tokens: prompt)
        print("CHAOS orphan: reindexed+served=\(hit != nil) tier=\(String(describing: hit?.tier))")
        #expect(hit != nil, "reconcile must re-index the orphaned encrypted file so it serves")
        #expect(hit?.tier == .ssd)
    }

    // ---- 4. Foreign / garbage file in the dir → reconcile deletes it, no crash ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func garbageFileIsDeletedNotServed() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: Self.modelID) }
        catch let s as LiveFixtureSkip { print("SKIP: \(s)"); return }
        defer { Task { await loaded.scheduler.unloadModel() } }
        guard let ckpt = await realCheckpoint(loaded.container, len: 256) else { print("SKIP: not checkpoint"); return }
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: modelDir(dir), withIntermediateDirectories: true)
        // A plausible-looking but garbage file (hex-name + right extension).
        let garbage = modelDir(dir).appendingPathComponent(
            "deadbeef00000000000000000000000000000000000000000000000000000000.\(EncryptedKVStore.fileExtension)")
        try Data("not a real dbkv file".utf8).write(to: garbage)
        let wrap = InMemoryKeyWrappingService(key: SymmetricKey(data: Data(repeating: 4, count: 32)), identifier: "c")
        let store = InMemoryWrappedKEKStorage(identifier: "c")

        let reader = mgr(dir: dir, shapes: ckpt.layerShapes, wrap: wrap, store: store)
        await reader.reconcileWithDisk()   // must not crash on the garbage file
        print("CHAOS garbage: deleted=\(!FileManager.default.fileExists(atPath: garbage.path))")
        #expect(!FileManager.default.fileExists(atPath: garbage.path), "garbage file must be deleted by reconcile")
    }
}
