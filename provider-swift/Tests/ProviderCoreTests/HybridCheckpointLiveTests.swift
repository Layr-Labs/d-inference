import Crypto
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

    /// Prefill `tokens` through `cache` in chunks of `chunk` to avoid
    /// materializing one giant attention-score matrix. A single-shot 100k
    /// forward needs ~320GB for the 100k×100k×heads scores and traps in Metal
    /// (max buffer ~86GB) — the engine ALWAYS chunks prefill for this reason.
    /// Causal attention makes chunked prefill numerically identical to a
    /// single-shot call. Returns last-position logits; evals the cache between
    /// chunks to bound peak memory.
    private func chunkedPrefill(
        model: any LanguageModel, cache: [any KVCache], tokens: [Int], chunk: Int
    ) -> MLXArray {
        var lastLogits = MLXArray(0)
        var i = 0
        while i < tokens.count {
            let end = min(i + chunk, tokens.count)
            let piece = Array(tokens[i..<end])
            let arr = MLXArray(piece.map { Int32($0) }).reshaped([1, piece.count])
            lastLogits = model.callAsFunction(arr, cache: cache)[.ellipsis, -1, 0...]
            eval(lastLogits)
            eval(cache.flatMap { $0.innerState() })  // materialize → free graph
            i = end
        }
        return lastLogits
    }

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
        // Gemma-4 sliding window 1024 → checkpoint within window.
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

    // PAST-WINDOW equivalence — the experiment that decides whether the
    // PrefixDigest cap (checkpoints L ≤ window) is a FUNDAMENTAL correctness
    // requirement or merely a conservative design choice.
    //
    // A hybrid prefix only needs, per layer: FULL KV for full-attention layers
    // + the last `window` KV for sliding layers (the rotating ring buffer).
    // Our serializer already snapshots each layer's `.state`, which is exactly
    // that (RotatingKVCache.state returns the wrapped ring buffer past the
    // window). So IF serialize→restore→continue stays numerically exact for
    // L > window, the cap is over-conservative and long-prefix reuse works in
    // this pipeline today. IF it diverges, the cap is protecting a real gap in
    // our restore of a wrapped ring buffer. This test answers it on real
    // weights at L = 2048 and 4096, both > Gemma-4's 1024 window.
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func gemma4RestoreMatchesColdPastWindow() async throws {
        // 2× and 4× the 1024 window: the sliding layers' ring buffer has
        // wrapped, so this exercises exactly the wrapped-state restore.
        try await assertRestoreMatchesCold(
            modelID: "mlx-community/gemma-4-26b-a4b-it-8bit", checkpointL: 2048)
        try await assertRestoreMatchesCold(
            modelID: "mlx-community/gemma-4-26b-a4b-it-8bit", checkpointL: 4096)
    }

    // PAST-WINDOW equivalence for GPT-OSS — the proof that gates whether the
    // past-window ladder lift can be enabled for GPT-OSS too (today
    // PrefixCachePastWindow.isProven is Gemma-only, a conservative default —
    // GPT-OSS was never *disproven*, just never run). GPT-OSS's mechanism is
    // identical to Gemma's: full-attention layers (KVCacheSimple) keep ALL
    // tokens; sliding layers (RotatingKVCache, window 128) keep their wrapped
    // ring buffer. If serialize→restore→continue is bit-exact for L > 128, the
    // lift is sound for GPT-OSS and isProven can include it. L = 256 and 512
    // are 2× and 4× the 128 window (ring buffer wrapped).
    @Test(.enabled(if:
        LiveInferenceFixtures.liveTestsEnabled
            && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GPTOSS"] != nil))
    func gptOssRestoreMatchesColdPastWindow() async throws {
        try await assertRestoreMatchesCold(
            modelID: "mlx-community/gpt-oss-20b-MXFP4-Q8", checkpointL: 256)
        try await assertRestoreMatchesCold(
            modelID: "mlx-community/gpt-oss-20b-MXFP4-Q8", checkpointL: 512)
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
        // Writer and reader MUST resolve the SAME KEK — in production both
        // tiers use the one SE-wrapped/Keychain-persisted backing.kek (and
        // the identical key is reloaded across restart). Model that with a
        // SHARED fixed wrapping key AND a SHARED storage instance: the writer
        // generates+wraps+persists the KEK into the shared storage, and the
        // reader unwraps that SAME persisted KEK. (Per-manager fresh
        // wrapper+storage would mint different random KEKs → the reader
        // couldn't unwrap the writer's DEK = authenticationFailure, a test
        // artifact, not a product bug.)
        let sharedWrap = InMemoryKeyWrappingService(
            key: SymmetricKey(data: Data(repeating: 0x5A, count: 32)), identifier: "live")
        let sharedStore = InMemoryWrappedKEKStorage(identifier: "live")
        func makeMgr() -> PrefixCacheManager {
            PrefixCacheManager(
                binding: binding, ram: PrefixCacheRAM(),
                index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
                kek: KVCacheKEK(wrapper: sharedWrap, storage: sharedStore),
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

    // 100k SSD ROUND-TRIP, INSTRUMENTED — answers "what's a 100k prefill cold
    // vs with SSD caching?". This is the #267 scenario: cache a prefix far past
    // the sliding window (1024), persist it encrypted, drop+reload, restore
    // from disk, continue, and TIME every stage against the cold baseline.
    // It deliberately bypasses the boundary-cap default (passes boundaries:
    // [checkpointL] directly) to measure what long-prefix reuse WOULD cost if
    // the cap were lifted — the disk size + read/decrypt/rebuild latency that
    // determines the break-even. Slow (a 100k cold prefill is ~74s on M5), so
    // it's its own gate.
    @Test(.enabled(if:
        LiveInferenceFixtures.gemmaTestsEnabled
            && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_BIGKV"] != nil))
    func gemma4SSD100kColdVsWarm() async throws {
        let modelID = "mlx-community/gemma-4-26b-a4b-it-8bit"
        let checkpointL = 100_000
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do { loaded = try await LiveInferenceFixtures.loadScheduler(
                modelID: modelID, memoryBudgetBytes: 110 * 1024 * 1024 * 1024) }
        catch let skip as LiveFixtureSkip { print("SKIP100k \(modelID): \(skip)"); return }
        defer { Task { await loaded.scheduler.unloadModel() } }
        let container = loaded.container

        let prompt = Array(0..<(checkpointL + 12)).map { ($0 % 64) + 5 }
        let suffix = Array(prompt[checkpointL...])
        let maxTokens = 8
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbkv-100k-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Step 1: capability gate, shapes, COLD reference (timed), prefilled prefix.
        struct Setup: @unchecked Sendable {
            let cold: [Int]; let layerShapes: [[Int]]; let prefix: [any KVCache]
            let coldPrefillSec: Double
        }
        let setup: Setup? = try await container.perform { ctx -> Setup? in
            let model = ctx.model
            guard PrefixCacheStrategy.classify(model.newCache(parameters: nil)) == .checkpoint,
                  let layerShapes = BatchScheduler.probeLayerShapes(model: model)
            else { print("SKIP100k \(modelID): not checkpoint / no shapes"); return nil }

            // COLD: full 100k prefill (this is the ~74s baseline), timed to the
            // first produced token. Chunked — a single-shot 100k forward traps
            // Metal (320GB scores); the engine chunks for exactly this reason.
            let prefillChunk = 2048
            let coldStart = Date()
            let coldCache = model.newCache(parameters: nil)
            let coldSeed = chunkedPrefill(model: model, cache: coldCache, tokens: prompt, chunk: prefillChunk)
            let coldPrefillSec = Date().timeIntervalSince(coldStart)
            let cold = greedyContinue(model: model, cache: coldCache, seedLogits: coldSeed, maxTokens: maxTokens)

            // Prefill the 100k prefix to capture as a checkpoint (chunked too).
            let prefixCache = model.newCache(parameters: nil)
            _ = chunkedPrefill(model: model, cache: prefixCache,
                               tokens: Array(prompt.prefix(checkpointL)), chunk: prefillChunk)
            eval(prefixCache.flatMap { $0.innerState() })
            return Setup(cold: cold, layerShapes: layerShapes, prefix: prefixCache, coldPrefillSec: coldPrefillSec)
        }
        guard let setup else { return }
        print("BIGKV cold 100k prefill = \(String(format: "%.2f", setup.coldPrefillSec))s")

        let binding = PrefixCacheModelBinding(
            modelHash: modelID, modelDtype: "x", modelArch: "x", vocabSize: 0,
            numLayers: setup.layerShapes.count,
            kvHeads: setup.layerShapes.first?.first ?? 1, headDim: setup.layerShapes.first?.last ?? 1,
            layerShapes: setup.layerShapes)
        let sharedWrap = InMemoryKeyWrappingService(
            key: SymmetricKey(data: Data(repeating: 0x5A, count: 32)), identifier: "live")
        let sharedStore = InMemoryWrappedKEKStorage(identifier: "live")
        func makeMgr() -> PrefixCacheManager {
            PrefixCacheManager(
                binding: binding, ram: PrefixCacheRAM(),
                index: PrefixCacheIndex(fileURL: dir.appendingPathComponent("index.json")),
                kek: KVCacheKEK(wrapper: sharedWrap, storage: sharedStore),
                cacheDir: dir, ssdEnabled: true, boundaries: [checkpointL], now: { 1000 })
        }

        // Step 2: store → flush (encrypt+write), timed; record on-disk size.
        // In-memory checkpoint size — the full-attention layers carry all L
        // tokens, the sliding layers only their window, so this is the real
        // hybrid footprint (≈2.4GB for Gemma-4 at 100k).
        let checkpointBytes = setup.prefix.reduce(0) { acc, cache in
            acc + cache.innerState().reduce(0) { $0 + $1.nbytes }
        }
        print("BIGKV checkpoint in-memory size = \(String(format: "%.2f", Double(checkpointBytes) / 1_073_741_824))GB")
        // Re-eval caches right before store to ensure MLX hasn't freed them.
        eval(setup.prefix.flatMap { $0.innerState() })
        let writer = makeMgr()
        let stored = await writer.store(tokens: prompt, checkpointLength: checkpointL,
                           caches: SendableKVCaches(setup.prefix))
        #expect(stored, "the 100k checkpoint must be accepted by the RAM tier")
        let flushStart = Date()
        let written = await writer.flushToSSD()
        await writer.flushIndexNow()
        let flushSec = Date().timeIntervalSince(flushStart)
        #expect(written == 1, "the 100k checkpoint must be flushed to SSD (wrote \(written))")
        // Recursively sum file sizes — checkpoints live in a model subdir
        // (<dir>/<modelDirComponent>/<digest>.darkbloom-kv), so a non-recursive
        // scan of `dir` would report 0.
        func recursiveDirSize(at url: URL) -> Int {
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { return 0 }
            var total = 0
            for case let fileURL as URL in enumerator {
                guard let attrs = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      attrs.isRegularFile == true, let size = attrs.fileSize else { continue }
                total += size
            }
            return total
        }
        let bytesOnDisk = recursiveDirSize(at: dir)
        print("BIGKV checkpoint on disk = \(String(format: "%.2f", Double(bytesOnDisk) / 1_073_741_824))GB, flush(encrypt+write) = \(String(format: "%.2f", flushSec))s")

        // Step 3: FRESH manager → reconcile → lookup (read+decrypt+rebuild), timed.
        let reader = makeMgr()
        await reader.reconcileWithDisk()
        let loadStart = Date()
        guard let hit = await reader.lookup(tokens: prompt) else {
            Issue.record("BIGKV SSD lookup MISS at 100k for \(modelID)")
            return
        }
        // loadSec = file read (mmap'd) + AES-GCM decrypt + eager MLXArray
        // construction (KVCacheSerializer.deserialize copies bytes eagerly).
        // CAVEAT (measurement validity): the file was fsync-written by THIS
        // process moments ago, so the OS unified buffer cache likely serves the
        // read from RAM, not NVMe. loadSec is therefore a WARM-page-cache lower
        // bound. The realistic worst case adds a true cold-disk read; on M-series
        // NVMe (~5 GB/s) a `bytesOnDisk` read is well under a second, so even
        // cold it's tiny next to the ~78s cold prefill. We print the cold-disk
        // upper-bound estimate alongside so the speedup isn't overstated.
        let loadSec = Date().timeIntervalSince(loadStart)
        #expect(hit.tier == .ssd, "must load from the encrypted SSD file, got \(hit.tier)")
        #expect(hit.tokenCount == checkpointL)

        // Step 4: rebuild batched (timed separately — fromSingleRow/merge build
        // lazy MLXArray graphs that only materialize under eval, so this is NOT
        // inside loadSec) + prefill ONLY the suffix (timed). warmTTFT ≈ loadSec
        // + rebuildSec + suffixSec.
        let warmResult: (tokens: [Int], rebuildSec: Double, suffixSec: Double) =
            try await container.perform { ctx -> ([Int], Double, Double) in
            let model = ctx.model
            let rStart = Date()
            let batched: [any KVCache] = hit.caches.map { layer in
                if let rot = layer as? RotatingKVCache { return BatchRotatingKVCache.fromSingleRow(rot) }
                return BatchKVCache.merge([layer as! KVCacheSimple])
            }
            eval(batched.flatMap { $0.innerState() })  // force the rebuild graph
            let rebuildSec = Date().timeIntervalSince(rStart)
            let sStart = Date()
            let sfx = MLXArray(suffix.map { Int32($0) }).reshaped([1, suffix.count])
            let seed = model.callAsFunction(sfx, cache: batched)[.ellipsis, -1, 0...]
            eval(seed)
            let suffixSec = Date().timeIntervalSince(sStart)
            let toks = greedyContinue(model: model, cache: batched, seedLogits: seed, maxTokens: maxTokens)
            return (toks, rebuildSec, suffixSec)
        }
        let warm = warmResult.tokens
        let warmTTFT = loadSec + warmResult.rebuildSec + warmResult.suffixSec
        // Cold-disk read upper bound: assume a pessimistic 3 GB/s effective
        // NVMe read if the page cache were fully evicted.
        let coldDiskReadEst = Double(bytesOnDisk) / (3.0 * 1_073_741_824)
        print("BIGKV stages: load(read+decrypt+build)=\(String(format: "%.2f", loadSec))s [warm-cache] rebuild=\(String(format: "%.2f", warmResult.rebuildSec))s suffix=\(String(format: "%.2f", warmResult.suffixSec))s")
        print("BIGKV SUMMARY: cold_prefill=\(String(format: "%.1f", setup.coldPrefillSec))s  warm(load+rebuild+suffix)=\(String(format: "%.2f", warmTTFT))s  speedup≈\(String(format: "%.0f", setup.coldPrefillSec / max(warmTTFT, 0.001)))x  diskGB=\(String(format: "%.2f", Double(bytesOnDisk) / 1_073_741_824))  flush=\(String(format: "%.1f", flushSec))s  cold_disk_read_upper_bound≈\(String(format: "%.2f", coldDiskReadEst))s")
        print("BIGKV NOTE: loadSec is a warm-page-cache read (same-process write→read); add ≈\(String(format: "%.2f", coldDiskReadEst))s for a fully-cold disk. n=1 — speedup is an order-of-magnitude estimate, not a precise figure.")
        #expect(warm == setup.cold,
            "\(modelID) SSD-load restore@100k: warm \(warm) != cold \(setup.cold)")
    }
}
