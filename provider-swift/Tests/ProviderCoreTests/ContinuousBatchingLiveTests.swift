import Foundation
import Testing
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers
@testable import ProviderCore

/// Greedy-decoding diff tests: batched output must match single-stream
/// output token-for-token (subject to bf16/fp16 reduction-order drift on
/// later tokens). Drives `MLXLMCommon.BatchedEngine` directly so we test
/// engine semantics independent of `BatchScheduler`. Gated by
/// `DARKBLOOM_LIVE_MLX_TESTS=1`; Gemma additionally needs
/// `DARKBLOOM_LIVE_MLX_GEMMA=1` (27 GB load).
@Suite(
    "continuous batching: greedy diff against single-stream reference",
    .serialized
)
struct ContinuousBatchingLiveTests {

    @Test(
        "Qwen3 0.6B, B=2",
        .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil)
    )
    func qwenTinyDiffB2() async throws {
        try await runDiffTest(
            modelID: "mlx-community/Qwen3-0.6B-8bit",
            prompts: [
                "Reply with the single word 'hello'.",
                "Count from 1 to 3.",
            ],
            maxTokens: 12
        )
    }

    @Test(
        "Qwen3 0.6B, B=4 ragged lengths",
        .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil)
    )
    func qwenTinyDiffB4Ragged() async throws {
        try await runDiffTest(
            modelID: "mlx-community/Qwen3-0.6B-8bit",
            prompts: [
                "Hi.",
                "Reply with one word: yes.",
                "List three colors briefly.",
                "What is 2 + 2? Answer with just the number.",
            ],
            maxTokens: 8
        )
    }

    @Test(
        "Gemma 4 26B-A4B-it-8bit (MoE), B=2",
        .enabled(if:
            ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil
        )
    )
    func gemma4MoEDiffB2() async throws {
        try await runDiffTest(
            modelID: "mlx-community/gemma-4-26b-a4b-it-8bit",
            prompts: [
                "What is 7 * 8? Reply with just the number.",
                "Reply with the single word 'sky'.",
            ],
            maxTokens: 6,
            wiredMemoryGB: 64
        )
    }

    /// Production reproduction: `gemma-4-26b` ships with `vision_config`, so the
    /// provider loads it via `VLMModelFactory` and serves text through the VLM
    /// model's batched path. That path used a scalar `cache.offset` for RoPE
    /// (wrong per-row positions in a mixed-length batch) and an explicit-mask
    /// fused kernel (MLX #3384 4-bit drift) — together producing the repetition
    /// users hit. This test loads via the VLM factory (NOT LLMModelFactory like
    /// `runDiffTest`), runs a mixed-length B=2 greedy batch on the 4-bit QAT
    /// build, and asserts the output is coherent (no degenerate repetition) and
    /// the short row tracks its single-stream reference.
    @Test(
        "Gemma 4 VLM qat-4bit mixed-length batch is coherent (no repetition)",
        .enabled(if:
            ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil
        )
    )
    func gemma4VLMMixedLengthCoherent() async throws {
        guard ensureMetallibAvailable() else { return }
        MLX.GPU.set(memoryLimit: 96 * 1024 * 1024 * 1024)

        let modelID = ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA_MODEL"]
            ?? "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache")
            return
        }

        // Production loads vision checkpoints through VLMModelFactory.
        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())

        // Deliberately different lengths so the shorter row carries left-padding
        // (the case the scalar-offset bug mis-positions). Row 0 is the shorter,
        // higher-entropy prompt — open-ended continuations have close argmax
        // calls, so wrong RoPE positions / mask-kernel drift flip the top token
        // and trap it in a loop (the "One of of of of" failure mode).
        let prompts = [
            "Tell me something interesting about machine learning.",
            "Write a detailed multi-paragraph essay about the history, present state, "
                + "and likely future of renewable energy technologies across the world.",
        ]
        let encoded: [[Int]] = try await container.perform { ctx in
            try prompts.map {
                try ctx.tokenizer.applyChatTemplate(
                    messages: [["role": "user", "content": $0]],
                    tools: nil, additionalContext: nil)
            }
        }
        let maxTokens = 110

        let batched = try await runBatchedEngine(
            container: container, modelID: modelID, prompts: encoded, maxTokens: maxTokens)
        let single = await singleStreamGreedy(
            container: container, prompts: encoded, maxTokens: maxTokens)

        // The batched engine honors EOS, so coherent rows terminate cleanly.
        // This is the path under test (per-row offset + manual masked attention);
        // it must not degenerate into repetition.
        for (k, toks) in batched.enumerated() {
            let text = await container.decode(tokenIds: toks)
            print("[gemma4-vlm-mixed] batched row \(k): \(text)")
            #expect(
                !Self.hasDegenerateRepetition(toks),
                Comment(rawValue: "batched row \(k) degenerates into repetition: \(toks)"))
        }
        // The short, low-entropy row 0 is the one mis-positioned by the
        // scalar-offset bug. Compare batched vs single-stream up to the natural
        // end-of-turn (the fixed-length single-stream helper force-generates
        // past EOS, so only the pre-EOS prefix is meaningful). With per-row
        // offsets the two agree on the opening tokens.
        let eos = 106
        let singleHead = Array(single[0].prefix(while: { $0 != eos }))
        let batchedHead = Array(batched[0].prefix(while: { $0 != eos }))
        let shortMatch = zip(batchedHead, singleHead).prefix(while: ==).count
        #expect(
            shortMatch >= 3,
            Comment(rawValue:
                "short row diverges immediately (batched=\(batchedHead) single=\(singleHead))"))
    }

    @Test(
        "Gemma 4 VLM qat-4bit provider-path decode throughput",
        .enabled(if:
            ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil
        )
    )
    func gemma4VLMProviderPathThroughput() async throws {
        try ensureMetallibAvailable()
        MLX.GPU.set(memoryLimit: 96 * 1024 * 1024 * 1024)

        let modelID = ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA_MODEL"]
            ?? "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache")
            return
        }

        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())
        let promptTokens: [Int] = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": "Write a concise paragraph about distributed inference."]],
                tools: nil,
                additionalContext: nil)
        }

        let decodeTokens = 64
        let direct = await timedSingleStream(container: container, prompt: promptTokens, decodeTokens: decodeTokens)
        let b1 = await timedBatchedEngine(
            container: container, modelID: modelID, prompts: [promptTokens], decodeTokens: decodeTokens)
        let b2 = await timedBatchedEngine(
            container: container, modelID: modelID,
            prompts: [promptTokens, promptTokens + Array(repeating: 105, count: 48)],
            decodeTokens: decodeTokens)

        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            pendingTimeout: .seconds(60),
            defaultMaxTokens: decodeTokens + 1)
        await scheduler.loadModel(container: container, modelId: modelID)
        defer { Task { await scheduler.unloadModel() } }
        let schedStream = await scheduler.submitTokenized(
            promptTokens: promptTokens,
            maxTokens: decodeTokens + 1,
            temperature: 0.0)
        var schedulerTPS = 0.0
        for await event in schedStream {
            if case .info(_, let completion, let tps) = event, completion > 1 {
                schedulerTPS = tps
            }
        }

        print("[gemma4-vlm-throughput] direct-single-cache B=1: \(String(format: "%.1f", direct)) tok/s")
        print("[gemma4-vlm-throughput] batched-engine B=1: \(String(format: "%.1f", b1)) tok/s")
        print("[gemma4-vlm-throughput] batched-engine B=2 aggregate: \(String(format: "%.1f", b2)) tok/s")
        print("[gemma4-vlm-throughput] BatchScheduler.submitTokenized: \(String(format: "%.1f", schedulerTPS)) tok/s")

        #expect(direct > 0)
        #expect(b1 > 0)
        #expect(b2 > 0)
        #expect(schedulerTPS > 0)
    }

    /// Detects degenerate generation: an n-gram (n = 1...4) repeated
    /// consecutively many times — the signature of decode loops like
    /// "of of of", "you've you've", or "the era of the era of the era of".
    /// Coherent prose never trips this; the batching bug produces exactly
    /// these cycles.
    static func hasDegenerateRepetition(_ tokens: [Int]) -> Bool {
        for n in 1 ... 4 {
            let minReps = n == 1 ? 8 : (n == 2 ? 6 : 4)
            var i = 0
            while i + n * minReps <= tokens.count {
                let gram = Array(tokens[i ..< i + n])
                var reps = 1
                var j = i + n
                while j + n <= tokens.count && Array(tokens[j ..< j + n]) == gram {
                    reps += 1
                    j += n
                }
                if reps >= minReps { return true }
                i += 1
            }
        }
        return false
    }

    /// Long-context, mixed-length B=3 correctness for the optimized
    /// `BatchRotatingKVCache` decode ring + per-row RoPE offset. Row 2 is a
    /// ~1k-token prompt, so prompt + generation crosses the Gemma sliding
    /// window (`slidingWindow == 1024`) DURING decode — the regime that
    /// exercises the fast path's window slide / ring compaction and, crucially,
    /// the per-row `batchOffset` past the window (the scalar `cache.offset`
    /// caps at the window and mis-positions every post-window query, which the
    /// `gemma4VLMGraphOffsetArray` fix corrects). Each row's batched greedy
    /// output is compared against its single-stream (`RotatingKVCache`)
    /// reference and must (a) never degenerate into repetition and (b) track
    /// the reference at least past the deterministic floor. ≥64 tokens are
    /// generated so the long row decodes well past the window edge.
    @Test(
        "Gemma 4 VLM long-context (~1k) mixed-length B=3 tracks solo + stays coherent",
        .enabled(if:
            ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil
        )
    )
    func gemma4VLMLongContextMixedB3() async throws {
        guard ensureMetallibAvailable() else { return }
        MLX.GPU.set(memoryLimit: 96 * 1024 * 1024 * 1024)

        let modelID = ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA_MODEL"]
            ?? "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache")
            return
        }
        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())

        // Row 0: short, low-entropy (deterministic floor). Row 1: medium.
        // Row 2: ~1k tokens — long enough that prompt + 64 generated tokens
        // crosses the 1024 sliding window mid-decode.
        let longBody = String(
            repeating: "Renewable energy has reshaped the global grid in many ways. ",
            count: 130)
        let prompts = [
            "Reply with the single word 'ocean'.",
            "Briefly, what is photosynthesis?",
            "Read the following notes and then summarize them in one paragraph.\n\n"
                + longBody,
        ]
        let encoded: [[Int]] = try await container.perform { ctx in
            try prompts.map {
                try ctx.tokenizer.applyChatTemplate(
                    messages: [["role": "user", "content": $0]],
                    tools: nil, additionalContext: nil)
            }
        }
        let lengths = encoded.map { $0.count }
        print("[gemma4-vlm-longctx] prompt token lengths: \(lengths)")
        #expect(
            lengths[2] >= 900,
            Comment(rawValue: "long row only \(lengths[2]) tokens; want ~1k to cross the window"))

        let maxTokens = 80  // ≥ 64; long row decodes past the 1024 window edge
        let batched = try await runBatchedEngine(
            container: container, modelID: modelID, prompts: encoded, maxTokens: maxTokens)
        let single = await singleStreamGreedy(
            container: container, prompts: encoded, maxTokens: maxTokens)

        let eos = 106
        for row in 0 ..< prompts.count {
            let toks = batched[row]
            let text = await container.decode(tokenIds: toks)
            print("[gemma4-vlm-longctx] batched row \(row) (\(toks.count) toks): \(text.prefix(160))")
            #expect(
                !Self.hasDegenerateRepetition(toks),
                Comment(rawValue: "batched row \(row) degenerates into repetition: \(toks)"))

            let singleHead = Array(single[row].prefix(while: { $0 != eos }))
            let batchedHead = Array(toks.prefix(while: { $0 != eos }))
            let match = zip(batchedHead, singleHead).prefix(while: ==).count
            print(
                "[gemma4-vlm-longctx] row \(row): batched/solo prefix match = \(match) "
                    + "(batchedHead=\(batchedHead.count), soloHead=\(singleHead.count))")
            // Row 0 is low-entropy → strong deterministic agreement. Rows 1/2
            // are higher-entropy MoE continuations where bf16 argmax flips can
            // diverge after the floor; the regression we guard is repetition /
            // immediate divergence, so require a small positive prefix match.
            let required = row == 0 ? 3 : 1
            #expect(
                match >= required,
                Comment(rawValue:
                    "row \(row) diverges below floor \(required) (match=\(match), "
                        + "batched=\(batchedHead.prefix(8)), solo=\(singleHead.prefix(8)))"))
        }
    }

    /// Provider-stack decode throughput at B=1/2/3 for the optimized
    /// `BatchRotatingKVCache`. Drives the same `BatchedEngine` the provider
    /// uses (via `runBatchedEngine`) with a ~1k-token prompt per row and times
    /// the full prefill+decode, reporting aggregate tok/s per batch width.
    ///
    /// OLD vs NEW comparison (the optimization is a runtime gate, so no rebuild
    /// is needed):
    /// ```
    /// # NEW (in-place decode ring, default):
    /// DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_LIVE_MLX_GEMMA=1 DARKBLOOM_BENCH=1 \
    ///   swift test --filter gemma4DecodeRingBenchmarkB1B2B3
    /// # OLD (legacy concat+trim path):
    /// DARKBLOOM_FAST_BATCH_ROTATING_KV=0 DARKBLOOM_LIVE_MLX_TESTS=1 \
    ///   DARKBLOOM_LIVE_MLX_GEMMA=1 DARKBLOOM_BENCH=1 \
    ///   swift test --filter gemma4DecodeRingBenchmarkB1B2B3
    /// ```
    /// `DARKBLOOM_BENCH_OUTPUT` overrides the generated-token count (default
    /// 256; set 512 to match the production decode benchmark). Diagnostic
    /// (prints tok/s); the only assertion is that every row produced output.
    @Test(
        "BENCHMARK: gemma4DecodeRingBenchmarkB1B2B3 (BatchRotatingKVCache decode TPS)",
        .enabled(if:
            ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_BENCH"] != nil
        )
    )
    func gemma4DecodeRingBenchmarkB1B2B3() async throws {
        guard ensureMetallibAvailable() else { return }
        MLX.GPU.set(memoryLimit: 96 * 1024 * 1024 * 1024)

        let env = ProcessInfo.processInfo.environment
        let fastGate = env["DARKBLOOM_FAST_BATCH_ROTATING_KV"].map {
            !["0", "false", "no", "off"].contains($0.lowercased())
        } ?? true
        let outputTokens = env["DARKBLOOM_BENCH_OUTPUT"].flatMap { Int($0) } ?? 256

        let modelID = env["DARKBLOOM_GEMMA_MODEL"]
            ?? "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache")
            return
        }
        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())

        // ~973-token prompt to match the production decode benchmark; with
        // outputTokens decode steps this crosses the 1024 sliding window.
        let body = String(
            repeating: "Renewable energy reshaped the global grid in many ways. ", count: 120)
        let encoded: [Int] = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": "Summarize:\n\n" + body]],
                tools: nil, additionalContext: nil)
        }
        print(
            "[gemma4-bench] fast_path=\(fastGate) prompt_tokens=\(encoded.count) "
                + "output_tokens=\(outputTokens) model=\(modelID)")

        for B in [1, 2, 3] {
            let prompts = Array(repeating: encoded, count: B)
            let t0 = Date()
            let toks = try await runBatchedEngine(
                container: container, modelID: modelID, prompts: prompts, maxTokens: outputTokens)
            let dt = Date().timeIntervalSince(t0)
            let generated = toks.reduce(0) { $0 + $1.count }
            let aggregateTPS = dt > 0 ? Double(generated) / dt : 0
            for t in toks {
                #expect(!t.isEmpty, Comment(rawValue: "B=\(B): a row produced no tokens"))
            }
            print(String(
                format: "[gemma4-bench] fast=%@ B=%d: %d tokens / %.2fs = %.1f tok/s aggregate",
                "\(fastGate)", B, generated, dt, aggregateTPS))
        }
    }

    @Test(
        "Qwen 3.5 0.8B-MLX-4bit (hybrid SSM+attention), B=2",
        .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil)
    )
    func qwen35HybridDiffB2() async throws {
        try await runDiffTest(
            modelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit",
            prompts: [
                "What is 7 * 8? Reply with just the number.",
                "Reply with the single word 'sky'.",
            ],
            maxTokens: 6,
            wiredMemoryGB: 8
        )
    }

    /// Same prompt at every batch position must produce identical token
    /// streams. Catches cache leaks, mask leaks, and per-row offset bugs.
    @Test(
        "same prompt across positions is deterministic (Qwen3 0.6B, B=4)",
        .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil)
    )
    func samePromptDeterministicAcrossBatchPositions() async throws {
        guard ensureMetallibAvailable() else { return }

        let modelID = "mlx-community/Qwen3-0.6B-8bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache")
            return
        }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir,
            using: LocalTokenizerLoader()
        )

        let promptText = "Reply with the single word 'apple'."
        let encoded: [Int] = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": promptText]],
                tools: nil,
                additionalContext: nil
            )
        }
        let prompts = Array(repeating: encoded, count: 4)
        let maxTokens = 8

        let batched = try await runBatchedEngine(
            container: container,
            modelID: modelID,
            prompts: prompts,
            maxTokens: maxTokens
        )

        let reference = batched[0]
        for (k, b) in batched.enumerated().dropFirst() {
            let failMsg = "row \(k) diverges from row 0: \(b) vs \(reference)"
            #expect(b == reference, Comment(rawValue: failMsg))
        }
    }

    // MARK: - shared driver

    private func runDiffTest(
        modelID: String,
        prompts: [String],
        maxTokens: Int,
        wiredMemoryGB: Int? = nil
    ) async throws {
        guard ensureMetallibAvailable() else { return }
        if let wiredMemoryGB {
            MLX.GPU.set(memoryLimit: wiredMemoryGB * 1024 * 1024 * 1024)
        }

        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache")
            return
        }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir,
            using: LocalTokenizerLoader()
        )

        let encodedPrompts: [[Int]] = try await container.perform { ctx in
            try prompts.map { promptText -> [Int] in
                try ctx.tokenizer.applyChatTemplate(
                    messages: [["role": "user", "content": promptText]],
                    tools: nil,
                    additionalContext: nil
                )
            }
        }

        let singleStream = await singleStreamGreedy(
            container: container,
            prompts: encodedPrompts,
            maxTokens: maxTokens
        )

        let batched = try await runBatchedEngine(
            container: container,
            modelID: modelID,
            prompts: encodedPrompts,
            maxTokens: maxTokens
        )

        // Structural-correctness floor: bit-identical for the first few
        // tokens. Past that, greedy batched decode and single-stream
        // can diverge when bf16/fp16 reduction order flips a close-call
        // top-1 argmax (vLLM, mlx-lm, sglang all behave the same way).
        //
        // MoE models (e.g. Gemma 4 26B-A4B) diverge earlier because
        // expert routing is sensitive to those argmax flips: a slightly
        // different probability at any router triggers a different
        // expert subset, which cascades into different logits the very
        // next step. For MoE we only require the first token to match.
        let isMoEModel = modelID.lowercased().contains("a4b")
            || modelID.lowercased().contains("moe")
        #expect(batched.count == singleStream.count)
        let requiredMatch = isMoEModel ? 1 : max(1, min(4, maxTokens / 2))
        for (k, (b, s)) in zip(batched, singleStream).enumerated() {
            let matchedPrefixLen = zip(b, s).prefix(while: ==).count
            let failMsg =
                "row \(k): only \(matchedPrefixLen) tokens match (batched=\(b), single=\(s))"
            #expect(matchedPrefixLen >= requiredMatch, Comment(rawValue: failMsg))
            if matchedPrefixLen < b.count {
                print(
                    "[batched-diff] row \(k): \(matchedPrefixLen)/\(b.count) tokens identical "
                        + "(batched=\(b.prefix(matchedPrefixLen + 1)), single=\(s.prefix(matchedPrefixLen + 1)))"
                )
            }
        }
    }

    private func singleStreamGreedy(
        container: ModelContainer,
        prompts: [[Int]],
        maxTokens: Int
    ) async -> [[Int]] {
        await container.perform { ctx in
            prompts.map { tokenIds -> [Int] in
                let cache = ctx.model.newCache(parameters: nil)
                var produced: [Int] = []

                let promptArr = MLXArray(tokenIds.map { Int32($0) })
                    .reshaped([1, tokenIds.count])
                var logits = ctx.model.callAsFunction(promptArr, cache: cache)
                logits = logits[.ellipsis, -1, 0...]

                for _ in 0 ..< maxTokens {
                    let nextToken = argMax(logits, axis: -1)
                    eval(nextToken)
                    produced.append(Int(nextToken.asArray(Int32.self)[0]))

                    let stepArr = nextToken[0..., .newAxis]
                    logits = ctx.model.callAsFunction(stepArr, cache: cache)
                    logits = logits[.ellipsis, -1, 0...]
                }

                return produced
            }
        }
    }

    private func timedSingleStream(
        container: ModelContainer,
        prompt: [Int],
        decodeTokens: Int
    ) async -> Double {
        await container.perform { ctx in
            let cache = ctx.model.newCache(parameters: nil)
            let promptArr = MLXArray(prompt.map { Int32($0) }).reshaped([1, prompt.count])
            var logits = ctx.model.callAsFunction(promptArr, cache: cache)
            logits = logits[.ellipsis, -1, 0...]

            var produced = 0
            var start = ContinuousClock.now
            for i in 0 ..< (decodeTokens + 1) {
                let nextToken = argMax(logits, axis: -1)
                eval(nextToken)
                if i == 0 {
                    start = .now
                } else {
                    produced += 1
                }
                let stepArr = nextToken[0..., .newAxis]
                logits = ctx.model.callAsFunction(stepArr, cache: cache)
                logits = logits[.ellipsis, -1, 0...]
            }
            return Self.tokensPerSecond(produced, .now - start)
        }
    }

    private func timedBatchedEngine(
        container: ModelContainer,
        modelID: String,
        prompts: [[Int]],
        decodeTokens: Int
    ) async -> Double {
        let engine = await container.perform { ctx -> BatchedEngine in
            let scheduler = Scheduler(
                model: ctx.model,
                tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: max(4, prompts.count),
                    maxNumBatchedTokens: 8192,
                    prefillStepSize: 512,
                    streamInterval: 1
                ),
                eosTokenIds: ctx.configuration.eosTokenIds,
                prefixCache: nil
            )
            return BatchedEngine(
                scheduler: scheduler,
                tokenizer: ctx.tokenizer,
                modelName: modelID,
                config: ContinuousBatchingConfig(
                    schedulerConfig: scheduler.config,
                    stepInterval: 0.001,
                    prefixCacheConfig: nil,
                    mtpEnabled: false
                ),
                externalChatTemplate: nil
            )
        }
        await engine.start()
        defer { Task { await engine.stop() } }

        struct RowMeasure: Sendable {
            let produced: Int
            let elapsed: Duration
        }

        return await withTaskGroup(of: RowMeasure.self) { group -> Double in
            for (i, prompt) in prompts.enumerated() {
                let id = "throughput-\(i)-\(UUID().uuidString.prefix(6))"
                group.addTask { [engine] in
                    _ = await engine.core.addRequest(Request(
                        requestId: id,
                        prompt: prompt as AnyHashable,
                        samplingParams: SamplingParams(maxTokens: decodeTokens + 1, temperature: 0.0)
                    ))

                    var sawFirst = false
                    var start = ContinuousClock.now
                    var produced = 0
                    for await output in engine.core.streamOutputs(requestId: id) {
                        if !sawFirst {
                            sawFirst = true
                            start = .now
                        } else {
                            produced += output.newTokenIds.count
                        }
                        if output.finished || output.error != nil { break }
                    }
                    return RowMeasure(produced: produced, elapsed: .now - start)
                }
            }

            var totalTokens = 0
            var maxElapsed: Duration = .zero
            for await row in group {
                totalTokens += row.produced
                if row.elapsed > maxElapsed { maxElapsed = row.elapsed }
            }
            return Self.tokensPerSecond(totalTokens, maxElapsed)
        }
    }

    private static func tokensPerSecond(_ tokens: Int, _ duration: Duration) -> Double {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return seconds > 0 ? Double(tokens) / seconds : 0
    }

    /// Construct a `BatchedEngine` directly (bypassing `BatchScheduler`) and
    /// drive `prompts.count` greedy requests through it. Returns one token
    /// list per request, in the order `prompts` were submitted.
    private func runBatchedEngine(
        container: ModelContainer,
        modelID: String,
        prompts: [[Int]],
        maxTokens: Int
    ) async throws -> [[Int]] {
        // Build the engine inside the container actor so we can pass the
        // LanguageModel reference; the engine then runs on its own queue.
        let engine = await container.perform { ctx -> BatchedEngine in
            let scheduler = Scheduler(
                model: ctx.model,
                tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: max(4, prompts.count),
                    maxNumBatchedTokens: 8192,
                    prefillStepSize: 2048,
                    streamInterval: 1
                ),
                eosTokenIds: ctx.configuration.eosTokenIds,
                prefixCache: nil
            )
            return BatchedEngine(
                scheduler: scheduler,
                tokenizer: ctx.tokenizer,
                modelName: modelID,
                config: ContinuousBatchingConfig(
                    schedulerConfig: scheduler.config,
                    stepInterval: 0.001,
                    prefixCacheConfig: nil,
                    mtpEnabled: false
                ),
                externalChatTemplate: nil
            )
        }
        await engine.start()

        // `[Int]` prompts so the engine does not re-tokenize, matching
        // how `BatchScheduler` dispatches.
        struct Slot: Sendable {
            let index: Int
            let id: String
        }
        var slots: [Slot] = []
        slots.reserveCapacity(prompts.count)
        for (i, prompt) in prompts.enumerated() {
            let id = "test-\(i)-\(UUID().uuidString.prefix(6))"
            let req = Request(
                requestId: id,
                prompt: prompt as AnyHashable,
                samplingParams: SamplingParams(maxTokens: maxTokens, temperature: 0.0)
            )
            _ = await engine.core.addRequest(req)
            slots.append(Slot(index: i, id: id))
        }

        // Drain per-request streams in parallel.
        var collected: [[Int]] = Array(repeating: [], count: prompts.count)
        await withTaskGroup(of: (Int, [Int]).self) { group in
            for slot in slots {
                group.addTask { [engine] in
                    var tokens: [Int] = []
                    for await output in engine.core.streamOutputs(requestId: slot.id) {
                        tokens.append(contentsOf: output.newTokenIds)
                        if output.finished || output.error != nil { break }
                    }
                    return (slot.index, tokens)
                }
            }
            for await (idx, toks) in group {
                collected[idx] = toks
            }
        }

        // Synchronous stop: a detached teardown would race the next
        // helper invocation against a live engine on the shared
        // `ModelContainer`.
        await engine.stop()
        return collected
    }

    /// Place the matching `mlx.metallib` next to the test runner so the MLX
    /// C++ runtime's `dladdr` lookup finds it on the first GPU call.
    ///
    /// Returns `true` when the metallib is colocated (GPU work can proceed) and
    /// `false` — after recording an issue — when it is missing, so callers do
    /// `guard ensureMetallibAvailable() else { return }` and STOP before the
    /// first GPU call. This mirrors `Gemma4DecodeProfileTests`, which returns on
    /// a missing metallib instead of pressing on into a hard crash on the first
    /// MLX kernel dispatch.
    private func ensureMetallibAvailable() -> Bool {
        if LiveInferenceFixtures.ensureMetallibColocated() == nil {
            let msg = "mlx.metallib not found near test bundle or in MLX_METALLIB_PATH/SOURCE; "
                + "run scripts/fetch-metallib.sh debug to install it for local runs"
            Issue.record(Comment(rawValue: msg))
            return false
        }
        return true
    }

    // MARK: - Eviction-and-admission

    /// Continuous-batching invariant: when row 0 finishes mid-batch and
    /// row C is admitted into the vacated slot, row C's tokens must match
    /// a solo run of the same prompt. Exercises `BatchedEngine`'s
    /// auto-admission path.
    @Test(
        "eviction and re-admission: row 0 evicted, row C admitted, deterministic match (Qwen3 0.6B)",
        .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil)
    )
    func evictionAndAdmissionMatchesSolo() async throws {
        guard ensureMetallibAvailable() else { return }

        let modelID = "mlx-community/Qwen3-0.6B-8bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache")
            return
        }

        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir,
            using: LocalTokenizerLoader()
        )

        let promptA = "Hi."
        let promptB = "List three colors briefly."
        let promptC = "What is 2 + 2? Answer with just the number."

        let encoded: (a: [Int], b: [Int], c: [Int]) = try await container.perform { ctx in
            func enc(_ s: String) throws -> [Int] {
                try ctx.tokenizer.applyChatTemplate(
                    messages: [["role": "user", "content": s]],
                    tools: nil,
                    additionalContext: nil
                )
            }
            return (try enc(promptA), try enc(promptB), try enc(promptC))
        }

        let bMaxTokens = 12
        let cMaxTokens = 10
        let aMaxTokens = 2

        let solo = await singleStreamGreedy(
            container: container,
            prompts: [encoded.b, encoded.c],
            maxTokens: max(bMaxTokens, cMaxTokens)
        )
        let bSolo = solo[0]
        let cSolo = solo[1]

        // Drive A + B, submit C the instant A finishes, capture B + C streams.
        let engine = await container.perform { ctx -> BatchedEngine in
            let scheduler = Scheduler(
                model: ctx.model,
                tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: 2,
                    maxNumBatchedTokens: 8192,
                    prefillStepSize: 2048,
                    streamInterval: 1
                ),
                eosTokenIds: ctx.configuration.eosTokenIds,
                prefixCache: nil
            )
            return BatchedEngine(
                scheduler: scheduler,
                tokenizer: ctx.tokenizer,
                modelName: modelID,
                config: ContinuousBatchingConfig(
                    schedulerConfig: scheduler.config,
                    stepInterval: 0.001,
                    prefixCacheConfig: nil,
                    mtpEnabled: false
                ),
                externalChatTemplate: nil
            )
        }
        await engine.start()

        let idA = "evict-A"
        let idB = "evict-B"
        let idC = "evict-C"

        _ = await engine.core.addRequest(Request(
            requestId: idA, prompt: encoded.a as AnyHashable,
            samplingParams: SamplingParams(maxTokens: aMaxTokens, temperature: 0.0)
        ))
        _ = await engine.core.addRequest(Request(
            requestId: idB, prompt: encoded.b as AnyHashable,
            samplingParams: SamplingParams(maxTokens: bMaxTokens, temperature: 0.0)
        ))

        async let bTokensTask: [Int] = {
            var t: [Int] = []
            for await output in engine.core.streamOutputs(requestId: idB) {
                t.append(contentsOf: output.newTokenIds)
                if output.finished || output.error != nil { break }
            }
            return t
        }()

        // Watch A; on finish, submit C and then capture C's tokens.
        let cTokensTask = Task { [engine] () -> [Int] in
            for await output in engine.core.streamOutputs(requestId: idA) {
                if output.finished || output.error != nil { break }
            }
            // A finished — submit C.
            _ = await engine.core.addRequest(Request(
                requestId: idC, prompt: encoded.c as AnyHashable,
                samplingParams: SamplingParams(maxTokens: cMaxTokens, temperature: 0.0)
            ))
            var t: [Int] = []
            for await output in engine.core.streamOutputs(requestId: idC) {
                t.append(contentsOf: output.newTokenIds)
                if output.finished || output.error != nil { break }
            }
            return t
        }
        let bBatch = await bTokensTask
        let cBatch = await cTokensTask.value

        let cMatched = zip(cBatch, cSolo).prefix(while: ==).count
        let cRequired = max(1, min(4, cMaxTokens / 2))
        let cFailMsg = "row C (post-admission): \(cMatched)/\(cBatch.count) match solo "
            + "(batch=\(cBatch), solo=\(cSolo.prefix(cBatch.count)))"
        #expect(cMatched >= cRequired, Comment(rawValue: cFailMsg))

        let bMatched = zip(bBatch, bSolo).prefix(while: ==).count
        let bRequired = max(1, min(4, bMaxTokens / 2))
        let bFailMsg = "row B (across eviction): \(bMatched)/\(bBatch.count) match solo "
            + "(batch=\(bBatch.prefix(bRequired + 2)), solo=\(bSolo.prefix(bRequired + 2)))"
        #expect(bMatched >= bRequired, Comment(rawValue: bFailMsg))

        if cMatched < cBatch.count || bMatched < bBatch.count {
            print(
                "[eviction] B prefix \(bMatched)/\(bBatch.count), "
                    + "C prefix \(cMatched)/\(cBatch.count)"
            )
        }

        // Synchronous teardown so the next test does not race a live
        // engine on the shared `ModelContainer`.
        await engine.stop()
    }

    // MARK: - Resource-count crash probe (diagnostic)

    /// Drives a SUSTAINED high-concurrency, long-generation batched decode on
    /// Gemma-4-26B to characterise the `[metal::malloc] Resource limit (499000)`
    /// crash. Set DARKBLOOM_MLX_RESOURCE_DEBUG=1 to log num_resources_ vs cache
    /// bytes per 50 steps (EngineCore prints them). The byte cache limit is set
    /// HUGE here to mimic the 128 GB prod box (where the byte-trim never fires),
    /// isolating pure count behaviour:
    ///   - count climbs WITH cache bytes  => cached/evictable => a count-aware
    ///     cache trim (the fork fix) prevents the crash.
    ///   - count climbs while cache stays small => the buffers are LIVE in the
    ///     in-flight eval => admission control (cap batch width/tokens) is needed.
    /// Diagnostic, not an assertion test; gated behind the Gemma live flags.
    /// Small-model variant of the resource probe (Qwen3-0.6B). The cached-vs-live
    /// buffer trajectory under continuous batching is model-agnostic — a small
    /// model has fewer layers (lower absolute count) but the SAME per-step
    /// distinct-buffer pattern, so it answers "do the accumulating buffers track
    /// the cache bytes (cached) or not (live)?" without the 26B load. Run locally
    /// with DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_MLX_RESOURCE_DEBUG=1.
    @Test(
        "RESOURCE PROBE (small): batched decode resource-count trajectory (Qwen3-0.6B)",
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_MLX_RESOURCE_DEBUG"] != nil
        )
    )
    func resourceCountTrajectoryProbeSmall() async throws {
        guard ensureMetallibAvailable() else { return }
        // Mimic the big-RAM box: BOTH the cache-size trim (cacheLimit /
        // max_pool_size_) AND the byte-pressure reclaim (memoryLimit, which drives
        // gc_limit_ in MetalAllocator::malloc) must be lifted, or the byte path
        // still frees cached buffers and flattens the count — a false negative for
        // the count-limit bug. A prior live test may have left memoryLimit at
        // 12–16GB via LiveInferenceFixtures.applyMemoryBudget. These are
        // process-global and Swift Testing shares the process, so snapshot and
        // restore both on exit.
        let savedCacheLimit = MLX.Memory.cacheLimit
        let savedMemoryLimit = MLX.Memory.memoryLimit
        defer {
            MLX.Memory.cacheLimit = savedCacheLimit
            MLX.Memory.memoryLimit = savedMemoryLimit
        }
        MLX.Memory.memoryLimit = 80 * 1024 * 1024 * 1024  // byte-pressure reclaim off
        MLX.Memory.cacheLimit = 80 * 1024 * 1024 * 1024  // cache-size trim off (mimic big box)

        let modelID = "mlx-community/Qwen3-0.6B-8bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache")
            return
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())

        // CHURN with VARIED prompt LENGTHS (not one fixed batch). Steady decode
        // keeps the count flat because per-step shapes repeat; the prod crash is
        // long-uptime churn where each new request length introduces new buffer
        // shapes. Build a base token stream and slice DISTINCT lengths per wave.
        let base: [Int] = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": String(
                    repeating: "Explain in detail, step by step, with examples. ", count: 60)]],
                tools: nil, additionalContext: nil)
        }
        print("[rsrc-probe-small] model=\(modelID) base_tokens=\(base.count) "
            + "cacheLimit=80GB resourceLimit=\(MLX.Memory.resourceLimit)")

        // Many WAVES; each wave submits a small concurrent batch whose prompt
        // lengths differ from every other wave (distinct prefill shapes), then
        // drains it. Mimics churn over uptime. EngineCore [rsrc] log shows the
        // count trajectory across waves.
        let waves = 60
        for w in 0..<waves {
            // 4 concurrent requests, each a DISTINCT length this wave.
            let lens = (0..<4).map { 8 + ((w * 7 + $0 * 13) % max(1, base.count - 16)) }
            let prompts = lens.map { Array(base.prefix($0)) }
            _ = try await runBatchedEngine(
                container: container, modelID: modelID, prompts: prompts, maxTokens: 24)
            if w % 10 == 0 || w == waves - 1 {
                let r = MLX.Memory.numResources
                print(String(format: "[rsrc-wave] wave=%d distinct_lens=%@ resources=%d/%d (%.1f%%) cache=%.0fMB",
                             w, "\(lens)", r, MLX.Memory.resourceLimit,
                             Double(r) / Double(MLX.Memory.resourceLimit) * 100,
                             Double(MLX.Memory.cacheMemory) / 1_048_576))
                fflush(stdout)
            }
        }
        print("[rsrc-probe-small] done — does count climb across distinct-shape waves?")
    }

    @Test(
        "RESOURCE PROBE: sustained batched decode resource-count trajectory (Gemma-4-26B)",
        .enabled(
            if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_MLX_RESOURCE_DEBUG"] != nil
        )
    )
    func resourceCountTrajectoryProbe() async throws {
        guard ensureMetallibAvailable() else { return }

        // Mimic the 128 GB box: lift BOTH the cache-size trim (cacheLimit) AND the
        // byte-pressure reclaim (memoryLimit -> gc_limit_ in
        // MetalAllocator::malloc) so neither byte path fires — otherwise a prior
        // live test that left memoryLimit at 12–16GB (via
        // LiveInferenceFixtures.applyMemoryBudget) would let byte pressure free
        // cached buffers and flatten the count, a false negative for the
        // count-limit bug. Both are process-global; restore on exit.
        let savedCacheLimit = MLX.Memory.cacheLimit
        let savedMemoryLimit = MLX.Memory.memoryLimit
        defer {
            MLX.Memory.cacheLimit = savedCacheLimit
            MLX.Memory.memoryLimit = savedMemoryLimit
        }
        MLX.Memory.memoryLimit = 80 * 1024 * 1024 * 1024
        MLX.Memory.cacheLimit = 80 * 1024 * 1024 * 1024

        // Use whichever Gemma-4-26B quant is on disk (box has 4bit; fixture
        // default is 8bit); allow an explicit override for portability.
        let candidates = [
            ProcessInfo.processInfo.environment["DARKBLOOM_PROBE_MODEL"],
            LiveInferenceFixtures.gemmaModelID,
            "mlx-community/gemma-4-26b-a4b-it-4bit",
            "gemma-4-26b",
        ].compactMap { $0 }
        guard let (modelID, modelDir) = candidates.lazy
            .compactMap({ id in ModelScanner.resolveLocalPath(modelID: id).map { (id, $0) } })
            .first
        else {
            Issue.record("no Gemma-4-26B variant in the local cache (tried \(candidates))")
            return
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())

        // A handful of distinct prompts so co-batched rows have different
        // lengths (the realistic continuous-batching shape that grows distinct
        // buffer sizes each step).
        let prompts = [
            "Write a long detailed essay about the history of computing.",
            "Explain quantum mechanics from first principles, at length.",
            "Tell a long story about a lighthouse keeper.",
            "Describe how a CPU executes an instruction, in great detail.",
            "Summarize the plot of a 10-act epic in full.",
            "List and explain 50 algorithms with examples.",
        ]
        let encoded: [[Int]] = try await container.perform { ctx in
            try prompts.map {
                try ctx.tokenizer.applyChatTemplate(
                    messages: [["role": "user", "content": $0]], tools: nil, additionalContext: nil)
            }
        }
        // Many concurrent rows × long generation = many decode steps.
        let concurrency = 16
        let manyPrompts = (0..<concurrency).map { encoded[$0 % encoded.count] }

        print("[rsrc-probe] starting: model=\(modelID) concurrency=\(concurrency) "
            + "cacheLimit=80GB resourceLimit=\(MLX.Memory.resourceLimit)")
        _ = try await runBatchedEngine(
            container: container, modelID: modelID, prompts: manyPrompts, maxTokens: 512)
        print("[rsrc-probe] done: peak resources observed in the [rsrc] step logs above")
    }

    // MARK: - DAR-328 cache-clearing empirical verification

    /// One MLX memory sample (MB for active/cache, raw count for resources).
    private struct MemSample: Sendable {
        let active: Double
        let cache: Double
        let resources: Int
    }
    private func sampleMLXMemory() -> MemSample {
        MemSample(
            active: Double(MLX.Memory.activeMemory) / 1_048_576,
            cache: Double(MLX.Memory.cacheMemory) / 1_048_576,
            resources: MLX.Memory.numResources)
    }

    /// Build a live `BatchedEngine` and KEEP it running (caller must stop it).
    /// `stepInterval` is deliberately exposed so the idle-clear window is
    /// observable from the test thread.
    private func makeLiveEngine(
        container: ModelContainer, modelID: String, stepInterval: Double
    ) async -> BatchedEngine {
        let engine = await container.perform { ctx -> BatchedEngine in
            let scheduler = Scheduler(
                model: ctx.model,
                tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: 4, maxNumBatchedTokens: 8192,
                    prefillStepSize: 2048, streamInterval: 1),
                eosTokenIds: ctx.configuration.eosTokenIds,
                prefixCache: nil)
            return BatchedEngine(
                scheduler: scheduler, tokenizer: ctx.tokenizer, modelName: modelID,
                config: ContinuousBatchingConfig(
                    schedulerConfig: scheduler.config, stepInterval: stepInterval,
                    prefixCacheConfig: nil, mtpEnabled: false),
                externalChatTemplate: nil)
        }
        await engine.start()
        return engine
    }

    /// Shared probe for DAR-328 #22 + the core question: on natural COMPLETION,
    /// the per-request KV row's bytes go to MLX's internal buffer POOL
    /// (cacheMemory rises and STAYS), NOT back to the OS. The pool is returned to
    /// the OS only by the engine's idle-gated `Memory.clearCache()` (EngineCore:
    /// after `deferredClearDelay`=8 idle steps). Both the cache-size trim
    /// (cacheLimit) and the byte-pressure reclaim (memoryLimit→gc_limit_) are
    /// lifted so the ONLY thing that returns the pool to the OS is the idle clear.
    private func runCompletionIdleReclaimProbe(
        container: ModelContainer, modelID: String, label: String, maxTokens: Int
    ) async throws {
        let savedCache = MLX.Memory.cacheLimit
        let savedMem = MLX.Memory.memoryLimit
        defer { MLX.Memory.cacheLimit = savedCache; MLX.Memory.memoryLimit = savedMem }
        MLX.Memory.memoryLimit = 100 * 1024 * 1024 * 1024
        MLX.Memory.cacheLimit = 100 * 1024 * 1024 * 1024

        // 50ms steps → the 8-idle-step clearCache window is ~400ms (comfortably
        // observable from the test thread).
        let stepInterval = 0.05
        let engine = await makeLiveEngine(
            container: container, modelID: modelID, stepInterval: stepInterval)

        let prompt: [Int] = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": String(
                    repeating: "Explain in detail, step by step. ", count: 80)]],
                tools: nil, additionalContext: nil)
        }

        MLX.Memory.clearCache()  // drop load-time transients → clean baseline
        let baseline = sampleMLXMemory()

        let rid = "dar328-complete-\(UUID().uuidString.prefix(6))"
        _ = await engine.core.addRequest(Request(
            requestId: rid, prompt: prompt as AnyHashable,
            samplingParams: SamplingParams(maxTokens: maxTokens, temperature: 0.0)))

        // Sample the INSTANT the request reports finished (idleSteps≈0).
        var atCompletion: MemSample?
        for await out in engine.core.streamOutputs(requestId: rid) {
            if out.finished || out.error != nil { atCompletion = sampleMLXMemory(); break }
        }
        let completion = try #require(atCompletion, "request never finished")

        // Short idle (~2 steps « 8): pool must still be held (NOT cleared on completion).
        try await Task.sleep(nanoseconds: UInt64(2 * stepInterval * 1_000_000_000))
        let shortIdle = sampleMLXMemory()

        // Long idle (~30 steps » 8): the idle-gated clearCache returns the pool to the OS.
        try await Task.sleep(nanoseconds: UInt64(30 * stepInterval * 1_000_000_000))
        let afterIdle = sampleMLXMemory()

        await engine.stop()

        print(String(
            format: "[dar328-#22 %@] baseline cache=%.0fMB | onComplete active=%.0f cache=%.0f res=%d | "
                + "shortIdle cache=%.0f | afterIdleGate active=%.0f cache=%.0f res=%d",
            label, baseline.cache, completion.active, completion.cache, completion.resources,
            shortIdle.cache, afterIdle.active, afterIdle.cache, afterIdle.resources))
        fflush(stdout)

        #expect(completion.cache > baseline.cache + 5)      // freed KV → POOL, not OS
        #expect(shortIdle.cache > completion.cache * 0.5)   // NOT cleared on completion / short idle
        #expect(afterIdle.cache < completion.cache * 0.5)   // idle gate (only) returned pool to OS
    }

    /// Shared probe for DAR-328 #23: cancel/abort does NOT clear the MLX buffer
    /// pool on the hot path. The aborted KV row is filtered out (bytes → pool) but
    /// `Memory.clearCache()` is never called on the cancel path, so `cacheMemory`
    /// stays elevated immediately after abort; the idle gate reclaims it later.
    private func runCancelHotPathProbe(
        container: ModelContainer, modelID: String, label: String
    ) async throws {
        let savedCache = MLX.Memory.cacheLimit
        let savedMem = MLX.Memory.memoryLimit
        defer { MLX.Memory.cacheLimit = savedCache; MLX.Memory.memoryLimit = savedMem }
        MLX.Memory.memoryLimit = 100 * 1024 * 1024 * 1024
        MLX.Memory.cacheLimit = 100 * 1024 * 1024 * 1024

        let stepInterval = 0.05
        let engine = await makeLiveEngine(
            container: container, modelID: modelID, stepInterval: stepInterval)

        let prompt: [Int] = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": String(
                    repeating: "Explain in detail, step by step. ", count: 80)]],
                tools: nil, additionalContext: nil)
        }

        MLX.Memory.clearCache()
        let rid = "dar328-cancel-\(UUID().uuidString.prefix(6))"
        // Long generation budget so the request is firmly mid-decode when we abort.
        // NOTE: we deliberately do NOT attach a `streamOutputs` consumer. Doing so
        // and breaking it early makes the stream's `cleanupRequest`
        // (→ removeFinishedRequest, which drops `requests[rid]`) race the deferred
        // `doAbortRequest`, whose `guard let request = requests[requestId]` then
        // early-returns WITHOUT filtering the batch row — orphaning a still-
        // decoding row. Driving the abort directly (doAbortRequest self-cleans via
        // removeFinishedRequest) isolates the cache behavior under test.
        _ = await engine.core.addRequest(Request(
            requestId: rid, prompt: prompt as AnyHashable,
            samplingParams: SamplingParams(maxTokens: 512, temperature: 0.0)))

        // Let prefill + a few decode steps build a real KV footprint.
        try await Task.sleep(nanoseconds: UInt64(12 * stepInterval * 1_000_000_000))
        let mid = sampleMLXMemory()

        let aborted = engine.core.abortRequest(rid)         // hot-path cancel (sync)
        let afterCancel = sampleMLXMemory()                 // idleSteps≈0, within idle window

        try await Task.sleep(nanoseconds: UInt64(40 * stepInterval * 1_000_000_000))
        let afterIdle = sampleMLXMemory()                   // abort processed → idle gate fired

        await engine.stop()

        print(String(
            format: "[dar328-#23 %@] aborted=%@ | midDecode cache=%.0fMB res=%d | "
                + "afterCancel cache=%.0fMB res=%d | afterIdleGate cache=%.0fMB res=%d",
            label, "\(aborted)", mid.cache, mid.resources,
            afterCancel.cache, afterCancel.resources, afterIdle.cache, afterIdle.resources))
        fflush(stdout)

        #expect(aborted)
        #expect(afterCancel.cache > mid.cache * 0.5)        // cancel did NOT reclaim to OS
        #expect(afterIdle.cache < afterCancel.cache * 0.5)  // only the idle gate did
    }

    // --- Qwen3-0.6B (fast, default live flag) ---

    @Test(
        "DAR-328 #22: completion → MLX pool, OS reclaim ONLY via idle gate (Qwen3-0.6B)",
        .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil)
    )
    func kvReturnedToOSOnlyAfterIdleGate() async throws {
        try ensureMetallibAvailable()
        let modelID = "mlx-community/Qwen3-0.6B-8bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache"); return
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())
        try await runCompletionIdleReclaimProbe(
            container: container, modelID: modelID, label: "qwen3-0.6b", maxTokens: 128)
    }

    @Test(
        "DAR-328 #23: cancel does NOT return the MLX pool to the OS on the hot path (Qwen3-0.6B)",
        .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil)
    )
    func cancelDoesNotClearPoolOnHotPath() async throws {
        try ensureMetallibAvailable()
        let modelID = "mlx-community/Qwen3-0.6B-8bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache"); return
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())
        try await runCancelHotPathProbe(
            container: container, modelID: modelID, label: "qwen3-0.6b")
    }

    // --- PROD model gemma-4-26b-a4b-qat-4bit (checkpoint tier, loaded via VLM
    //     factory because it ships vision_config). Gated by the Gemma live flag. ---

    @Test(
        "DAR-328 #22/#23 on PROD gemma-4-26b-a4b-qat-4bit (checkpoint tier, VLM)",
        .enabled(if:
            ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil
        )
    )
    func cacheBehaviorGemma4QatProd() async throws {
        try ensureMetallibAvailable()
        MLX.Memory.memoryLimit = 100 * 1024 * 1024 * 1024  // headroom for the ~15 GB VLM load
        let modelID = ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA_MODEL"]
            ?? "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache"); return
        }
        // Production loads vision checkpoints through VLMModelFactory.
        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())
        try await runCompletionIdleReclaimProbe(
            container: container, modelID: modelID, label: "gemma4-qat4bit", maxTokens: 48)
        try await runCancelHotPathProbe(
            container: container, modelID: modelID, label: "gemma4-qat4bit")
    }

    // MARK: - Per-stream TPS regression under concurrent load

    /// Regression test for the serial WS outbound bottleneck (PR #475):
    /// per-stream decode TPS must not collapse catastrophically under concurrent
    /// load. Measures solo (B=1) throughput, then fires B=4 concurrent greedy
    /// requests and asserts each stream stays above `alpha * solo` TPS. Without
    /// the streamInterval fix this would show ~1/B of solo due to per-token WS
    /// serialization; with the fix, per-stream TPS should stay within 2x of solo.
    ///
    /// This test exercises the engine path directly (no WS) — it tests the MLX
    /// batching throughput characteristics, not the WS pipeline. A future
    /// integration-level test should cover the full stack.
    @Test(
        "per-stream TPS regression: B=4 per-stream must stay above 40% of B=1 solo",
        .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil)
    )
    func perStreamTPSRegressionB4() async throws {
        guard ensureMetallibAvailable() else { return }

        let modelID = "mlx-community/Qwen3-0.6B-8bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache"); return
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())

        let prompt = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": "Write a short paragraph about the ocean."]],
                tools: nil, additionalContext: nil)
        }

        let decodeTokens = 64

        // Solo (B=1) throughput
        let soloTPS = await timedPerStreamEngine(
            container: container, modelID: modelID,
            prompts: [prompt], decodeTokens: decodeTokens)
        #expect(soloTPS.count == 1)
        let solo = soloTPS[0]
        print("[per-stream-regression] B=1 solo: \(String(format: "%.1f", solo)) tok/s")

        // Concurrent (B=4) per-stream throughput
        let b4Prompts = Array(repeating: prompt, count: 4)
        let b4TPS = await timedPerStreamEngine(
            container: container, modelID: modelID,
            prompts: b4Prompts, decodeTokens: decodeTokens)
        #expect(b4TPS.count == 4)

        let alpha = 0.4  // per-stream should stay above 40% of solo
        for (i, tps) in b4TPS.enumerated() {
            print("[per-stream-regression] B=4 stream \(i): \(String(format: "%.1f", tps)) tok/s")
            #expect(tps >= solo * alpha,
                Comment(rawValue: "stream \(i) TPS \(String(format: "%.1f", tps)) < \(String(format: "%.1f", solo * alpha)) (40% of solo \(String(format: "%.1f", solo)))"))
        }
    }

    /// Measures PER-STREAM (not aggregate) TPS for each concurrent request.
    /// Returns an array of per-stream tok/s values, one per prompt.
    private func timedPerStreamEngine(
        container: ModelContainer,
        modelID: String,
        prompts: [[Int]],
        decodeTokens: Int
    ) async -> [Double] {
        let engine = await container.perform { ctx -> BatchedEngine in
            let scheduler = Scheduler(
                model: ctx.model, tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: max(4, prompts.count), maxNumBatchedTokens: 8192,
                    prefillStepSize: 512, streamInterval: 4),
                eosTokenIds: ctx.configuration.eosTokenIds, prefixCache: nil)
            return BatchedEngine(
                scheduler: scheduler, tokenizer: ctx.tokenizer, modelName: modelID,
                config: ContinuousBatchingConfig(
                    schedulerConfig: scheduler.config, stepInterval: 0.001,
                    prefixCacheConfig: nil, mtpEnabled: false),
                externalChatTemplate: nil)
        }
        await engine.start()

        let results = await withTaskGroup(of: (Int, Double).self) { group -> [Double] in
            for (i, prompt) in prompts.enumerated() {
                let id = "perstream-\(i)-\(UUID().uuidString.prefix(6))"
                group.addTask { [engine] in
                    _ = await engine.core.addRequest(Request(
                        requestId: id, prompt: prompt as AnyHashable,
                        samplingParams: SamplingParams(maxTokens: decodeTokens + 1, temperature: 0.0)))
                    var sawFirst = false; var start = ContinuousClock.now; var produced = 0
                    for await output in engine.core.streamOutputs(requestId: id) {
                        if !sawFirst { sawFirst = true; start = .now }
                        else { produced += output.newTokenIds.count }
                        if output.finished || output.error != nil { break }
                    }
                    return (i, Self.tokensPerSecond(produced, .now - start))
                }
            }
            var r = Array(repeating: 0.0, count: prompts.count)
            for await (idx, tps) in group { r[idx] = tps }
            return r
        }

        // Synchronous stop: a detached teardown would race the next
        // helper invocation against a live engine on the shared
        // ModelContainer.
        await engine.stop()
        return results
    }

    // MARK: - streamInterval text completeness

    /// Regression test for PR #475 P1 review: with streamInterval > 1, the
    /// streaming output must contain ALL decoded text. The original code
    /// called detok.next() on every token (consuming text), then discarded it
    /// via `continue` when shouldSend was false — causing 3/4 of tokens' text
    /// to be silently dropped. The fix defers next() until the emission gate.
    @Test(
        "streamInterval=4: streamed text must match full decoded output",
        .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil)
    )
    func streamIntervalTextCompleteness() async throws {
        guard ensureMetallibAvailable() else { return }

        let modelID = "mlx-community/Qwen3-0.6B-8bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache"); return
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())

        let prompt = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": "Count from 1 to 20."]],
                tools: nil, additionalContext: nil)
        }

        let maxTokens = 40

        // Run with streamInterval=1 (reference)
        let ref = await collectStreamedText(
            container: container, modelID: modelID,
            prompt: prompt, maxTokens: maxTokens, streamInterval: 1)

        // Run with streamInterval=4 (the production value)
        let batched = await collectStreamedText(
            container: container, modelID: modelID,
            prompt: prompt, maxTokens: maxTokens, streamInterval: 4)

        print("[streamInterval] interval=1 text (\(ref.chunks) chunks): \(ref.text.prefix(120))...")
        print("[streamInterval] interval=4 text (\(batched.chunks) chunks): \(batched.text.prefix(120))...")

        // The concatenated streamed text must match exactly
        #expect(ref.text == batched.text,
            Comment(rawValue: "streamInterval=4 text differs from interval=1:\n  ref=\(ref.text.prefix(200))\n  got=\(batched.text.prefix(200))"))

        // interval=4 should produce fewer chunks (roughly 4x fewer)
        #expect(batched.chunks < ref.chunks,
            Comment(rawValue: "interval=4 produced \(batched.chunks) chunks, expected fewer than interval=1's \(ref.chunks)"))
    }

    private struct StreamResult {
        let text: String
        let chunks: Int
    }

    private func collectStreamedText(
        container: ModelContainer,
        modelID: String,
        prompt: [Int],
        maxTokens: Int,
        streamInterval: Int
    ) async -> StreamResult {
        let engine = await container.perform { ctx -> BatchedEngine in
            let scheduler = Scheduler(
                model: ctx.model, tokenizer: ctx.tokenizer,
                config: SchedulerConfig(
                    maxNumSeqs: 1, maxNumBatchedTokens: 8192,
                    prefillStepSize: 512, streamInterval: streamInterval),
                eosTokenIds: ctx.configuration.eosTokenIds, prefixCache: nil)
            return BatchedEngine(
                scheduler: scheduler, tokenizer: ctx.tokenizer, modelName: modelID,
                config: ContinuousBatchingConfig(
                    schedulerConfig: scheduler.config, stepInterval: 0.001,
                    prefixCacheConfig: nil, mtpEnabled: false),
                externalChatTemplate: nil)
        }
        await engine.start()

        let id = "stream-interval-\(streamInterval)-\(UUID().uuidString.prefix(6))"
        _ = await engine.core.addRequest(Request(
            requestId: id, prompt: prompt as AnyHashable,
            samplingParams: SamplingParams(maxTokens: maxTokens, temperature: 0.0)))

        var text = ""
        var chunks = 0
        for await output in engine.core.streamOutputs(requestId: id) {
            if !output.newText.isEmpty {
                text += output.newText
                chunks += 1
            }
            if output.finished || output.error != nil { break }
        }

        await engine.stop()
        return StreamResult(text: text, chunks: chunks)
    }

    // --- PROD model gpt-oss-20b (8-bit / MXFP4-Q8, checkpoint tier, LLM factory).
    //     Gated by a dedicated flag. ---

    @Test(
        "DAR-328 #22/#23 on PROD gpt-oss-20b-8bit (checkpoint tier)",
        .enabled(if:
            ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GPTOSS"] != nil
        )
    )
    func cacheBehaviorGptOss20bProd() async throws {
        try ensureMetallibAvailable()
        MLX.Memory.memoryLimit = 100 * 1024 * 1024 * 1024  // headroom for the ~11 GB load
        let modelID = ProcessInfo.processInfo.environment["DARKBLOOM_GPTOSS_MODEL"]
            ?? "mlx-community/gpt-oss-20b-MXFP4-Q8"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache"); return
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())
        try await runCompletionIdleReclaimProbe(
            container: container, modelID: modelID, label: "gpt-oss-20b", maxTokens: 48)
        try await runCancelHotPathProbe(
            container: container, modelID: modelID, label: "gpt-oss-20b")
    }
}
