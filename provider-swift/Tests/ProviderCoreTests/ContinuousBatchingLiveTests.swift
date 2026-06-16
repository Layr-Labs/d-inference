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
        try ensureMetallibAvailable()
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
        try ensureMetallibAvailable()

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
        try ensureMetallibAvailable()
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
    private func ensureMetallibAvailable() throws {
        if LiveInferenceFixtures.ensureMetallibColocated() == nil {
            let msg = "mlx.metallib not found near test bundle or in MLX_METALLIB_PATH/SOURCE; "
                + "run scripts/fetch-metallib.sh debug to install it for local runs"
            Issue.record(Comment(rawValue: msg))
        }
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
        try ensureMetallibAvailable()

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
        try ensureMetallibAvailable()
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
        try ensureMetallibAvailable()

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
}
