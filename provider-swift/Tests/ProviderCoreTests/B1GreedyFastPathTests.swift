// B1GreedyFastPathTests -- unit coverage for the B=1 greedy fast-path
// eligibility policy, plus an opt-in live A/B benchmark that compares the
// fast path against the batched engine on Gemma-4.
//
// The eligibility tests are pure and run in CI (no model, no GPU). The
// benchmark is gated exactly like `Gemma4DecodeProfileTests`:
//
//   DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_LIVE_MLX_GEMMA=1 \
//     DARKBLOOM_GEMMA_MODEL=mlx-community/gemma-4-26b-a4b-it-8bit \
//     swift test --filter B1GreedyFastPathBenchmark
//
// Set DARKBLOOM_GEMMA_PRINT_TEXT=1 to print a short decoded sample from each
// path so a reviewer can eyeball output parity.

import Foundation
import Testing
import MLX
import MLXLMCommon
import MLXVLM
@testable import ProviderCore

// MARK: - Pure eligibility policy (CI-safe, no model)

@Suite("B=1 fast-path eligibility")
struct B1GreedyFastPathEligibilityTests {

    /// All conditions satisfied for a single exclusive greedy Gemma-4 request.
    private func eligible(
        enabled: Bool = true,
        allowFastPath: Bool = true,
        modelId: String = "mlx-community/gemma-4-26b-a4b-it-8bit",
        kvQuantEnabled: Bool = false,
        temperature: Float = 0,
        topP: Float? = nil,
        topK: Int? = nil,
        seed: UInt64? = nil,
        promptTokenCount: Int = 16,
        maxTokens: Int = 128,
        maxContextLength: Int = 8192,
        cacheScope: String = "",
        activeBridgeCount: Int = 0,
        pendingRequestCount: Int = 0,
        fastPathActive: Bool = false,
        hasContainer: Bool = true
    ) -> Bool {
        BatchScheduler.b1FastPathEligiblePure(
            enabled: enabled,
            allowFastPath: allowFastPath,
            modelId: modelId,
            kvQuantEnabled: kvQuantEnabled,
            temperature: temperature,
            topP: topP,
            topK: topK,
            seed: seed,
            promptTokenCount: promptTokenCount,
            maxTokens: maxTokens,
            maxContextLength: maxContextLength,
            cacheScope: cacheScope,
            activeBridgeCount: activeBridgeCount,
            pendingRequestCount: pendingRequestCount,
            fastPathActive: fastPathActive,
            hasContainer: hasContainer
        )
    }

    @Test("the canonical single greedy request is eligible")
    func canonicalEligible() {
        #expect(eligible())
    }

    @Test("disabled gate short-circuits everything")
    func disabledIsIneligible() {
        #expect(!eligible(enabled: false))
    }

    @Test("non-greedy sampling is ineligible")
    func samplingIsIneligible() {
        #expect(!eligible(temperature: 0.7))
        #expect(!eligible(topP: 0.9))
        #expect(!eligible(topK: 40))
        #expect(!eligible(seed: 42))
        // Inert/disabled sampling knobs do NOT disqualify a greedy request.
        #expect(eligible(topP: 0))
        #expect(eligible(topK: 0))
    }

    @Test("zero / negative maxTokens is ineligible")
    func badMaxTokensIneligible() {
        #expect(!eligible(maxTokens: 0))
        #expect(!eligible(maxTokens: -5))
    }

    @Test("an empty prompt is ineligible")
    func emptyPromptIneligible() {
        #expect(!eligible(promptTokenCount: 0))
    }

    @Test("the caller can force the request onto the engine path")
    func callerOptOutIsIneligible() {
        // Tool-bearing requests clear this so they never take the text-only path.
        #expect(!eligible(allowFastPath: false))
    }

    @Test("only Gemma-family models are eligible")
    func nonGemmaIsIneligible() {
        #expect(!eligible(modelId: "mlx-community/Qwen3.5-30B-8bit"))
        #expect(!eligible(modelId: ""))
        // Case-insensitive family match.
        #expect(eligible(modelId: "google/Gemma-4-it"))
    }

    @Test("KV quantization disqualifies the fast path (fp16 KV under-reserve)")
    func kvQuantIsIneligible() {
        #expect(!eligible(kvQuantEnabled: true))
    }

