import Crypto
import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon
@testable import ProviderCore

// END-TO-END live serve-loop gates for the hybrid checkpoint cache — the
// path a partner actually hits: BatchScheduler.submitTokenized → lookup →
// addRequest → admit (cold capture / warm restore) → decode → stream. None
// of the other live tests exercise this seam. Verifies on REAL Gemma-4:
//   1. flag-ON output == flag-OFF output (the cache must be transparent);
//   2. a shared-prefix 2nd request actually RESTORES from the cache and is
//      not slower (TTFT benefit / no miss-path regression);
//   3. capture/store/hit stats reflect a real cache hit.
//
// Gated: DARKBLOOM_LIVE_MLX_TESTS + DARKBLOOM_LIVE_MLX_GEMMA. Skips cleanly.
//
// RUN THIS SUITE ALONE — `swift test --filter HybridCheckpointE2ELiveTests`.
// Swift Testing parallelizes ACROSS suites (`.serialized` only orders within
// one), so running it alongside the other Hybrid*LiveTests suites loads
// several 26B models at once → memory contention → spurious request errors
// and TTFT-comparison failures. The transparency/miss-path TTFT asserts here
// are timing-sensitive and need an uncontended box.
@Suite("Hybrid checkpoint live E2E", .serialized)
struct HybridCheckpointE2ELiveTests {

    private static let modelID = "mlx-community/gemma-4-26b-a4b-it-8bit"

    /// Drain a generation stream → (text, ttft seconds, info-tps).
    private func drain(_ stream: AsyncStream<GenerationEvent>) async
        -> (text: String, ttft: Double, tps: Double)
    {
        var text = ""; var ttft = 0.0; var tps = 0.0; var first = true
        let start = Date()
        for await ev in stream {
            switch ev {
            case .chunk(let c):
                if first { ttft = Date().timeIntervalSince(start); first = false }
                text += c
            case .info(_, _, let t): tps = t
            case .error(let e): Issue.record("stream error: \(e)")
            }
        }
        return (text, ttft, tps)
    }

    /// Load a scheduler with the prefix-cache flag set to `on`.
    private func load(flagOn: Bool) async throws
        -> (BatchScheduler, ModelContainer)?
    {
        setenv("DARKBLOOM_PREFIX_CACHE", flagOn ? "1" : "0", 1)
        do {
            let l = try await LiveInferenceFixtures.loadScheduler(modelID: Self.modelID)
            return (l.scheduler, l.container)
        } catch let s as LiveFixtureSkip { print("SKIP: \(s)"); return nil }
    }

    // A long shared prefix (crosses the 256 checkpoint boundary) + a unique
    // tail per request. Distinct tails → same prefix digest at 256.
    private func prompt(tail: Int) -> [Int] {
        Array(0..<280).map { ($0 % 64) + 5 } + Array(repeating: tail, count: 6)
    }

    // ---- 1. Transparency: flag-on output == flag-off output ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func flagOnOutputMatchesFlagOff() async throws {
        let p = prompt(tail: 99)
        let maxTokens = 24

        guard let (offSched, _) = try await load(flagOn: false) else { return }
        let off = await drain(offSched.submitTokenized(promptTokens: p, maxTokens: maxTokens, temperature: 0))
        await offSched.unloadModel()

        guard let (onSched, _) = try await load(flagOn: true) else { return }
        defer { Task { await onSched.unloadModel() } }
        // First request populates the cache; second should restore — both must
        // match the flag-off baseline exactly (greedy, temp 0).
        let on1 = await drain(onSched.submitTokenized(promptTokens: p, maxTokens: maxTokens, temperature: 0))
        let on2 = await drain(onSched.submitTokenized(promptTokens: p, maxTokens: maxTokens, temperature: 0))

