// End-to-end performance tests for the Swift provider.
//
// Goal: produce reproducible TTFT (time-to-first-token) and throughput
// numbers that mirror what a coordinator-driven request actually pays
// for in production. Five scenarios, each implemented as a parameterised
// helper and run against two models:
//
//   A) Warm + plaintext  -- pure inference TTFT (baseline)
//   B) Cold (model load) -- load_time + warm_TTFT
//   C) Warm + encrypted  -- encrypt + decrypt + warm_TTFT (full E2E)
//   D) Warm + batched    -- 1, 2, 4 concurrent requests, per-row TTFT
//                           and aggregate throughput
//   E) Decode-tps bracket -- pure model loop vs BatchGenerator vs
//                           BatchScheduler at B=1, max_tokens=64.
//                           Localizes any per-token cost overhead.
//
//   Qwen3 0.6B-8bit             -- smoke-tier (DARKBLOOM_LIVE_MLX_TESTS=1)
//   Gemma 4 26B-A4B-it-8bit MoE -- production-tier (DARKBLOOM_LIVE_MLX_GEMMA=1)
//
// Numbers print to stderr in a `[perf]` prefix so they're easy to grep
// out of CI logs.
//
// Reference points: mlx_lm 0.31.3 Python on the same hardware. Reproduce
// with `scripts/mlx_lm_batch_bench.py`.
//
//   Qwen3 0.6B-8bit              B=1: 265 tok/s   B=2: 694 tok/s   B=4: 1119 tok/s
//   Gemma 4 26B-A4B-it-8bit MoE  B=1:  74 tok/s   B=2: 126 tok/s   B=4:  181 tok/s
//
// Swift release-mode direct BatchGenerator numbers (decode-only, after
// the greedy fast-path fixes: nil samplers for greedy rows, UInt32 token
// tensors, no logSumExp on greedy, and mlx_lm-style double-buffering):
//
//   Qwen3 0.6B-8bit              B=1: ~400 tok/s  B=4: ~890 tok/s
//   Gemma 4 26B-A4B-it-8bit MoE  B=1:  ~80 tok/s  B=4: ~186 tok/s
//
// This is effectively at parity with mlx_lm for Gemma B=4. If a
// production streaming test is slower, this file prints separate
// `model-side scheduler` and public aggregate numbers so we can tell
// model decode from text streaming / AsyncStream / detokenization costs.
// Always compare against release-mode Swift (`swift test -c release`);
// debug-mode Swift is several times slower and is not a valid mlx_lm
// comparison.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("performance: end-to-end TTFT", .serialized)
struct PerformanceLiveTests {

    // MARK: - Configuration

    /// Static configuration for one performance scenario. Captures the
    /// model ID, the wired-memory budget MLX should target, and the
    /// number of warm-iteration samples to collect (Gemma uses fewer
    /// iterations because each load is ~30 s of disk I/O).
    private struct ModelConfig: Sendable {
        let label: String
        let modelID: String
        let wiredMemoryGB: Int
        let warmIterations: Int
        let coldIterations: Int
        let batchSizes: [Int]
        let maxTokens: Int
    }

    private static let qwen = ModelConfig(
        label: "Qwen3 0.6B-8bit",
        modelID: "mlx-community/Qwen3-0.6B-8bit",
        wiredMemoryGB: 8,
        warmIterations: 3,
        coldIterations: 2,
        batchSizes: [1, 2, 4],
        maxTokens: 16
    )

    private static let gemma = ModelConfig(
        label: "Gemma 4 26B-A4B-it-8bit (MoE)",
        modelID: "mlx-community/gemma-4-26b-a4b-it-8bit",
        wiredMemoryGB: 64,
        warmIterations: 2,
        coldIterations: 1,
        batchSizes: [1, 2, 4],
        // 32 tokens lets steady-state decode dominate over prefill in
        // the aggregate throughput print (prefill is ~250 ms; 32 decode
        // steps at ~25 ms each is ~800 ms).
        maxTokens: 32
    )

    /// Short prompt for TTFT measurements (encryption, cold load): a
    /// model that emits EOS quickly is fine here because we only care
    /// about first-token timing.
    private let ttftPromptText = "Reply with the single word 'hi'."