    @Test("a prompt+generation span over the context window defers to the engine")
    func overContextIsIneligible() {
        // prompt + maxTokens must fit the model context window.
        #expect(!eligible(promptTokenCount: 8000, maxTokens: 512, maxContextLength: 8192))
        // Exactly at the limit is fine.
        #expect(eligible(promptTokenCount: 8064, maxTokens: 128, maxContextLength: 8192))
        // Unknown context (0) skips the gate — other gates still apply.
        #expect(eligible(promptTokenCount: 100000, maxTokens: 4096, maxContextLength: 0))
    }

    @Test("a prefix-cache scope defers to the engine")
    func scopedIsIneligible() {
        #expect(!eligible(cacheScope: "tenant-abc"))
    }

    @Test("any concurrent or queued work disqualifies the exclusive fast path")
    func nonExclusiveIsIneligible() {
        #expect(!eligible(activeBridgeCount: 1))
        #expect(!eligible(pendingRequestCount: 1))
    }

    @Test("an already-running fast-path task disqualifies a second one")
    func fastPathActiveIsIneligible() {
        #expect(!eligible(fastPathActive: true))
    }

    @Test("a missing container is ineligible")
    func noContainerIneligible() {
        #expect(!eligible(hasContainer: false))
    }

    @Test("fast path is ON by default; env flags opt OUT")
    func envFlagDefaultOn() {
        // Default ON: the gate is true unless EITHER flag is set to a falsey
        // value (0/false/no/off). The CI runner does not set them, so the gate
        // is true. (If a developer exported an opt-out, this documents the
        // expectation rather than asserting a hard true.)
        let env = ProcessInfo.processInfo.environment
        let off: Set<String> = ["0", "false", "no", "off"]
        let optedOut =
            off.contains((env["DARKBLOOM_B1_GREEDY_FAST_PATH"] ?? "").lowercased())
            || off.contains((env["DARKBLOOM_GEMMA_B1_FAST_PATH"] ?? "").lowercased())
        #expect(BatchScheduler.b1GreedyFastPathEnabled() == !optedOut)
    }
}

// MARK: - Live A/B benchmark (opt-in)

/// One measured generation through the scheduler's tokenized submit path.
private struct FastPathRun {
    var text: String = ""
    var promptTokens: Int = 0
    var completionTokens: Int = 0
    var tokensPerSecond: Double = 0
    var error: String?
    var wallSeconds: Double = 0
}

@Suite("B=1 fast-path benchmark", .serialized)
struct B1GreedyFastPathBenchmark {

    /// Submit a pre-tokenized greedy request and collect the full event stream.
    private func runTokenized(
        scheduler: BatchScheduler,
        promptTokens: [Int],
        maxTokens: Int
    ) async -> FastPathRun {
        let start = ContinuousClock.now
        let stream = await scheduler.submitTokenized(
            promptTokens: promptTokens,
            maxTokens: maxTokens,
            temperature: 0.0,
            requestId: "b1-bench-\(UUID().uuidString.prefix(8))"
        )
        var run = FastPathRun()
        var chunks: [String] = []
        for await event in stream {
            switch event {
            case .chunk(let text):
                chunks.append(text)
            case .info(let prompt, let completion, let tps):
                run.promptTokens = prompt
                run.completionTokens = completion
                run.tokensPerSecond = tps
            case .error(let message):
                run.error = message
            }
        }
        run.text = chunks.joined()
        run.wallSeconds = (ContinuousClock.now - start).asSeconds
        return run
    }

    /// Median tokens/sec of `iterations` measured runs after one warmup, for a
    /// given fast-path mode.
    private func measure(
        scheduler: BatchScheduler,
        promptTokens: [Int],
        maxTokens: Int,
        fastPath: Bool,
        warmups: Int,
        iterations: Int
    ) async -> (median: FastPathRun, all: [FastPathRun]) {
        await scheduler._setForceB1FastPathForTest(fastPath)
        for _ in 0 ..< warmups {
            _ = await runTokenized(
                scheduler: scheduler, promptTokens: promptTokens, maxTokens: maxTokens)
        }
        var runs: [FastPathRun] = []
        for _ in 0 ..< iterations {
            runs.append(await runTokenized(
                scheduler: scheduler, promptTokens: promptTokens, maxTokens: maxTokens))
        }
        let sorted = runs.sorted { $0.tokensPerSecond < $1.tokensPerSecond }
        return (sorted[sorted.count / 2], runs)
    }

