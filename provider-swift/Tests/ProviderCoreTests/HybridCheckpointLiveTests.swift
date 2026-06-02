import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// STEP 5 — live numeric-equivalence gate for the hybrid (sliding-window)
// checkpoint KV cache on REAL Gemma-4 / GPT-OSS weights. This is the
// non-negotiable correctness check that synthetic models can't provide: it
// exercises real bf16 KV tensors, real head dims, real sliding-window sizes,
// real layer counts, and the actual KVCacheSerializer + fromSingleRow/merge
// restore path.
//
// The property: continuing generation from a RESTORED checkpoint at length L
// (serialize the prefix cache → deserialize → rebuild batched B==1 →
// prefill the suffix → decode) yields the SAME tokens as a cold full-prompt
// greedy run. A wrong restored offset, shape, or layer mapping diverges the
// argmax within a few tokens.
//
// Gated: DARKBLOOM_LIVE_MLX_TESTS + DARKBLOOM_LIVE_MLX_GEMMA, and the model
// must be on disk. Skips cleanly otherwise (no weights in CI).

@Suite("Hybrid checkpoint live equivalence", .serialized)
struct HybridCheckpointLiveTests {

    /// Greedy-decode `maxTokens` from a model + seeded cache, returning the
    /// produced token ids. Mirrors the engine's continue-from-cache path.
    private func greedyContinue(
        model: any LanguageModel, cache: [any KVCache],
        seedLogits: MLXArray, maxTokens: Int
    ) -> [Int] {
        var produced: [Int] = []
        var logits = seedLogits
        for _ in 0 ..< maxTokens {
            let next = argMax(logits, axis: -1)
            eval(next)
            produced.append(Int(next.asArray(Int32.self)[0]))
            let stepArr = next[0..., .newAxis]
            logits = model.callAsFunction(stepArr, cache: cache)[.ellipsis, -1, 0...]
        }
        return produced
    }

    /// Core check: restore-at-L greedy continuation == cold greedy.
    private func assertRestoreMatchesCold(modelID: String, checkpointL: Int) async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do {
            loaded = try await LiveInferenceFixtures.loadScheduler(modelID: modelID)
        } catch let skip as LiveFixtureSkip {
            // Model/metallib absent → skip without failing.
            print("SKIP \(modelID): \(skip)")
            return
        }
        defer { Task { await loaded.scheduler.unloadModel() } }
        let container = loaded.container

        // A prompt long enough to cross the checkpoint and leave a suffix.
        let prompt = Array(0..<(checkpointL + 12)).map { ($0 % 64) + 5 }
        let maxTokens = 8

        let (cold, warm): ([Int], [Int]) = try await container.perform { ctx in
            let model = ctx.model

            // Capability gate: only run for models the checkpoint tier serves.
            let strategy = PrefixCacheStrategy.classify(model.newCache(parameters: nil))
            guard strategy == .checkpoint else {
                print("SKIP \(modelID): strategy=\(strategy), not a hybrid checkpoint model")
                return ([], [])
            }

            // --- COLD: full-prompt prefill, then greedy. ---
            let coldCache = model.newCache(parameters: nil)
            let full = MLXArray(prompt.map { Int32($0) }).reshaped([1, prompt.count])
            let coldSeed = model.callAsFunction(full, cache: coldCache)[.ellipsis, -1, 0...]
            let coldOut = greedyContinue(
                model: model, cache: coldCache, seedLogits: coldSeed, maxTokens: maxTokens)

            // --- WARM: prefill only the prefix[0..L], serialize→restore the
            // cache via the real pipeline, rebuild B==1 batched, prefill the
            // suffix, then greedy. ---
            let prefixCache = model.newCache(parameters: nil)
            let prefixArr = MLXArray(prompt.prefix(checkpointL).map { Int32($0) })
                .reshaped([1, checkpointL])
            _ = model.callAsFunction(prefixArr, cache: prefixCache)
            eval(prefixCache.flatMap { $0.innerState() })

            // Serialize → deserialize (the encrypted store's payload path).
            let (chunks, layout) = try KVCacheSerializer.serialize(prefixCache)
            let restoredSingle = try KVCacheSerializer.deserialize(chunks: chunks, layout: layout)

            // Rebuild B==1 batched caches exactly like admitRestoredCheckpoint.
            let batched: [any KVCache] = restoredSingle.map { layer -> any KVCache in
                if let rot = layer as? RotatingKVCache {
                    return BatchRotatingKVCache.fromSingleRow(rot)
                }
                return BatchKVCache.merge([layer as! KVCacheSimple])
            }

            // Prefill the suffix on the restored cache, then greedy.
            let suffix = Array(prompt[checkpointL...])
            let suffixArr = MLXArray(suffix.map { Int32($0) }).reshaped([1, suffix.count])
            let warmSeed = model.callAsFunction(suffixArr, cache: batched)[.ellipsis, -1, 0...]
            let warmOut = greedyContinue(
                model: model, cache: batched, seedLogits: warmSeed, maxTokens: maxTokens)

            return (coldOut, warmOut)
        }

