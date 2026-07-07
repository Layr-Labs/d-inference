// Copyright © 2026 Eigen Labs.
//
// LIVE (weight-gated) validation of the v0.7.5 v2 prefix cache on the two
// production model families, through the provider's own construction path
// (`EngineV2Factory.makeProductionEngine(prefixCache:)` + `EngineV2Bridge`,
// exactly as the slot factory wires them):
//
//   (a) EXACTNESS — a multi-turn conversation whose turn 2 shares turn 1's
//       full prompt prefix must produce BYTE-IDENTICAL greedy turn-2 output
//       with the cache enabled vs disabled (two engine constructions over
//       the same weights). For gemma-4 this exercises the hybrid
//       sliding-window `requiredRecompute` path: the engine adopts only
//       matched − windowCount×maxWindow tokens and re-prefills the rest
//       through ALL layers.
//   (b) HIT ACCOUNTING — the cached turn-2 run reports
//       `prefixCacheHitTokens > 0` (read through the provider's new
//       out-of-band `EngineV2RequestUsageSignal`), with a lower bound
//       derived from the shared-prefix block count and the model's own
//       layer kinds.
//   (c) BATCH INVARIANCE — a cached row + a cold row submitted TOGETHER
//       produce the same outputs as each run separately (the cold row's
//       reference comes from the cache-off engine, so it is a true miss on
//       both sides).
//
// TTFT deltas are recorded to the test log (informational — cache-warm vs
// cache-off turn-2).
//
// Sizing note (why the prompts are long): a hit only pays off past the
// recompute bound windowCount × maxWindow — gpt-oss-20b: 12 × 128 = 1,536
// tokens; gemma-4-26B (25 sliding × 1024 window): 25,600 tokens — so each
// model's turn-1 prefix is grown past its own bound (derived from
// `cbv2LayerKinds`, never hardcoded). The gemma case prefills ~26k-token
// prompts several times and takes minutes; it rides the existing
// DARKBLOOM_LIVE_MLX_GEMMA opt-in.
//
// Funding-gate framing: because gemma's bound dwarfs real prompt lengths,
// PRODUCTION does not fund its cache at all (PrefixCachePolicy.shouldFund,
// default threshold 4,096) — the gemma test first pins that unfunded
// default verdict, then runs the funded scenario explicitly as the
// operator override (DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS)
// so the hybrid-window recompute exactness stays exercised on real
// weights. gpt-oss (bound 1,536) is the funded-by-default case.
//
// Gates: DARKBLOOM_LIVE_MLX_TESTS (+ DARKBLOOM_LIVE_MLX_GPTOSS for gpt-oss,
// DARKBLOOM_LIVE_MLX_GEMMA for gemma); each checkpoint skips cleanly when
// not in the local HF cache.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing

@testable import ProviderCore

@Suite("EngineV2 prefix cache (live)", .serialized)
struct EngineV2PrefixCacheLiveTests {

    static let gptossModelID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    static let gemmaQatModelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"

    private static let gib = 1_073_741_824

    // MARK: - Loaded-model harness

    /// `@unchecked Sendable`: the module reference is handed to ONE engine
    /// at a time (which serializes forward passes on its step thread) and
    /// the batch-invariance `async let` pair only reads the value-type
    /// fields — the same ownership story as `EngineV2ModelSnapshot`.
    private struct LiveModel: @unchecked Sendable {
        let modelID: String
        /// Retained so the weights stay resident for the test's lifetime.
        let container: ModelContainer
        let model: any LanguageModel
        let tokenizer: TokenizerHandle
        let eosTokenIds: Set<Int>
        let layerKinds: [CBv2LayerKind]
    }

    /// The engine's recompute bound for full-history prefix adoption:
    /// windowCount × maxWindow (see `cbv2RequiredRecompute`). A hit is only
    /// effective past this many matched tokens.
    private func recomputeBound(_ kinds: [CBv2LayerKind]) -> Int {
        var maxWindow = 0
        var windowCount = 0
        for kind in kinds {
            if case .slidingWindow(let window) = kind.attention {
                maxWindow = max(maxWindow, window)
                windowCount += 1
            }
        }
        return windowCount * maxWindow
    }

