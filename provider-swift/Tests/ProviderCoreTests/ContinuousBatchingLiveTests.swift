import Foundation
import Testing
import MLX
import MLXLLM
import MLXLMCommon
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
}