        if cold.isEmpty && warm.isEmpty { return }  // skipped inside perform
        #expect(warm == cold,
            "\(modelID) restore@\(checkpointL): warm \(warm) != cold \(cold)")
    }

    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func gemma4RestoreMatchesCold() async throws {
        // Gemma-4 sliding window 512 → checkpoint within window.
        try await assertRestoreMatchesCold(
            modelID: "mlx-community/gemma-4-26b-a4b-it-8bit", checkpointL: 256)
    }

    @Test(.enabled(if:
        LiveInferenceFixtures.liveTestsEnabled
            && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GPTOSS"] != nil))
    func gptOssRestoreMatchesCold() async throws {
        // GPT-OSS window 128 → checkpoint within window.
        try await assertRestoreMatchesCold(
            modelID: "mlx-community/gpt-oss-20b-MXFP4-Q8", checkpointL: 64)
    }

    /// FULL ENCRYPTED-SSD PATH: prefill prefix → real PrefixCacheManager
    /// store → flushToSSD (writes encrypted file) → DROP the manager → FRESH
    /// manager + reconcileWithDisk → lookup (reads SSD, decrypts, per-layer
    /// validateLayout) → rebuild B==1 batched → suffix → greedy == cold.
    /// This is the test that proves the encrypted SSD cache actually LOADS
    /// for a real heterogeneous model (Gemma-4: sliding [8,256] + full
    /// [2,512]) — the path the bypass equivalence test above does NOT cover.
    private func assertSSDLoadMatchesCold(modelID: String, checkpointL: Int) async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(modelID: modelID) }
        catch let skip as LiveFixtureSkip { print("SKIP \(modelID): \(skip)"); return }
        defer { Task { await loaded.scheduler.unloadModel() } }
        let container = loaded.container

        let prompt = Array(0..<(checkpointL + 12)).map { ($0 % 64) + 5 }
        let suffix = Array(prompt[checkpointL...])
        let maxTokens = 8
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbkv-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Step 1 (in model context): capability gate, per-layer shapes, COLD
        // reference output, and the prefilled prefix caches to persist.
        struct Setup: @unchecked Sendable {
            let cold: [Int]; let layerShapes: [[Int]]; let prefix: [any KVCache]
        }
        let setup: Setup? = try await container.perform { ctx -> Setup? in
            let model = ctx.model
            guard PrefixCacheStrategy.classify(model.newCache(parameters: nil)) == .checkpoint,
                  let layerShapes = BatchScheduler.probeLayerShapes(model: model)
            else { print("SKIP \(modelID): not checkpoint / no shapes"); return nil }
            let distinct = Set(layerShapes.map { "\($0)" })
            print("LAYER SHAPES \(modelID): \(distinct.count) distinct -> \(distinct.sorted())")

            let coldCache = model.newCache(parameters: nil)
            let full = MLXArray(prompt.map { Int32($0) }).reshaped([1, prompt.count])
            let coldSeed = model.callAsFunction(full, cache: coldCache)[.ellipsis, -1, 0...]
            let cold = greedyContinue(model: model, cache: coldCache, seedLogits: coldSeed, maxTokens: maxTokens)

            let prefixCache = model.newCache(parameters: nil)
            let pfx = MLXArray(prompt.prefix(checkpointL).map { Int32($0) }).reshaped([1, checkpointL])
            _ = model.callAsFunction(pfx, cache: prefixCache)
            eval(prefixCache.flatMap { $0.innerState() })
            return Setup(cold: cold, layerShapes: layerShapes, prefix: prefixCache)
        }
        guard let setup else { return }  // skipped

        // Step 2 (actor context): store → flush (encrypt to SSD) → DROP the
        // manager → FRESH manager → reconcile + lookup (reads SSD, decrypts,
        // PER-LAYER validateLayout). This is the real encrypted-SSD load.
        let binding = PrefixCacheModelBinding(
            modelHash: modelID, modelDtype: "x", modelArch: "x", vocabSize: 0,
            numLayers: setup.layerShapes.count,
            kvHeads: setup.layerShapes.first?.first ?? 1, headDim: setup.layerShapes.first?.last ?? 1,
            layerShapes: setup.layerShapes)
        func makeMgr() -> PrefixCacheManager {
            PrefixCacheManager(
                binding: binding, ram: PrefixCacheRAM(),
                index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
                kek: KVCacheKEK(wrapper: InMemoryKeyWrappingService(),
                                storage: InMemoryWrappedKEKStorage(identifier: "live")),
                cacheDir: dir, ssdEnabled: true, boundaries: [checkpointL], now: { 1000 })
        }
        let writer = makeMgr()
        await writer.store(tokens: prompt, checkpointLength: checkpointL,
                           caches: SendableKVCaches(setup.prefix))
        _ = await writer.flushToSSD()
        await writer.flushIndexNow()

        let reader = makeMgr()  // fresh, empty RAM
        await reader.reconcileWithDisk()
        guard let hit = await reader.lookup(tokens: prompt) else {
            Issue.record("SSD lookup MISS — encrypted checkpoint failed to load for \(modelID)")
            return
        }
        #expect(hit.tier == .ssd, "must load from the encrypted SSD file, got \(hit.tier)")
        #expect(hit.tokenCount == checkpointL)

        // Step 3 (model context): rebuild batched from the SSD-loaded caches,
        // forward the suffix, greedy — must equal the cold reference.
        let warm: [Int] = try await container.perform { ctx -> [Int] in
            let model = ctx.model
            let batched: [any KVCache] = hit.caches.map { layer in
                if let rot = layer as? RotatingKVCache { return BatchRotatingKVCache.fromSingleRow(rot) }
                return BatchKVCache.merge([layer as! KVCacheSimple])
            }
            let sfx = MLXArray(suffix.map { Int32($0) }).reshaped([1, suffix.count])
            let seed = model.callAsFunction(sfx, cache: batched)[.ellipsis, -1, 0...]
            return greedyContinue(model: model, cache: batched, seedLogits: seed, maxTokens: maxTokens)
        }
        #expect(warm == setup.cold,
            "\(modelID) SSD-load restore@\(checkpointL): warm \(warm) != cold \(setup.cold)")
    }

    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func gemma4SSDLoadMatchesCold() async throws {
        try await assertSSDLoadMatchesCold(
            modelID: "mlx-community/gemma-4-26b-a4b-it-8bit", checkpointL: 256)
    }
}