    private func loadGptOss() async throws -> LiveModel {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(Self.gptossModelID) else {
            throw LiveFixtureSkip.modelNotInCache(Self.gptossModelID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 48 * Self.gib)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        let snapshot = await container.perform { ctx in
            EngineV2ModelSnapshot(
                model: ctx.model,
                eosTokenIds: ctx.configuration.eosTokenIds,
                extraEOSTokens: ctx.configuration.extraEOSTokens.sorted())
        }
        let tokenizer: TokenizerHandle = await container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }
        let gptoss = try #require(
            snapshot.model as? GPTOSSModel, "gpt-oss checkpoint must load as GPTOSSModel")
        // Same EOS augmentation the slot factory applies (Harmony stops).
        let eos = BatchScheduler.effectiveEOSTokenIds(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            base: snapshot.eosTokenIds,
            tokenToId: { tokenizer.inner.convertTokenToId($0) })
        return LiveModel(
            modelID: "gpt-oss-20b",
            container: container,
            model: gptoss,
            tokenizer: tokenizer,
            eosTokenIds: eos,
            layerKinds: gptoss.cbv2LayerKinds)
    }

    private func loadGemmaQat() async throws -> LiveModel {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(Self.gemmaQatModelID)
        else {
            throw LiveFixtureSkip.modelNotInCache(Self.gemmaQatModelID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: 64 * Self.gib)
        // Prod gemma-4 checkpoints are VLM builds: load through the VLM
        // factory and extract the CBv2-adapted text model over the SAME
        // weight arrays — the identical path the slot factory takes.
        let container = try await VLMModelFactory.shared.loadContainer(
            from: directory, using: LocalTokenizerLoader())
        let snapshot = await container.perform { ctx in
            EngineV2ModelSnapshot(
                model: ctx.model,
                eosTokenIds: ctx.configuration.eosTokenIds,
                extraEOSTokens: ctx.configuration.extraEOSTokens.sorted())
        }
        let tokenizer: TokenizerHandle = await container.perform { ctx in
            TokenizerHandle(ctx.tokenizer)
        }
        let extraction = try EngineV2VLMTextExtraction.extractTextModel(
            from: snapshot.model, modelDirectory: directory)
        return LiveModel(
            modelID: "gemma-4-26b-qat-4bit",
            container: container,
            model: extraction.model,
            tokenizer: tokenizer,
            eosTokenIds: snapshot.eosTokenIds,
            layerKinds: extraction.model.cbv2LayerKinds)
    }

    // MARK: - Engine/bridge construction (the production seam)

    private func makeBridge(
        _ live: LiveModel, cache: PrefixCacheV2?
    ) throws -> EngineV2Bridge {
        let engine = try EngineV2Factory.makeProductionEngine(
            model: live.model,
            tokenizer: live.tokenizer.inner,
            kvBytesCapacity: 24 * Self.gib,
            prefixCache: cache)
        return EngineV2Bridge(
            engine: engine,
            modelId: live.modelID,
            tokenizer: live.tokenizer,
            eosTokenIds: live.eosTokenIds,
            prefixCacheBudgetBytes: cache?.config.maxBytes ?? 0)
    }

    // MARK: - Conversation building

    /// Deterministic, token-dense filler so turn-1 crosses `minTokens` under
    /// the model's chat template — WITHOUT overshooting (the first cut
    /// assumed ≥ 8 tokens/line and overshot gemma's ~26.4k target to 104k
    /// tokens, blowing the engine's 120s per-request deadline). Probe a
    /// small batch to measure tokens/line, extrapolate, then top up by the
    /// measured deficit — converges within ~2% of the target.
    private func turn1UserText(minTokens: Int, tokenize: ([ChatMessage]) throws -> [Int])
        rethrows -> String
    {
        func line(_ index: Int) -> String {
            "Log entry \(index): sensor channel \(index % 17) reported value "
                + "\(index * 37 % 1000) at tick \(index * 13). Summarize later."
        }
        func render(_ count: Int) -> String {
            "Here is a maintenance log to remember for later questions.\n"
                + (1 ... count).map(line).joined(separator: "\n")
                + "\nAcknowledge that you memorized the log."
        }
        func tokenCount(_ count: Int) throws -> Int {
            try tokenize([ChatMessage(role: "user", content: render(count))]).count
        }
        // Probe: 64 lines → per-line token rate (template overhead is inside
        // the probe measurement, so the extrapolation is a safe floor).
        let probeLines = 64
        let probeTokens = try tokenCount(probeLines)
        let perLine = max(1.0, Double(probeTokens) / Double(probeLines))
        var lines = max(probeLines, Int(Double(minTokens) / perLine) + 1)
        // Top up by the measured deficit until the target is crossed
        // (converges in 1–2 rounds; small slack, never a multiple).
        for _ in 0 ..< 8 {
            let tokens = try tokenCount(lines)
            if tokens >= minTokens { return render(lines) }
            let deficit = minTokens - tokens
            lines += max(8, Int(Double(deficit) / perLine * 1.02) + 1)
        }
        return render(lines)
    }

    private struct Conversation {
        let turn1Tokens: [Int]
        let turn2Tokens: [Int]
        /// Tokens the two turns share (turn 2 extends turn 1's full prompt).
        let sharedPrefixTokens: Int
    }

    /// Turn 2 = turn 1 + a FIXED assistant reply + a follow-up question, so
    /// the conversation is genuinely multi-turn, deterministic, and turn 2's
    /// rendering starts with turn 1's full prompt (the chat templates render
    /// history prefix-stably within a process).
    private func buildConversation(_ live: LiveModel, minTurn1Tokens: Int) throws -> Conversation {
        let tokenize: ([ChatMessage]) throws -> [Int] = { messages in
            try live.tokenizer.inner.applyChatTemplate(
                messages: messages.map { ["role": $0.role, "content": $0.content] },
                tools: nil, additionalContext: nil)
        }
        let userText = try turn1UserText(minTokens: minTurn1Tokens, tokenize: tokenize)
        let turn1: [ChatMessage] = [ChatMessage(role: "user", content: userText)]
        let turn2: [ChatMessage] = turn1 + [
            ChatMessage(role: "assistant", content: "Acknowledged. I memorized the log."),
            ChatMessage(role: "user", content: "How many log entries were there? Reply briefly."),
        ]
        let t1 = try tokenize(turn1)
        let t2 = try tokenize(turn2)
        var shared = 0
        while shared < min(t1.count, t2.count), t1[shared] == t2[shared] { shared += 1 }
        return Conversation(turn1Tokens: t1, turn2Tokens: t2, sharedPrefixTokens: shared)
    }

    // MARK: - Turn driver

    private struct TurnResult {
        let text: String
        let ttft: Duration
        let prefixCacheHitTokens: Int
    }

    /// One greedy turn through the bridge (the production submit seam),
    /// reading the hit count through the new usage signal.
    private func runTurn(
        bridge: EngineV2Bridge,
        live: LiveModel,
        promptTokens: [Int],
        maxTokens: Int,
        requestId: String
    ) async throws -> TurnResult {
        let signal = EngineV2RequestUsageSignal()
        let request = ChatCompletionRequest(
            model: live.modelID,
            messages: [ChatMessage(role: "user", content: "unused — pre-tokenized")],
            temperature: 0,
            max_tokens: maxTokens)
        let started = ContinuousClock.now
        var firstChunkAt: ContinuousClock.Instant?
        var text = ""
        var streamError: String?
        let stream = await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: requestId,
            usageSignal: signal)
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                if firstChunkAt == nil { firstChunkAt = .now }
                text += chunk
            case .info:
                break
            case .error(let message):
                streamError = message
            }
        }
        if let streamError {
            Issue.record("[\(requestId)] stream error: \(streamError)")
        }
        return TurnResult(
            text: text,
            ttft: (firstChunkAt ?? .now) - started,
            prefixCacheHitTokens: signal.prefixCacheHitTokens ?? 0)
    }

    /// Donation runs off-thread after a finish — wait for the cache to index
    /// the turn-1 prefix before submitting turn 2 (upstream test pattern).
    private func waitForDonation(_ cache: PrefixCacheV2, timeout: Duration = .seconds(60)) async
        -> Bool
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if cache.stats().entryCount >= 1 { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return cache.stats().entryCount >= 1
    }

    // MARK: - Shared scenario

    private func runPrefixCacheScenario(_ live: LiveModel, maxTokens: Int) async throws {
        let bound = recomputeBound(live.layerKinds)
        let blockSize = PrefixCachePolicy.blockSize
        // Turn-1 prefix comfortably past the recompute bound: enough whole
        // blocks that matched − recompute stays > 0 with margin.
        let minTurn1 = bound + 3 * blockSize
        let conversation = try buildConversation(live, minTurn1Tokens: minTurn1)
        // The shared prefix must clear the recompute bound in whole blocks —
        // it may fall a few tokens short of turn 1's FULL render (the
        // template ends turn 1 with a generation-prompt suffix that the
        // history rendering replaces), and that is fine: the chain match
        // works in whole blocks of the shared span.
        #expect(conversation.sharedPrefixTokens >= minTurn1,
            "turn 2 must share at least the sized turn-1 prefix")
        // The engine indexes whole blocks of the donated turn-1 sequence;
        // matched covers at least the shared prefix's whole blocks, so the
        // effective hit has this floor.
        let expectedMinHit = (conversation.sharedPrefixTokens / blockSize) * blockSize - bound
        #expect(expectedMinHit > 0, "conversation sizing failed to clear the recompute bound")
        print(
            "[prefix-live] \(live.modelID): turn1=\(conversation.turn1Tokens.count) tok, "
                + "turn2=\(conversation.turn2Tokens.count) tok, "
                + "shared=\(conversation.sharedPrefixTokens) tok, recomputeBound=\(bound), "
                + "expectedMinHit=\(expectedMinHit)")

        // ---- Cache-ON engine (production construction, funded cache).
        let cache = try #require(
            PrefixCachePolicy.makePrefixCache(modelId: live.modelID, budgetBytes: 8 * Self.gib))
        let cacheOn = try makeBridge(live, cache: cache)

        // Turn 1: a genuine miss that seeds the cache on finish.
        let turn1 = try await runTurn(
            bridge: cacheOn, live: live, promptTokens: conversation.turn1Tokens,
            maxTokens: maxTokens, requestId: "t1-on")
        #expect(!turn1.text.isEmpty, "turn 1 produced no content")
        #expect(turn1.prefixCacheHitTokens == 0, "first-ever submission cannot hit")
        #expect(await waitForDonation(cache), "turn-1 finish never donated its prefix")

        // Turn 2 solo on the warm cache: the (b) assertion.
        let turn2Warm = try await runTurn(
            bridge: cacheOn, live: live, promptTokens: conversation.turn2Tokens,
            maxTokens: maxTokens, requestId: "t2-on")
        #expect(!turn2Warm.text.isEmpty, "turn 2 (cached) produced no content")
        #expect(
            turn2Warm.prefixCacheHitTokens >= expectedMinHit,
            Comment(
                rawValue: "cached turn 2 reported \(turn2Warm.prefixCacheHitTokens) hit tokens "
                    + "(expected ≥ \(expectedMinHit))"))

        // (c) batch invariance: the cached row + a COLD row submitted
        // together. The cold prompt is first seen here on this engine.
        let coldTokens = try live.tokenizer.inner.applyChatTemplate(
            messages: [[
                "role": "user",
                "content": "Name three prime numbers below twenty, comma separated.",
            ]],
            tools: nil, additionalContext: nil)
        async let batchedTurn2Task = runTurn(
            bridge: cacheOn, live: live, promptTokens: conversation.turn2Tokens,
            maxTokens: maxTokens, requestId: "t2-batch")
        async let batchedColdTask = runTurn(
            bridge: cacheOn, live: live, promptTokens: coldTokens,
            maxTokens: maxTokens, requestId: "cold-batch")
        let batchedTurn2 = try await batchedTurn2Task
        let batchedCold = try await batchedColdTask
        await cacheOn.shutdown()

        // ---- Cache-OFF engine (second construction, same weights).
        let cacheOff = try makeBridge(live, cache: nil)
        let turn2Off = try await runTurn(
            bridge: cacheOff, live: live, promptTokens: conversation.turn2Tokens,
            maxTokens: maxTokens, requestId: "t2-off")
        let coldSolo = try await runTurn(
            bridge: cacheOff, live: live, promptTokens: coldTokens,
            maxTokens: maxTokens, requestId: "cold-solo")
        await cacheOff.shutdown()

        // (a) exactness: cache-adopted greedy output byte-identical to the
        // cache-off run — including the hybrid-window recompute path.
        #expect(turn2Off.prefixCacheHitTokens == 0, "cache-off engine cannot hit")
        #expect(
            turn2Warm.text == turn2Off.text,
            Comment(
                rawValue: "cached turn-2 output diverged from cache-off: "
                    + "on=\(turn2Warm.text.debugDescription) "
                    + "off=\(turn2Off.text.debugDescription)"))

        // (c) batch invariance vs the solo runs.
        #expect(
            batchedTurn2.text == turn2Warm.text,
            Comment(
                rawValue: "cached row diverged when batched with a cold row: "
                    + "batch=\(batchedTurn2.text.debugDescription) "
                    + "solo=\(turn2Warm.text.debugDescription)"))
        #expect(batchedTurn2.prefixCacheHitTokens >= expectedMinHit,
            "the batched cached row must still hit")
        #expect(
            batchedCold.text == coldSolo.text,
            Comment(
                rawValue: "cold row diverged when batched with a cached row: "
                    + "batch=\(batchedCold.text.debugDescription) "
                    + "solo=\(coldSolo.text.debugDescription)"))

        // Informational TTFT delta (cache-warm vs cache-off turn 2).
        let stats = cache.stats()
        print(
            "[prefix-live] \(live.modelID): turn2 TTFT warm=\(turn2Warm.ttft) "
                + "off=\(turn2Off.ttft) (Δ=\(turn2Off.ttft - turn2Warm.ttft)); "
                + "hitTokens solo=\(turn2Warm.prefixCacheHitTokens) "
                + "batch=\(batchedTurn2.prefixCacheHitTokens); "
                + "cache stats: hits=\(stats.hits) misses=\(stats.misses) "
                + "tokensSaved=\(stats.tokensSaved) entries=\(stats.entryCount) "
                + "bytes=\(stats.bytesInUse)")

        MLX.Memory.clearCache()
    }

    // MARK: - Tests

    @Test(
        "gpt-oss-20b: funded by default; turn-2 exactness, hit accounting, batch invariance",
        .enabled(if:
            LiveInferenceFixtures.liveTestsEnabled
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GPTOSS"] != nil)
    )
    func gptOssPrefixCache() async throws {
        let live = try await loadGptOss()
        // Funding gate on the REAL checkpoint's layer kinds: gpt-oss's
        // adoption bound (12 × 128 = 1,536) is under the 4,096 default, so
        // production funds its cache. The scenario below is therefore the
        // default-env path for this model.
        let bound = PrefixCachePolicy.adoptionBoundTokens(layerKinds: live.layerKinds)
        #expect(bound == 1536, "gpt-oss-20b adoption bound drifted: \(bound)")
        #expect(PrefixCachePolicy.shouldFund(adoptionBoundTokens: bound, environment: [:]),
            "gpt-oss must fund at the default threshold")
        try await runPrefixCacheScenario(live, maxTokens: 24)
    }

    @Test(
        "gemma-4-26b-qat-4bit: UNFUNDED by default (adoption bound); funded+hybrid-recompute path via override",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func gemmaQatPrefixCache() async throws {
        let live = try await loadGemmaQat()

        // DEFAULT-ENV verdict on the REAL checkpoint's layer kinds: the
        // adoption bound (25 sliding × 1024 = 25,600) dwarfs real prompt
        // lengths, so production does NOT fund gemma's cache — the full
        // grant stays with live KV. Pin the whole unfunded composition the
        // slot factory executes: gate verdict → zero requested budget →
        // carve passthrough → no cache instance (the slot-factory plumbing
        // itself — raw grant to the engine, zero bridge budget, no stats
        // logger — is pinned in EngineV2PrefixCacheWiringTests).
        let bound = PrefixCachePolicy.adoptionBoundTokens(layerKinds: live.layerKinds)
        #expect(bound == 25600, "gemma-4-qat adoption bound drifted: \(bound)")
        #expect(!PrefixCachePolicy.shouldFund(adoptionBoundTokens: bound, environment: [:]),
            "gemma-4 must NOT fund at the default threshold")
        let unfundedCarve = PrefixCachePolicy.carve(
            slotKVBytesCapacity: 24 * Self.gib,
            requestedBudgetBytes: 0,  // gate said no
            kvBytesPerToken: 4096)
        #expect(unfundedCarve.engineKVBytesCapacity == 24 * Self.gib,
            "unfunded gemma must keep its full grant for live KV")
        #expect(unfundedCarve.prefixCacheBudgetBytes == 0)
        #expect(PrefixCachePolicy.makePrefixCache(modelId: live.modelID, budgetBytes: 0) == nil)

        // The config.json-only derivation the slot factory uses for VLM
        // slots must agree with the loaded model's own layer kinds.
        if case .found(let directory) = LiveInferenceFixtures.locate(Self.gemmaQatModelID) {
            #expect(
                EngineV2VLMTextExtraction.adoptionBoundTokens(modelDirectory: directory) == bound,
                "config-only adoption bound diverged from the loaded model's")
        }

        // FUNDED path under the operator override
        // (DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS=26000): keeps
        // the hybrid-window requiredRecompute exactness + hit accounting +
        // batch invariance exercised on real gemma weights.
        let overrideEnv = ["DARKBLOOM_PREFIX_CACHE_MAX_ADOPTION_BOUND_TOKENS": "26000"]
        #expect(PrefixCachePolicy.shouldFund(
            adoptionBoundTokens: bound, environment: overrideEnv),
            "the override must make gemma fundable for this scenario")
        try await runPrefixCacheScenario(live, maxTokens: 16)
    }
}
