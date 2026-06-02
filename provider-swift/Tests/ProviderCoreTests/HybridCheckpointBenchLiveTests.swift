import Crypto
import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// TTFT BENCHMARK on real Gemma-4: N cold (distinct 512-tok prefix → full
// prefill) vs N warm (shared 512-tok prefix → checkpoint restore, prefill
// only the short suffix). Emits raw per-sample TTFT (ms) as CSV-ish lines
// (BENCH …) so a real distribution can be charted — no synthetic data.
//
// Run ALONE: swift test --filter HybridCheckpointBenchLiveTests
// Gated: DARKBLOOM_LIVE_MLX_TESTS + DARKBLOOM_LIVE_MLX_GEMMA.
@Suite("Hybrid checkpoint TTFT bench", .serialized)
struct HybridCheckpointBenchLiveTests {

    private static let modelID = "mlx-community/gemma-4-26b-a4b-it-8bit"
    private static let prefixLen = 512   // shared-prefix checkpoint boundary
    private static let samples = 12

    private func ttft(_ stream: AsyncStream<GenerationEvent>) async -> Double {
        let start = Date(); var t = -1.0
        for await ev in stream {
            if case .chunk = ev, t < 0 { t = Date().timeIntervalSince(start) }
            if case .error(let e) = ev { Issue.record("stream error: \(e)") }
        }
        return t
    }

    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func ttftColdVsWarm() async throws {
        setenv("DARKBLOOM_PREFIX_CACHE", "1", 1)
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: Self.modelID) }
        catch let s as LiveFixtureSkip { print("SKIP: \(s)"); return }
        let sched = loaded.scheduler
        defer { Task { await sched.unloadModel() } }

        // Inject an in-memory-KEK manager (unsigned test binary can't make the
        // SE KEK); same wiring makeBatchedEngine does for a .checkpoint model.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbkv-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let shapes = await loaded.container.perform({ ctx in BatchScheduler.probeLayerShapes(model: ctx.model) }) else {
            print("SKIP: not a checkpoint model"); return
        }
        let mgr = PrefixCacheManager(
            binding: PrefixCacheModelBinding(
                modelHash: Self.modelID, modelDtype: "x", modelArch: "x", vocabSize: 0,
                numLayers: shapes.count, kvHeads: shapes.first?.first ?? 1,
                headDim: shapes.first?.last ?? 1, layerShapes: shapes),
            ram: PrefixCacheRAM(maxBytes: 0),
            index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
            kek: KVCacheKEK(wrapper: InMemoryKeyWrappingService(
                key: SymmetricKey(data: Data(repeating: 0x5A, count: 32)), identifier: "bench"),
                storage: InMemoryWrappedKEKStorage(identifier: "bench")),
            cacheDir: dir, ssdEnabled: true, boundaries: [Self.prefixLen], diskBudgetBytes: 0, now: { 1 })
        await sched._installCheckpointManagerForTest(mgr, boundaries: [Self.prefixLen])

        // Fixed shared prefix for the WARM condition.
        let sharedPrefix = (0..<Self.prefixLen).map { ($0 % 64) + 5 }
        func warmPrompt(_ i: Int) -> [Int] { sharedPrefix + [900 + i, 901, 902, 903, 904, 905] }
        // Distinct 512-tok prefix per COLD sample → never a cache hit.
        func coldPrompt(_ i: Int) -> [Int] {
            ((i * 10_000)..<(i * 10_000 + Self.prefixLen)).map { $0 } + [7, 7, 7, 7, 7, 7]
        }

        // Warm-up (absorb Metal kernel compile; not measured) + populate the
        // shared-prefix checkpoint.
        _ = await ttft(sched.submitTokenized(promptTokens: warmPrompt(0), maxTokens: 4, temperature: 0))
        try? await Task.sleep(nanoseconds: 700_000_000)  // let the capture Task land
        let s0 = await mgr.snapshotStats()
        print("BENCH setup: stores=\(s0.stores) (shared prefix captured)")

        var cold: [Double] = []; var warm: [Double] = []
        for i in 1...Self.samples {
            // COLD: distinct prefix → full 512-token prefill.
            cold.append(await ttft(sched.submitTokenized(promptTokens: coldPrompt(i), maxTokens: 4, temperature: 0)))
            // WARM: shared prefix → restore, prefill only the 6-token tail.
            warm.append(await ttft(sched.submitTokenized(promptTokens: warmPrompt(i), maxTokens: 4, temperature: 0)))
        }
        let hits = (await mgr.snapshotStats()).ramHits + (await mgr.snapshotStats()).ssdHits
        print("BENCH hits=\(hits) over \(Self.samples) warm samples")

        // Emit raw samples (ms) for charting.
        for (i, t) in cold.enumerated() { print("BENCH,cold,\(i),\(Int(t * 1000))") }
        for (i, t) in warm.enumerated() { print("BENCH,warm,\(i),\(Int(t * 1000))") }
        func med(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
        let cMed = med(cold) * 1000, wMed = med(warm) * 1000
        print("BENCH SUMMARY: cold_median_ms=\(Int(cMed)) warm_median_ms=\(Int(wMed)) speedup=\(String(format: "%.2f", cMed / max(wMed, 0.001)))x prefix=\(Self.prefixLen)tok n=\(Self.samples)")

        #expect(hits >= Self.samples - 1, "warm samples must hit the cache")
        #expect(wMed < cMed, "warm-restore TTFT median must beat cold full-prefill")
    }
}