    @Test(
        "fast path vs batched engine decode TPS (Gemma-4)",
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil
        )
    )
    func fastPathVsEngine() async throws {
        if LiveInferenceFixtures.ensureMetallibColocated() == nil {
            Issue.record("mlx.metallib not found near test bundle or in MLX_METALLIB_PATH/SOURCE")
            return
        }
        MLX.GPU.set(memoryLimit: 96 * 1024 * 1024 * 1024)

        let modelID = ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA_MODEL"]
            ?? "mlx-community/gemma-4-26b-a4b-it-8bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache")
            return
        }

        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())

        let scheduler = BatchScheduler(
            maxConcurrentRequests: 1,
            pendingTimeout: .seconds(120),
            defaultMaxTokens: 512
        )
        await scheduler.loadModel(container: container, modelId: modelID)
        defer { Task { await scheduler.unloadModel() } }

        let prompt = "Write a detailed technical explanation of sparse "
            + "mixture-of-experts inference on Apple Silicon."
        let promptTokens: [Int] = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": prompt]],
                tools: nil,
                additionalContext: nil)
        }

        let maxTokens = 256
        let warmups = 1
        let iterations = 3

        // Engine (batched) baseline first, then the fast path. Order is fixed so
        // both pay an equal share of any thermal drift across the run.
        let engine = await measure(
            scheduler: scheduler, promptTokens: promptTokens, maxTokens: maxTokens,
            fastPath: false, warmups: warmups, iterations: iterations)
        let fast = await measure(
            scheduler: scheduler, promptTokens: promptTokens, maxTokens: maxTokens,
            fastPath: true, warmups: warmups, iterations: iterations)
        await scheduler._setForceB1FastPathForTest(nil)

        let e = engine.median
        let f = fast.median
        let ratio = e.tokensPerSecond > 0 ? f.tokensPerSecond / e.tokensPerSecond : 0
        let commonPrefix = sharedPrefixCount(e.text, f.text)

        print("""
            [b1-fastpath-benchmark] model=\(modelID) prompt_tokens=\(promptTokens.count) max_tokens=\(maxTokens)
            [b1-fastpath-benchmark] engine_median_tps=\(fmt(e.tokensPerSecond)) completion=\(e.completionTokens)
            [b1-fastpath-benchmark] fast_median_tps=\(fmt(f.tokensPerSecond)) completion=\(f.completionTokens)
            [b1-fastpath-benchmark] speedup=\(fmt(ratio))x shared_text_prefix_chars=\(commonPrefix)
            """)
        if ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA_PRINT_TEXT"] != nil {
            print("[b1-fastpath-benchmark] engine_sample=\(e.text.prefix(160).debugDescription)")
            print("[b1-fastpath-benchmark] fast_sample=\(f.text.prefix(160).debugDescription)")
        }

        // Correctness: both paths must produce real output.
        #expect(e.error == nil, "engine path errored: \(e.error ?? "")")
        #expect(f.error == nil, "fast path errored: \(f.error ?? "")")
        #expect(!e.text.isEmpty, "engine path produced empty text")
        #expect(!f.text.isEmpty, "fast path produced empty text")
        #expect(e.completionTokens > 0 && f.completionTokens > 0)
        // Greedy decode from the same prompt should agree on the opening text
        // (the first argmax over the same prefill logits). A long shared prefix
        // is strong evidence the fast path is byte-compatible; FP differences in
        // the batched vs. single-row kernels can diverge later, so we only
        // require a non-trivial shared opening rather than full equality.
        #expect(commonPrefix >= 8, "fast/engine greedy text diverged immediately (shared=\(commonPrefix))")

        // Throughput: the fast path must not regress materially. The whole point
        // is that it is faster; allow generous noise so a busy CI box can't flake.
        #expect(
            f.tokensPerSecond >= e.tokensPerSecond * 0.85,
            "fast path regressed vs engine (\(fmt(f.tokensPerSecond)) < 0.85 * \(fmt(e.tokensPerSecond)))"
        )

        // Cleanup invariant: no reservations / bridges left behind.
        let cap = await scheduler.capacity()
        #expect(cap.activeRequests == 0, "left \(cap.activeRequests) active requests")
        #expect(cap.pendingRequests == 0, "left \(cap.pendingRequests) pending requests")
        let fastTasks = await scheduler._fastPathTaskCountForTest()
        #expect(fastTasks == 0, "left \(fastTasks) fast-path tasks tracked")
    }

    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    /// Number of leading characters shared by two strings.
    private func sharedPrefixCount(_ a: String, _ b: String) -> Int {
        let ca = Array(a), cb = Array(b)
        var i = 0
        while i < ca.count, i < cb.count, ca[i] == cb[i] { i += 1 }
        return i
    }
}

private extension Duration {
    var asSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
