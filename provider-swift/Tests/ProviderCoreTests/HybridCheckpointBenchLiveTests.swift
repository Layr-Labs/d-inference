import Crypto
import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// TTFT BENCHMARK on real hybrid (sliding-window) models: N cold (distinct
// PREFIX-len prefix → full prefill) vs N warm (shared PREFIX-len prefix →
// checkpoint restore, prefill only the short suffix). Emits raw per-sample
// TTFT (ms) as CSV-ish lines (BENCH …) so a real distribution can be charted
// — no synthetic data.
//
// Two models, each gated independently so a box with only one weight set
// still produces a chartable result:
//   • Gemma-4 26B (sliding window 512) — DARKBLOOM_LIVE_MLX_GEMMA, prefix 512.
//   • GPT-OSS 20B (sliding window 128) — DARKBLOOM_LIVE_MLX_GPTOSS, prefix 96
//     (must stay ≤ window so every sliding layer still holds the full prefix).
//
// There is also a PREFILL-LENGTH SWEEP (gemma4PrefillSweep) that holds the
// model loaded and measures cold/warm at several prefix lengths, to show that
// the TTFT win IS a prefill effect: cold grows with prefix length (more tokens
// to prefill) while warm stays ~flat (it only ever prefills the short suffix),
// so the speedup scales with how much prefill the checkpoint skips.
//
// Run ALONE: swift test --filter HybridCheckpointBenchLiveTests
// Always requires DARKBLOOM_LIVE_MLX_TESTS.
@Suite("Hybrid checkpoint TTFT bench", .serialized)
struct HybridCheckpointBenchLiveTests {

    private static let samples = 12

    private func ttft(_ stream: AsyncStream<GenerationEvent>) async -> Double {
        let start = Date(); var t = -1.0
        for await ev in stream {
            if case .chunk = ev, t < 0 { t = Date().timeIntervalSince(start) }
            if case .error(let e) = ev { Issue.record("stream error: \(e)") }
        }
        return t
    }

    /// Install a fresh in-memory-KEK checkpoint manager bound to `prefixLen`,
    /// then measure `samples` cold (distinct full-prefill prefix) vs `samples`
    /// warm (shared prefix → restore + 6-tok suffix) TTFTs. Returns the raw
    /// per-sample arrays + the observed cache-hit count. A warm-up request
    /// (not measured) absorbs Metal kernel compile and seeds the checkpoint.
    private func measureColdVsWarm(
        sched: BatchScheduler, container: ModelContainer, shapes: [[Int]],
        modelID: String, prefixLen: Int
    ) async throws -> (cold: [Double], warm: [Double], hits: Int) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbkv-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let mgr = PrefixCacheManager(
            binding: PrefixCacheModelBinding(
                modelHash: modelID, modelDtype: "x", modelArch: "x", vocabSize: 0,
                numLayers: shapes.count, kvHeads: shapes.first?.first ?? 1,
                headDim: shapes.first?.last ?? 1, layerShapes: shapes),
            ram: PrefixCacheRAM(maxBytes: 0),
            index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
            kek: KVCacheKEK(wrapper: InMemoryKeyWrappingService(
                key: SymmetricKey(data: Data(repeating: 0x5A, count: 32)), identifier: "bench"),
                storage: InMemoryWrappedKEKStorage(identifier: "bench")),
            cacheDir: dir, ssdEnabled: true, boundaries: [prefixLen], diskBudgetBytes: 0, now: { 1 })
        await sched._installCheckpointManagerForTest(mgr, boundaries: [prefixLen])

        // Fixed shared prefix for the WARM condition.
        let sharedPrefix = (0..<prefixLen).map { ($0 % 64) + 5 }
        func warmPrompt(_ i: Int) -> [Int] { sharedPrefix + [900 + i, 901, 902, 903, 904, 905] }
        // Distinct PREFIX-len prefix per COLD sample → never a cache hit.
        func coldPrompt(_ i: Int) -> [Int] {
            ((i * 10_000)..<(i * 10_000 + prefixLen)).map { $0 } + [7, 7, 7, 7, 7, 7]
        }

        // Warm-up (absorb Metal kernel compile for this length; not measured)
        // + populate the shared-prefix checkpoint.
        _ = await ttft(sched.submitTokenized(promptTokens: warmPrompt(0), maxTokens: 4, temperature: 0))
        try? await Task.sleep(nanoseconds: 700_000_000)  // let the capture Task land