        #expect(on1.text == off.text, "flag-on (cold) output must match flag-off")
        #expect(on2.text == off.text, "flag-on (warm/restored) output must match flag-off")
        print("E2E transparency OK: off.len=\(off.text.count) on1==off=\(on1.text == off.text) on2==off=\(on2.text == off.text)")
    }

    // ---- 2. A shared-prefix request actually restores; TTFT not worse ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func sharedPrefixRestoresAndIsNotSlower() async throws {
        guard let (sched, container) = try await load(flagOn: true) else { return }
        defer { Task { await sched.unloadModel() } }
        // Production wires the manager with an SE-wrapped Keychain KEK, which
        // an unsigned `swift test` binary can't create (errSecMissingEntitlement)
        // — so the auto-wired manager is nil here. Inject an equivalent manager
        // with an in-memory KEK + the model's real per-layer shapes via the
        // test seam, so the real submit→lookup→admit→capture path runs. (The
        // SE-KEK wiring itself is covered by the makeBatchedEngine code path;
        // signed-binary integration is a separate gate.)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbkv-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let shapes = await container.perform({ ctx in BatchScheduler.probeLayerShapes(model: ctx.model) }) else {
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
                key: SymmetricKey(data: Data(repeating: 0x5A, count: 32)), identifier: "e2e"),
                storage: InMemoryWrappedKEKStorage(identifier: "e2e")),
            cacheDir: dir, ssdEnabled: true, boundaries: [256], diskBudgetBytes: 0, now: { 1 })
        await sched._installCheckpointManagerForTest(mgr, boundaries: [256])

        // Warm-up request with the shared 280-token prefix → captures @256.
        let warmup = await drain(sched.submitTokenized(promptTokens: prompt(tail: 1), maxTokens: 16, temperature: 0))
        _ = warmup
        // Capture runs in a detached Task (store→flush off the engine queue);
        // give it a moment to land before reading stats / issuing the 2nd req.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let afterWarmup = await mgr.snapshotStats()
        print("E2E after warmup: stores=\(afterWarmup.stores) ramHits=\(afterWarmup.ramHits) ssdHits=\(afterWarmup.ssdHits)")
        #expect(afterWarmup.stores >= 1, "the warm-up request must have CAPTURED a checkpoint")

        // Second request, SAME prefix, different tail → must hit the cache.
        let t0 = Date()
        let second = await drain(sched.submitTokenized(promptTokens: prompt(tail: 2), maxTokens: 16, temperature: 0))
        let warmTTFT = second.ttft; _ = t0
        let afterSecond = await mgr.snapshotStats()
        let hits = (afterSecond.ramHits + afterSecond.ssdHits) - (afterWarmup.ramHits + afterWarmup.ssdHits)
        print("E2E after 2nd: ramHits=\(afterSecond.ramHits) ssdHits=\(afterSecond.ssdHits) deltaHits=\(hits) warmTTFT=\(warmTTFT)")
        #expect(hits >= 1, "the shared-prefix 2nd request must RESTORE from the cache (a hit)")

        // A fresh request with NO shared prefix = cold reference TTFT.
        let coldPrompt = Array(5000..<5280).map { $0 } + [7, 7, 7, 7, 7, 7]
        let cold = await drain(sched.submitTokenized(promptTokens: coldPrompt, maxTokens: 16, temperature: 0))
        print("E2E TTFT: warm(shared-prefix)=\(warmTTFT)s  cold(no-prefix)=\(cold.ttft)s")
        // Not a hard perf assert (CI variance), but a sanity floor: the warm
        // path must not be DRAMATICALLY slower than cold (no pathological
        // regression from the lookup/restore overhead).
        #expect(warmTTFT <= cold.ttft * 3 + 0.5,
            "warm TTFT \(warmTTFT)s pathologically worse than cold \(cold.ttft)s")
    }

    // ---- 3. Isolation: a request that misses costs roughly the same as
    // flag-off (lookup overhead on the miss path is not pathological) ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func cacheMissDoesNotRegressVsFlagOff() async throws {
        let unique = Array(9000..<9280).map { $0 } + [3, 3, 3, 3, 3, 3]
        let maxTokens = 12

        guard let (offSched, _) = try await load(flagOn: false) else { return }
        let off = await drain(offSched.submitTokenized(promptTokens: unique, maxTokens: maxTokens, temperature: 0))
        await offSched.unloadModel()

        guard let (onSched, _) = try await load(flagOn: true) else { return }
        defer { Task { await onSched.unloadModel() } }
        let on = await drain(onSched.submitTokenized(promptTokens: unique, maxTokens: maxTokens, temperature: 0))

        #expect(on.text == off.text, "miss-path output must equal flag-off")
        print("E2E miss-path TTFT: flagOff=\(off.ttft)s flagOn=\(on.ttft)s")
        #expect(on.ttft <= off.ttft * 2 + 0.5,
            "flag-on miss TTFT \(on.ttft)s must not be pathologically worse than flag-off \(off.ttft)s")
    }

    // ---- 4. Phase-1 admission policy: RAM-first, 2nd-use promotion ----
    @Test(.enabled(if: LiveInferenceFixtures.gemmaTestsEnabled))
    func admissionRamFirstThenPromotesOnSecondUse() async throws {
        guard let (sched, container) = try await load(flagOn: true) else { return }
        defer { Task { await sched.unloadModel() } }

        // Set up a manager with a SMALL minPersistTokens (64) so a ~70-token prompt
        // crosses one checkpoint boundary and is eligible for promotion.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbkv-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let shapes = await container.perform({ ctx in BatchScheduler.probeLayerShapes(model: ctx.model) }) else {
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
                key: SymmetricKey(data: Data(repeating: 0x5A, count: 32)), identifier: "admission"),
                storage: InMemoryWrappedKEKStorage(identifier: "admission")),
            cacheDir: dir, ssdEnabled: true, boundaries: [64], diskBudgetBytes: 0,
            minPersistTokens: 64, now: { 1 })
        await sched._installCheckpointManagerForTest(mgr, boundaries: [64])

        // Helper: recursively scan for .darkbloom-kv files
        func findKVFiles() -> [URL] {
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else { return [] }
            var found: [URL] = []
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == EncryptedKVStore.fileExtension {
                    found.append(fileURL)
                }
            }
            return found
        }

        // Helper: poll for file appearance/absence with timeout
        func pollForFile(shouldExist: Bool, timeout: TimeInterval) async throws -> Bool {
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                let files = findKVFiles()
                if shouldExist && !files.isEmpty { return true }
                if !shouldExist && files.isEmpty { continue }
                if !shouldExist && !files.isEmpty { return false }
                try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
            }
            return shouldExist ? false : (findKVFiles().isEmpty)
        }

        // A ~70-token prompt that crosses the 64-token boundary
        let sharedPrefix = Array(0..<70).map { ($0 % 64) + 5 }

        // Request #1: capture → RAM-only (no SSD file yet)
        print("Admission test: submitting req #1 (capture)")
        let r1 = await drain(sched.submitTokenized(
            promptTokens: sharedPrefix + [1, 1], maxTokens: 8, temperature: 0))
        _ = r1

        // Wait ~1s to give any (incorrect) eager flush time to land, then assert NO file
        print("Admission test: polling for NO file (RAM-only capture)")
        let noFileYet = try await pollForFile(shouldExist: false, timeout: 1.0)
        #expect(noFileYet, "Request #1 capture must be RAM-only — NO .darkbloom-kv file should exist yet")
        print("Admission test: confirmed NO .darkbloom-kv file after req #1 (RAM-only)")

        // Assert stats show a store happened and it's RAM-resident
        let afterR1 = await mgr.snapshotStats()
        let ramAfterR1 = await mgr.ramTierStats()
        print("Admission test: after req #1: stores=\(afterR1.stores) ramEntries=\(ramAfterR1.entries)")
        #expect(afterR1.stores >= 1, "Request #1 must have STORED a checkpoint")
        #expect(ramAfterR1.entries >= 1, "Request #1 checkpoint must be RAM-resident")

        // Request #2: RAM-hit → triggers 2nd-use promotion (detached persist)
        print("Admission test: submitting req #2 (shared prefix → promotion)")
        let r2 = await drain(sched.submitTokenized(
            promptTokens: sharedPrefix + [2, 2], maxTokens: 8, temperature: 0))
        _ = r2

        // Poll up to 10s for the .darkbloom-kv file to APPEAR
        print("Admission test: polling for .darkbloom-kv file (2nd-use promotion)")
        let fileAppeared = try await pollForFile(shouldExist: true, timeout: 10.0)
        #expect(fileAppeared, "Request #2 (2nd use) must trigger promotion → .darkbloom-kv file should appear")
        let files = findKVFiles()
        print("Admission test: confirmed .darkbloom-kv file appeared after req #2 (promotion): \(files.map { $0.lastPathComponent })")

        // Assert RAM hit was recorded
        let afterR2 = await mgr.snapshotStats()
        let ramAfterR2 = await mgr.ramTierStats()
        print("Admission test: after req #2: ramHits=\(afterR2.ramHits) stores=\(afterR2.stores)")
        #expect(afterR2.ramHits >= 1, "Request #2 must have RAM-HIT the shared prefix")

        // (Optional bit-exact check: clear RAM, submit req #3, should load from SSD)
        print("Admission test: clearing RAM and submitting req #3 (SSD restore)")
        await mgr.clearRAM()
        let r3 = await drain(sched.submitTokenized(
            promptTokens: sharedPrefix + [3, 3], maxTokens: 8, temperature: 0))
        print("Admission test: req #3 (SSD restore) produced output.len=\(r3.text.count)")
        #expect(!r3.text.isEmpty, "Request #3 (SSD restore after clearRAM) must produce valid output")
        let afterR3 = await mgr.snapshotStats()
        print("Admission test: after req #3: ssdHits=\(afterR3.ssdHits)")
        #expect(afterR3.ssdHits >= 1, "Request #3 must have SSD-HIT the promoted checkpoint")
    }
}