    /// Long-output prompt for throughput measurements: explicitly asks
    /// for a long response so decode runs to `max_tokens` and the
    /// reported tok/s reflects steady-state, not a few amortised
    /// post-EOS tokens.
    private let throughputPromptText =
        "Tell me a 200-word story about a robot that learns to paint. "
        + "Be detailed and descriptive throughout."

    private func ttftRequest(for config: ModelConfig) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: config.modelID,
            messages: [ChatMessage(role: "user", content: ttftPromptText)],
            temperature: 0.0,
            max_tokens: config.maxTokens
        )
    }

    private func throughputRequest(for config: ModelConfig) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: config.modelID,
            messages: [ChatMessage(role: "user", content: throughputPromptText)],
            temperature: 0.0,
            max_tokens: config.maxTokens
        )
    }

    private static var liveEnabled: Bool { LiveInferenceFixtures.liveTestsEnabled }
    private static var gemmaEnabled: Bool { LiveInferenceFixtures.gemmaTestsEnabled }

    // ====================================================================
    // MARK: - Qwen3 0.6B (smoke tier; DARKBLOOM_LIVE_MLX_TESTS=1)
    // ====================================================================

    @Test("warm TTFT baseline (Qwen3 0.6B)", .enabled(if: liveEnabled))
    func qwenWarmTTFT() async throws { try await runWarmTTFT(Self.qwen) }

    @Test("cold TTFT (Qwen3 0.6B)", .enabled(if: liveEnabled))
    func qwenColdTTFT() async throws { try await runColdTTFT(Self.qwen) }

    @Test("encrypted TTFT (Qwen3 0.6B)", .enabled(if: liveEnabled))
    func qwenEncryptedTTFT() async throws { try await runEncryptedTTFT(Self.qwen) }

    @Test("batched TTFT + throughput (Qwen3 0.6B)", .enabled(if: liveEnabled))
    func qwenBatchedTTFT() async throws { try await runBatchedTTFT(Self.qwen) }

    // ====================================================================
    // MARK: - Gemma 4 26B-A4B-it-8bit MoE (production tier;
    //         DARKBLOOM_LIVE_MLX_TESTS=1 + DARKBLOOM_LIVE_MLX_GEMMA=1)
    // ====================================================================

    @Test("warm TTFT baseline (Gemma 26B MoE)", .enabled(if: gemmaEnabled))
    func gemmaWarmTTFT() async throws { try await runWarmTTFT(Self.gemma) }

    @Test("cold TTFT (Gemma 26B MoE)", .enabled(if: gemmaEnabled))
    func gemmaColdTTFT() async throws { try await runColdTTFT(Self.gemma) }

    @Test("encrypted TTFT (Gemma 26B MoE)", .enabled(if: gemmaEnabled))
    func gemmaEncryptedTTFT() async throws { try await runEncryptedTTFT(Self.gemma) }

    @Test("batched TTFT + throughput (Gemma 26B MoE)", .enabled(if: gemmaEnabled))
    func gemmaBatchedTTFT() async throws { try await runBatchedTTFT(Self.gemma) }

    /// Bracket test: pure model loop vs BatchGenerator vs BatchScheduler,
    /// all at B=1, max_tokens=64 so decode dominates over prefill. Tells
    /// us where the per-token cost is going (forward pass vs scheduler
    /// overhead vs actor hops).
    @Test("decode-tps bracket: pure / generator / scheduler (Qwen3 0.6B)",
          .enabled(if: liveEnabled))
    func qwenDecodeTPSBracket() async throws {
        try await runDecodeTPSBracket(Self.qwen, decodeTokens: 64)
    }

    @Test("decode-tps bracket: pure / generator / scheduler (Gemma 26B MoE)",
          .enabled(if: gemmaEnabled))
    func gemmaDecodeTPSBracket() async throws {
        try await runDecodeTPSBracket(Self.gemma, decodeTokens: 64)
    }

    // ====================================================================
    // MARK: - Scenario implementations (parameterised by ModelConfig)
    // ====================================================================

    /// A) Warm baseline -- pure inference TTFT, no encryption, model already loaded.
    private func runWarmTTFT(_ config: ModelConfig) async throws {
        let loaded = try await loadOrSkip(config)
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }

        // Warm-up pass: the very first generation pays JIT/Metal setup
        // costs that have nothing to do with the steady-state TTFT.
        _ = await timeFirstToken(scheduler: scheduler, request: ttftRequest(for: config))

        var samples: [Duration] = []
        for _ in 0 ..< config.warmIterations {
            samples.append(
                await timeFirstToken(scheduler: scheduler, request: ttftRequest(for: config))
            )
        }
        Self.printRow("\(config.label): warm TTFT", samples: samples, median: median(samples))
        #expect(median(samples) > .zero)
    }

    /// B) Cold -- fresh ModelContainer per iteration so weights are
    /// re-paged from disk. Reports load-only and load+first-token.
    private func runColdTTFT(_ config: ModelConfig) async throws {
        try ensureModelOrSkip(config)
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: config.modelID) else {
            Issue.record("model not in cache")
            return
        }

        var loadSamples: [Duration] = []
        var totalSamples: [Duration] = []

        for _ in 0 ..< config.coldIterations {
            applyMemoryBudget(gigabytes: config.wiredMemoryGB)
            let totalStart = ContinuousClock.now

            let loadStart = ContinuousClock.now
            let container = try await LLMModelFactory.shared.loadContainer(
                from: modelDir,
                using: LocalTokenizerLoader()
            )
            let scheduler = BatchScheduler(
                maxConcurrentRequests: 4,
                pendingTimeout: .seconds(120),
                defaultMaxTokens: 64
            )
            await scheduler.loadModel(container: container, modelId: config.modelID)
            let loadElapsed = ContinuousClock.now - loadStart

            _ = await timeFirstToken(scheduler: scheduler, request: ttftRequest(for: config))
            let totalElapsed = ContinuousClock.now - totalStart

            loadSamples.append(loadElapsed)
            totalSamples.append(totalElapsed)
            await scheduler.unloadModel()
        }

        Self.printRow("\(config.label): cold load",         samples: loadSamples,  median: median(loadSamples))
        Self.printRow("\(config.label): cold load + first", samples: totalSamples, median: median(totalSamples))
        #expect(median(loadSamples) > .zero)
        #expect(median(totalSamples) > median(loadSamples))
    }

    /// C) Encrypted -- full E2E pipeline including NaCl box round-trip.
    private func runEncryptedTTFT(_ config: ModelConfig) async throws {
        let loaded = try await loadOrSkip(config)
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }

        let providerKeys = NodeKeyPair.generate()
        let consumerKeys = NodeKeyPair.generate()
        let providerPubKeyData = Data(base64Encoded: providerKeys.publicKeyBase64)!
        let consumerPubKeyData = Data(base64Encoded: consumerKeys.publicKeyBase64)!

        // Warm-up.
        _ = await timeFirstToken(scheduler: scheduler, request: ttftRequest(for: config))

        var encryptSamples: [Duration] = []
        var decryptSamples: [Duration] = []
        var ttftSamples: [Duration] = []
        var e2eFirstTokenSamples: [Duration] = []

        for _ in 0 ..< config.warmIterations {
            let payload = try JSONEncoder().encode(ttftRequest(for: config))

            let encStart = ContinuousClock.now
            let ciphertext = try consumerKeys.encrypt(
                recipientPublicKey: providerPubKeyData,
                plaintext: payload
            )
            let encElapsed = ContinuousClock.now - encStart

            let decStart = ContinuousClock.now
            let decrypted = try providerKeys.decrypt(
                senderPublicKey: consumerPubKeyData,
                ciphertext: ciphertext
            )
            let decElapsed = ContinuousClock.now - decStart

            #expect(decrypted == payload, "encrypt/decrypt round-trip must preserve bytes")

            let parsedRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: decrypted)
            let ttft = await timeFirstToken(scheduler: scheduler, request: parsedRequest)

            encryptSamples.append(encElapsed)
            decryptSamples.append(decElapsed)
            ttftSamples.append(ttft)
            e2eFirstTokenSamples.append(encElapsed + decElapsed + ttft)
        }

        Self.printRow("\(config.label): encrypt",                  samples: encryptSamples,        median: median(encryptSamples))
        Self.printRow("\(config.label): decrypt",                  samples: decryptSamples,        median: median(decryptSamples))
        Self.printRow("\(config.label): warm TTFT",                samples: ttftSamples,           median: median(ttftSamples))
        Self.printRow("\(config.label): E2E first-token",          samples: e2eFirstTokenSamples,  median: median(e2eFirstTokenSamples))
        #expect(median(encryptSamples) > .zero)
        #expect(median(decryptSamples) > .zero)
    }

    /// D) Batched -- B=1, B=2, B=4 concurrent submissions on a single
    /// shared scheduler. Reports per-row TTFT and aggregate throughput
    /// (the headline continuous-batching metric).
    private func runBatchedTTFT(_ config: ModelConfig) async throws {
        let loaded = try await LiveInferenceFixtures.loadScheduler(
            modelID: config.modelID,
            maxConcurrentRequests: 4,
            memoryBudgetBytes: config.wiredMemoryGB * 1024 * 1024 * 1024
        )
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }

        // Warm-up with the same long-output prompt so JIT/Metal kernel
        // compile costs are paid before the timed run.
        _ = await timeFirstToken(scheduler: scheduler, request: throughputRequest(for: config))

        for batchSize in config.batchSizes {
            let result = await measureBatch(
                scheduler: scheduler,
                batchSize: batchSize,
                request: throughputRequest(for: config)
            )
            Self.printRow(
                "\(config.label): B=\(batchSize) per-row TTFT (prefill+1)",
                samples: result.ttft,
                median: median(result.ttft)
            )

            let totalSeconds = Double(result.totalElapsed.components.seconds)
                + Double(result.totalElapsed.components.attoseconds) / 1e18
            let aggregateTPS = totalSeconds > 0
                ? Double(result.totalCompletionTokens) / totalSeconds : 0

            // Steady-state decode TPS: prefill (everything up to the
            // first token across all rows) is dominated by the MAX
            // per-row TTFT. Subtract it from the wall-clock so we
            // report decode-only throughput. This is the number that
            // compares apples-to-apples with mlx_lm's "Generation:
            // X tokens-per-sec" headline.
            let prefillSeconds: Double = {
                guard let maxTTFT = result.ttft.max() else { return 0 }
                let s = Double(maxTTFT.components.seconds)
                    + Double(maxTTFT.components.attoseconds) / 1e18
                return s
            }()
            let decodeSeconds = max(totalSeconds - prefillSeconds, 0.0001)
            let decodeTokens = max(result.totalCompletionTokens - batchSize, 0)
            let decodeTPS = Double(decodeTokens) / decodeSeconds
            let modelSideAggregateTPS = result.modelSideTPS.reduce(0, +)

            FileHandle.standardError.write(Data("""
            [perf] \(config.label): B=\(batchSize) aggregate throughput  \(String(format: "%.1f", aggregateTPS)) tok/s (incl. prefill)
            [perf] \(config.label): B=\(batchSize) steady-state decode   \(String(format: "%.1f", decodeTPS)) tok/s (\(decodeTokens) tokens after prefill)
            [perf] \(config.label): B=\(batchSize) model-side scheduler  \(String(format: "%.1f", modelSideAggregateTPS)) tok/s (before detokenization)

            """.utf8))
            #expect(result.ttft.allSatisfy { $0 > .zero })
        }
    }

    /// Decode-throughput bracket. Tokenizes a fixed prompt and runs the
    /// same `decodeTokens`-token decode through three paths to localize
    /// where time goes:
    ///
    ///   1. Pure model loop      -- `model.callAsFunction` directly,
    ///                              greedy argMax, no BatchGenerator.
    ///   2. BatchGenerator only  -- exercises the batched-cache path
    ///                              but bypasses the scheduler actor.
    ///   3. BatchScheduler.submit -- the production path (actor +
    ///                              detached worker + AsyncStream).
    ///
    /// All three excluded the prefill cost (we time the steady-state
    /// decode portion only). If (1) ~= mlx_lm but (2) or (3) is slower,
    /// the cost is in our wrappers.
    private func runDecodeTPSBracket(_ config: ModelConfig, decodeTokens: Int) async throws {
        try ensureModelOrSkip(config)
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: config.modelID) else {
            Issue.record("model not in cache")
            return
        }

        applyMemoryBudget(gigabytes: config.wiredMemoryGB)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: modelDir,
            using: LocalTokenizerLoader()
        )

        // Tokenize once. Use the throughput prompt so the model
        // generates `decodeTokens` tokens before EOS.
        let promptTokens: [Int] = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": self.throughputPromptText]],
                tools: nil,
                additionalContext: nil
            )
        }

        // Path 1a: pure single-stream loop with SYNCHRONOUS eval per
        // token. Matches what GenerationBatch.step() and the existing
        // singleStreamGreedy helper do.
        let pureSyncDecodeTPS = await container.perform { ctx in
            let cache = ctx.model.newCache(parameters: nil)
            let promptArr = MLXArray(promptTokens.map { UInt32($0) })
                .reshaped([1, promptTokens.count])

            var logits = ctx.model.callAsFunction(promptArr, cache: cache)
            logits = logits[.ellipsis, -1, 0...]
            var nextToken = argMax(logits, axis: -1)
            eval(nextToken)

            let start = ContinuousClock.now
            for _ in 0 ..< decodeTokens {
                let stepArr = nextToken[0..., .newAxis]
                logits = ctx.model.callAsFunction(stepArr, cache: cache)
                logits = logits[.ellipsis, -1, 0...]
                nextToken = argMax(logits, axis: -1)
                eval(nextToken)
            }
            let elapsed = ContinuousClock.now - start
            return Self.tokensPerSecond(decodeTokens, elapsed)
        }

        // Path 1b: pure single-stream loop with ASYNC-EVAL pipelining
        // (the mlx_lm Python pattern). Dispatch the next forward
        // speculatively while the current token's value copies back to
        // the CPU, so the GPU stays saturated.
        let pureAsyncDecodeTPS = await container.perform { ctx in
            let cache = ctx.model.newCache(parameters: nil)
            let promptArr = MLXArray(promptTokens.map { UInt32($0) })
                .reshaped([1, promptTokens.count])

            var logits = ctx.model.callAsFunction(promptArr, cache: cache)
            logits = logits[.ellipsis, -1, 0...]
            var current = argMax(logits, axis: -1)
            asyncEval(current)

            let start = ContinuousClock.now
            for _ in 0 ..< decodeTokens {
                // Speculatively dispatch the *next* forward before we
                // read the current token. Both ops run on the GPU
                // command queue concurrently with the asArray copy.
                let stepArr = current[0..., .newAxis]
                logits = ctx.model.callAsFunction(stepArr, cache: cache)
                logits = logits[.ellipsis, -1, 0...]
                let next = argMax(logits, axis: -1)
                asyncEval(next)
                // Force sync of the *previous* iteration's token. By
                // the time this returns, the next forward is already
                // partway through.
                _ = current.asArray(UInt32.self)[0]
                current = next
            }
            let elapsed = ContinuousClock.now - start
            return Self.tokensPerSecond(decodeTokens, elapsed)
        }

        // Path 1c: pure loop with the decode step wrapped in
        // mlx-swift's `compile`, matching the optimisation mlx_lm Python
        // applies in its hot decode path.
        let pureCompiledDecodeTPS = await container.perform { ctx in
            let cache = ctx.model.newCache(parameters: nil)
            let promptArr = MLXArray(promptTokens.map { UInt32($0) })
                .reshaped([1, promptTokens.count])

            var logits = ctx.model.callAsFunction(promptArr, cache: cache)
            logits = logits[.ellipsis, -1, 0...]
            var current = argMax(logits, axis: -1)
            eval(current)

            let compiledStep = compile { (tokens: MLXArray) -> MLXArray in
                let inputs = tokens[0..., .newAxis]
                let logits = ctx.model.callAsFunction(inputs, cache: cache)
                let stepLogits = logits[.ellipsis, -1, 0...]
                let logprobs = stepLogits - logSumExp(stepLogits, axis: -1, keepDims: true)
                return argMax(logprobs, axis: -1)
            }

            // First call pays tracing / compile cost; do not time it.
            current = compiledStep(current)
            eval(current)

            let start = ContinuousClock.now
            for _ in 0 ..< decodeTokens {
                current = compiledStep(current)
                eval(current)
            }
            let elapsed = ContinuousClock.now - start
            return Self.tokensPerSecond(decodeTokens, elapsed)
        }

        // Path 2: BatchGenerator at B=1 (bypasses BatchScheduler).
        let generatorTPS = await container.perform { ctx in
            let gen = BatchGenerator(
                model: ctx.model,
                eosTokens: [],
                defaultMaxTokens: decodeTokens + 1,
                prefillStepSize: 2048,
                prefillBatchSize: 1,
                completionBatchSize: 1
            )
            _ = gen.insert(prompts: [promptTokens])
            // Drain the first token (prefill cost — NOT timed).
            _ = gen.next()
            let start = ContinuousClock.now
            var produced = 0
            while gen.hasWork, produced < decodeTokens {
                let responses = gen.next()
                produced += responses.count
            }
            let elapsed = ContinuousClock.now - start
            gen.close()
            return Self.tokensPerSecond(produced, elapsed)
        }

        let generatorBatchedTPS: [(Int, Double)] = await container.perform { ctx in
            [2, 4].map { batchSize in
                let gen = BatchGenerator(
                    model: ctx.model,
                    eosTokens: [],
                    defaultMaxTokens: decodeTokens + 1,
                    prefillStepSize: 2048,
                    prefillBatchSize: batchSize,
                    completionBatchSize: batchSize
                )
                _ = gen.insert(prompts: Array(repeating: promptTokens, count: batchSize))
                _ = gen.next() // prefill / first token outside timed region
                let start = ContinuousClock.now
                var produced = 0
                let target = decodeTokens * batchSize
                while gen.hasWork, produced < target {
                    produced += gen.next().count
                }
                let elapsed = ContinuousClock.now - start
                gen.close()
                return (batchSize, Self.tokensPerSecond(produced, elapsed))
            }
        }

        // Path 3: BatchScheduler.submit (production path). Use
        // max_tokens=decodeTokens+1 so we can drop the first token's
        // prefill cost from the steady-state measurement.
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            pendingTimeout: .seconds(60),
            defaultMaxTokens: decodeTokens + 1
        )
        await scheduler.loadModel(container: container, modelId: config.modelID)
        let req = ChatCompletionRequest(
            model: config.modelID,
            messages: [ChatMessage(role: "user", content: throughputPromptText)],
            temperature: 0.0,
            max_tokens: decodeTokens + 1
        )
        let stream = await scheduler.submit(request: req)
        var firstChunkAt: ContinuousClock.Instant?
        var lastChunkAt: ContinuousClock.Instant?
        var completionTokens = 0
        var schedulerTPS = 0.0
        for await event in stream {
            switch event {
            case .chunk:
                if firstChunkAt == nil { firstChunkAt = .now }
                lastChunkAt = .now
            case .info(_, let completion, let tps):
                completionTokens = completion
                schedulerTPS = tps
            case .error:
                break
            }
        }
        if let first = firstChunkAt, let last = lastChunkAt, completionTokens > 1 {
            schedulerTPS = Self.tokensPerSecond(completionTokens - 1, last - first)
        }
        await scheduler.unloadModel()

        FileHandle.standardError.write(Data("""
        [perf] \(config.label): decode (pure loop, sync eval)         \(String(format: "%.1f", pureSyncDecodeTPS)) tok/s
        [perf] \(config.label): decode (pure loop, async eval)        \(String(format: "%.1f", pureAsyncDecodeTPS)) tok/s
        [perf] \(config.label): decode (pure loop, compile)           \(String(format: "%.1f", pureCompiledDecodeTPS)) tok/s
        [perf] \(config.label): decode (BatchGenerator B=1)           \(String(format: "%.1f", generatorTPS)) tok/s
        [perf] \(config.label): decode (BatchGenerator B=2)           \(String(format: "%.1f", generatorBatchedTPS[0].1)) tok/s
        [perf] \(config.label): decode (BatchGenerator B=4)           \(String(format: "%.1f", generatorBatchedTPS[1].1)) tok/s
        [perf] \(config.label): decode (BatchScheduler.submit)        \(String(format: "%.1f", schedulerTPS)) tok/s

        """.utf8))

        #expect(pureSyncDecodeTPS > 0)
        #expect(pureAsyncDecodeTPS > 0)
        #expect(pureCompiledDecodeTPS > 0)
        #expect(generatorTPS > 0)
        #expect(schedulerTPS > 0)
    }

    private static func tokensPerSecond(_ tokens: Int, _ duration: Duration) -> Double {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return seconds > 0 ? Double(tokens) / seconds : 0
    }

    // MARK: - Helpers

    private func loadOrSkip(_ config: ModelConfig) async throws -> (
        scheduler: BatchScheduler,
        container: ModelContainer,
        modelDirectory: URL
    ) {
        applyMemoryBudget(gigabytes: config.wiredMemoryGB)
        do {
            return try await LiveInferenceFixtures.loadScheduler(
                modelID: config.modelID,
                memoryBudgetBytes: config.wiredMemoryGB * 1024 * 1024 * 1024
            )
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipped: \(skip.description)")
            throw skip
        }
    }

    private func ensureModelOrSkip(_ config: ModelConfig) throws {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            Issue.record("metallib not found; run scripts/fetch-metallib.sh debug")
            return
        }
        guard ModelScanner.resolveLocalPath(modelID: config.modelID) != nil else {
            Issue.record("model '\(config.modelID)' not in cache")
            return
        }
    }

    private func applyMemoryBudget(gigabytes: Int) {
        MLX.GPU.set(memoryLimit: gigabytes * 1024 * 1024 * 1024)
    }

    /// Submit `request` to `scheduler`, measure wall-clock from
    /// submit() to the first `.chunk`, then drain the rest so the
    /// scheduler's row count returns to zero before the next iteration.
    private func timeFirstToken(
        scheduler: BatchScheduler,
        request: ChatCompletionRequest
    ) async -> Duration {
        let start = ContinuousClock.now
        let stream = await scheduler.submit(request: request)
        var ttft: Duration = .zero
        var sawFirst = false
        for await event in stream {
            switch event {
            case .chunk:
                if !sawFirst {
                    ttft = ContinuousClock.now - start
                    sawFirst = true
                }
            case .info, .error:
                break
            }
        }
        return ttft
    }

    private struct BatchResult: Sendable {
        let ttft: [Duration]
        let totalCompletionTokens: Int
        let totalElapsed: Duration
        let modelSideTPS: [Double]
    }

    private func measureBatch(
        scheduler: BatchScheduler,
        batchSize: Int,
        request: ChatCompletionRequest
    ) async -> BatchResult {
        let start = ContinuousClock.now
        struct RowResult: Sendable {
            let ttft: Duration
            let completionTokens: Int
            let modelSideTPS: Double
        }
        let rows: [RowResult] = await withTaskGroup(of: RowResult.self) { group in
            for _ in 0 ..< batchSize {
                group.addTask {
                    let stream = await scheduler.submit(request: request)
                    var ttft: Duration = .zero
                    var completionTokens = 0
                    var modelSideTPS = 0.0
                    var sawFirst = false
                    for await event in stream {
                        switch event {
                        case .chunk:
                            if !sawFirst {
                                ttft = ContinuousClock.now - start
                                sawFirst = true
                            }
                        case .info(_, let completion, _):
                            completionTokens = completion
                            if case .info(_, _, let tps) = event {
                                modelSideTPS = tps
                            }
                        case .error:
                            break
                        }
                    }
                    return RowResult(
                        ttft: ttft,
                        completionTokens: completionTokens,
                        modelSideTPS: modelSideTPS
                    )
                }
            }
            var collected: [RowResult] = []
            for await row in group { collected.append(row) }
            return collected
        }
        let totalElapsed = ContinuousClock.now - start
        return BatchResult(
            ttft: rows.map(\.ttft),
            totalCompletionTokens: rows.reduce(0) { $0 + $1.completionTokens },
            totalElapsed: totalElapsed,
            modelSideTPS: rows.map(\.modelSideTPS)
        )
    }

    private func median(_ xs: [Duration]) -> Duration {
        guard !xs.isEmpty else { return .zero }
        return xs.sorted()[xs.count / 2]
    }

    // MARK: - Reporting

    private static func printRow(_ name: String, samples: [Duration], median: Duration) {
        let label = name.padding(toLength: 56, withPad: " ", startingAt: 0)
        let cells = samples.map { format($0) }.joined(separator: ", ")
        let line = "[perf] \(label)  median=\(format(median))  samples=[\(cells)]"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func format(_ duration: Duration) -> String {
        let nanos = Double(duration.components.attoseconds) / 1e9
            + Double(duration.components.seconds) * 1e9
        let ms = nanos / 1_000_000.0
        if ms < 10 {
            return String(format: "%.2f ms", ms)
        }
        if ms < 1000 {
            return String(format: "%.1f ms", ms)
        }
        return String(format: "%.2f s", ms / 1000.0)
    }
}