        var cold: [Double] = []; var warm: [Double] = []
        for i in 1...Self.samples {
            cold.append(await ttft(sched.submitTokenized(promptTokens: coldPrompt(i), maxTokens: 4, temperature: 0)))
            warm.append(await ttft(sched.submitTokenized(promptTokens: warmPrompt(i), maxTokens: 4, temperature: 0)))
        }
        let s = await mgr.snapshotStats()
        return (cold, warm, s.ramHits + s.ssdHits)
    }

    private func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }

    /// Run the single-prefix cold-vs-warm benchmark for one model and emit the
    /// raw samples (tagged) + a SUMMARY line for charting.
    private func runBench(modelID: String, prefixLen: Int, tag: String) async throws {
        setenv("DARKBLOOM_PREFIX_CACHE", "1", 1)
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: modelID) }
        catch let s as LiveFixtureSkip { print("SKIP \(tag): \(s)"); return }
        let sched = loaded.scheduler
        defer { Task { await sched.unloadModel() } }

        guard let shapes = await loaded.container.perform({ ctx in BatchScheduler.probeLayerShapes(model: ctx.model) }) else {
            print("SKIP \(tag): not a checkpoint model"); return
        }
        let r = try await measureColdVsWarm(
            sched: sched, container: loaded.container, shapes: shapes,
            modelID: modelID, prefixLen: prefixLen)
        print("BENCH[\(tag)] hits=\(r.hits) over \(Self.samples) warm samples, prefix=\(prefixLen)tok")

        for (i, t) in r.cold.enumerated() { print("BENCH,\(tag),cold,\(i),\(Int(t * 1000))") }
        for (i, t) in r.warm.enumerated() { print("BENCH,\(tag),warm,\(i),\(Int(t * 1000))") }
        let cMed = median(r.cold) * 1000, wMed = median(r.warm) * 1000
        print("BENCH SUMMARY[\(tag)]: cold_median_ms=\(Int(cMed)) warm_median_ms=\(Int(wMed)) speedup=\(String(format: "%.2f", cMed / max(wMed, 0.001)))x prefix=\(prefixLen)tok n=\(Self.samples)")

        #expect(r.hits >= Self.samples - 1, "[\(tag)] warm samples must hit the cache")
        #expect(wMed < cMed, "[\(tag)] warm-restore TTFT median must beat cold full-prefill")
    }

    // Gemma-4 26B-A4B, sliding window 512 → checkpoint @ 512 (within window).
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func gemma4ColdVsWarm() async throws {
        try await runBench(
            modelID: "mlx-community/gemma-4-26b-a4b-it-8bit", prefixLen: 512, tag: "gemma4")
    }

    // GPT-OSS 20B, sliding window 128 → checkpoint @ 96 (must be ≤ window so
    // every sliding layer still holds the full prefix at restore time).
    @Test(.enabled(if:
        LiveInferenceFixtures.liveTestsEnabled
            && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GPTOSS"] != nil))
    func gptOssColdVsWarm() async throws {
        try await runBench(
            modelID: "mlx-community/gpt-oss-20b-MXFP4-Q8", prefixLen: 96, tag: "gptoss")
    }

    // PREFILL-LENGTH SWEEP — load Gemma-4 once, measure cold/warm at several
    // prefix lengths (all ≤ window 512). Demonstrates the win is a prefill
    // effect: cold TTFT rises with prefix length, warm stays ~flat (only the
    // 6-tok suffix is ever prefilled), so speedup scales with skipped prefill.
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func gemma4PrefillSweep() async throws {
        setenv("DARKBLOOM_PREFIX_CACHE", "1", 1)
        let modelID = "mlx-community/gemma-4-26b-a4b-it-8bit"
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: modelID) }
        catch let s as LiveFixtureSkip { print("SKIP sweep: \(s)"); return }
        let sched = loaded.scheduler
        defer { Task { await sched.unloadModel() } }
        guard let shapes = await loaded.container.perform({ ctx in BatchScheduler.probeLayerShapes(model: ctx.model) }) else {
            print("SKIP sweep: not a checkpoint model"); return
        }

        let lengths = [64, 128, 256, 384, 512]   // all ≤ Gemma-4 window (512)
        print("SWEEP[gemma4] prefill-length cold vs warm TTFT (ms), n=\(Self.samples)/point")
        for L in lengths {
            let r = try await measureColdVsWarm(
                sched: sched, container: loaded.container, shapes: shapes,
                modelID: modelID, prefixLen: L)
            let cMed = median(r.cold) * 1000, wMed = median(r.warm) * 1000
            print("SWEEP,gemma4,\(L),\(Int(cMed)),\(Int(wMed)),\(String(format: "%.2f", cMed / max(wMed, 0.001)))")
            print("SWEEP[gemma4] prefix=\(L): cold=\(Int(cMed))ms warm=\(Int(wMed))ms speedup=\(String(format: "%.2f", cMed / max(wMed, 0.001)))x hits=\(r.hits)")
            #expect(r.hits >= Self.samples - 1, "sweep@\(L): warm must hit the cache")
            #expect(wMed < cMed, "sweep@\(L): warm must beat cold")
        }
    }
}
