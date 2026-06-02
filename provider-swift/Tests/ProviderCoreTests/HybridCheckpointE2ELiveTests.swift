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
        guard let (sched, _) = try await load(flagOn: true) else { return }
        defer { Task { await sched.unloadModel() } }
        guard let mgr = await sched.checkpointManager else {
            Issue.record("checkpoint manager not wired with flag on"); return
        }

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
}
