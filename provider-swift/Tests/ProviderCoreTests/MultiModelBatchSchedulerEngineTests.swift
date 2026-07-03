import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

// Unit tests for the `MLXServerEngine` adapter that bridges the
// multi-model `BatchScheduler` registry to the upstream MLXLMServer
// runtime. We can't easily construct a real `BatchScheduler` without
// loading a model, so these tests focus on the dispatch + translation
// + lifecycle hooks that don't require a live engine. End-to-end
// generation is covered by the live test suites.

@Test("availableModels reports the registry keys sorted")
func multiModelEngineReportsRegistry() async throws {
    let engine = MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in [:] }
    )
    let models = try await engine.availableModels()
    #expect(models.isEmpty)
}

@Test("availableModels returns sorted ids")
func multiModelEngineReturnsSortedIDs() async throws {
    // We can't construct a real BatchScheduler synchronously, so we
    // can't put real entries into the registry. Verify the empty path
    // first; the sort property is documented and tested via end-to-end
    // live tests where real schedulers are present.
    let engine = MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in [:] }
    )
    let models = try await engine.availableModels()
    #expect(models.map(\.id) == [])
}

@Test("streamChatCompletion calls ensureLoaded before lookup")
func multiModelEngineCallsEnsureLoadedBeforeRegistryLookup() async throws {
    let ensureCounter = Counter()
    let engine = MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in [:] },
        ensureLoaded: { @Sendable _ in
            await ensureCounter.increment()
        }
    )

    let request = OpenAIChatCompletionRequest(
        model: "mlx-test",
        messages: [.init(role: .user, content: .text("hi"))]
    )

    do {
        _ = try await engine.streamChatCompletion(request: request)
        Issue.record("expected modelNotLoaded throw")
    } catch let error as MultiModelBatchSchedulerEngineError {
        #expect(error == .modelNotLoaded("mlx-test"))
    }

    #expect(await ensureCounter.value == 1)
}

@Test("streamChatCompletion throws modelNotLoaded when registry has no entry")
func multiModelEngineDispatchThrowsForMissingModel() async throws {
    let engine = MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in [:] }
    )

    let request = OpenAIChatCompletionRequest(
        model: "missing/model",
        messages: [.init(role: .user, content: .text("hello"))]
    )

    do {
        _ = try await engine.streamChatCompletion(request: request)
        Issue.record("expected throw")
    } catch let error as MultiModelBatchSchedulerEngineError {
        #expect(error == .modelNotLoaded("missing/model"))
    }
}

@Test("tokenize without a loaded model throws")
func multiModelEngineTokenizeWithoutModelThrows() async throws {
    let engine = MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in [:] }
    )
    do {
        _ = try await engine.tokenize(TokenizeRequest(prompt: "hello"))
        Issue.record("expected throw")
    } catch let error as MultiModelBatchSchedulerEngineError {
        #expect(error == .noModelLoadedForTokenization)
    }
}

@Test("translate maps OpenAI fields onto the legacy ChatCompletionRequest")
func multiModelEngineTranslatesRequestFields() {
    let request = OpenAIChatCompletionRequest(
        model: "mlx-community/Qwen3-0.6B",
        messages: [
            .init(role: .system, content: .text("Be terse.")),
            .init(role: .user, content: .text("Hello")),
        ],
        stream: true,
        temperature: 0.2,
        topP: 0.9,
        topK: 50,
        maxTokens: 64,
        presencePenalty: 0.1,
        frequencyPenalty: 0.2,
        repetitionPenalty: 1.05,
        stop: ["<|endoftext|>", "<|im_end|>"]
    )

    let translated = MultiModelBatchSchedulerEngine.translate(
        openAIRequest: request,
        defaultMaxTokens: 4096
    )

    #expect(translated.model == "mlx-community/Qwen3-0.6B")
    #expect(translated.messages.count == 2)
    #expect(translated.messages[0].role == "system")
    #expect(translated.messages[0].content == "Be terse.")
    #expect(translated.messages[1].role == "user")
    #expect(translated.messages[1].content == "Hello")
    #expect(translated.temperature == 0.2)
    #expect(translated.top_p == 0.9)
    #expect(translated.top_k == 50)
    #expect(translated.max_tokens == 64)
    #expect(translated.presence_penalty == 0.1)
    #expect(translated.frequency_penalty == 0.2)
    #expect(translated.repetition_penalty == 1.05)
    #expect(translated.stream == true)
    #expect(translated.stop?.asArray == ["<|endoftext|>", "<|im_end|>"])
}

@Test("translate collapses empty stop sequences to nil")
func multiModelEngineTranslateDropsEmptyStop() {
    let request = OpenAIChatCompletionRequest(
        model: "any",
        messages: [.init(role: .user, content: .text("hi"))],
        stop: []
    )
    let translated = MultiModelBatchSchedulerEngine.translate(
        openAIRequest: request,
        defaultMaxTokens: 4096
    )
    #expect(translated.stop == nil)
}

// P1 #3 deviation guard (narrowed): the upstream request type carries
// neither `seed` nor `logit_bias`, so a translation WITHOUT the sealed-body
// overlay yields nil for both. If a future upstream PR adds the fields,
// plumb them through `translate` directly and retire the overlay. Until
// then this fixture pins the bare-translation behaviour so the deviation
// stays visible.
@Test("translate without an overlay yields nil seed/logit_bias (upstream shape omits them)")
func multiModelEngineTranslateDropsSeed() {
    let request = OpenAIChatCompletionRequest(
        model: "any",
        messages: [.init(role: .user, content: .text("hi"))]
    )
    let translated = MultiModelBatchSchedulerEngine.translate(
        openAIRequest: request,
        defaultMaxTokens: 4096
    )
    #expect(translated.seed == nil,
        "the upstream OpenAIChatCompletionRequest exposes no seed field; without the sealed-body overlay the adapter must yield nil")
    #expect(translated.logit_bias == nil)
}

// Coordinator-path recovery for the same two fields: the inference handler
// decodes them from the sealed body (`extractSamplingOverrides`) and
// overlays them here, so the v2 engine sees the caller's real values.
@Test("translate overlays sealed-body logit_bias and seed onto the internal shape")
func multiModelEngineTranslateOverlaysSamplingFields() {
    let request = OpenAIChatCompletionRequest(
        model: "any",
        messages: [.init(role: .user, content: .text("hi"))]
    )
    let translated = MultiModelBatchSchedulerEngine.translate(
        openAIRequest: request,
        defaultMaxTokens: 4096,
        logitBias: ["50256": -100],
        seed: 1234
    )
    #expect(translated.logit_bias == ["50256": -100])
    #expect(translated.seed == 1234)
    // The overlay feeds EngineV2Translation verbatim: the parsed bias and
    // seed land in the CBv2 sampling params.
    let sampling = EngineV2Translation.samplingParams(from: translated)
    #expect(sampling.logitBias == [50256: -100])
    #expect(sampling.seed == 1234)
}

// MARK: - Scheduler error mapping (P2 #6)
//
// Pins the `MultiModelBatchSchedulerEngineError.fromSchedulerMessage`
// translator that converts `BatchScheduler` `.error(message)` payloads
// into typed errors so `ProviderLoop.mapInferenceErrorToStatus` can
// return 429/503 instead of collapsing every admission failure into
// 500. The string prefixes here MUST stay in sync with the messages
// emitted by `BatchScheduler.submit` and the planner.

@Test("fromSchedulerMessage maps 'queue full' to .queueFull (429)")
func fromSchedulerMessageMapsQueueFull() {
    let err = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
        "token_budget_exhausted: request queue full"
    )
    if case .queueFull(let msg) = err {
        #expect(msg.contains("queue full"))
    } else {
        Issue.record("expected .queueFull, got \(err)")
    }
    #expect(ProviderLoop.mapInferenceErrorToStatus(err) == 429)
}

@Test("fromSchedulerMessage maps token_budget_exhausted (active budget) to .tokenBudgetExhausted (503)")
func fromSchedulerMessageMapsActiveTokenBudget() {
    let err = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
        "token_budget_exhausted: request exceeds active token budget"
    )
    if case .tokenBudgetExhausted = err {
        // OK
    } else {
        Issue.record("expected .tokenBudgetExhausted, got \(err)")
    }
    #expect(ProviderLoop.mapInferenceErrorToStatus(err) == 503)
}

@Test("fromSchedulerMessage maps insufficient KV cache headroom to .tokenBudgetExhausted (503)")
func fromSchedulerMessageMapsKVHeadroom() {
    let err = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
        "token_budget_exhausted: insufficient global KV cache headroom"
    )
    if case .tokenBudgetExhausted = err {
        // OK
    } else {
        Issue.record("expected .tokenBudgetExhausted, got \(err)")
    }
    #expect(ProviderLoop.mapInferenceErrorToStatus(err) == 503)
}

@Test("fromSchedulerMessage maps capacity-timeout to .tokenBudgetExhausted (503)")
func fromSchedulerMessageMapsCapacityTimeout() {
    let err = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
        "request timed out waiting for capacity"
    )
    if case .tokenBudgetExhausted = err {
        // OK
    } else {
        Issue.record("expected .tokenBudgetExhausted, got \(err)")
    }
    #expect(ProviderLoop.mapInferenceErrorToStatus(err) == 503)
}

@Test("fromSchedulerMessage falls through to .generationFailed for unknown messages (500)")
func fromSchedulerMessageFallsThroughToGenerationFailed() {
    let err = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
        "request stream closed by engine teardown"
    )
    if case .generationFailed(let msg) = err {
        #expect(msg == "request stream closed by engine teardown",
            "verbatim message preserved for operator debugging")
    } else {
        Issue.record("expected .generationFailed, got \(err)")
    }
    #expect(ProviderLoop.mapInferenceErrorToStatus(err) == 500)
}

@Test("invalidRole maps to 400 (P2 #5)")
func invalidRoleMapsToBadRequest() {
    let err = MultiModelBatchSchedulerEngineError.invalidRole("developer")
    #expect(ProviderLoop.mapInferenceErrorToStatus(err) == 400)
}

@Test("invalidToolPayload maps to 400")
func invalidToolPayloadMapsToBadRequest() {
    let err = MultiModelBatchSchedulerEngineError.invalidToolPayload(
        "tool message has no preceding assistant tool_calls")
    #expect(ProviderLoop.mapInferenceErrorToStatus(err) == 400)
}

@Test("GPT-OSS Harmony EOS includes return and call tokens")
func gptOssHarmonyEOSIncludesCallAndReturnTokens() {
    let ids = BatchScheduler.effectiveEOSTokenIds(
        modelId: "mlx-community/gpt-oss-20b-MXFP4-Q8",
        base: []
    ) { token in
        switch token {
        case "<|return|>": return 200002
        case "<|endoftext|>": return 199999
        case "<|call|>": return 200012
        default: return nil
        }
    }

    #expect(ids == [199999, 200002, 200012])
}

@Test("Harmony EOS can be detected from model_type for aliased GPT-OSS models")
func harmonyEOSUsesModelTypeForAliasedModels() {
    let ids = BatchScheduler.effectiveEOSTokenIds(
        modelId: "local-alias",
        modelType: "gpt_oss",
        base: []
    ) { token in
        switch token {
        case "<|return|>": return 200002
        case "<|endoftext|>": return 199999
        case "<|call|>": return 200012
        default: return nil
        }
    }

    #expect(ids == [199999, 200002, 200012])
}

@Test("non-Harmony EOS set is unchanged")
func nonHarmonyEOSIsUnchanged() {
    let ids = BatchScheduler.effectiveEOSTokenIds(
        modelId: "mlx-community/Qwen3-0.6B",
        base: [151645]
    ) { _ in 200012 }

    #expect(ids == [151645])
}

// MARK: - defaultReasoningParser(for:) (Part 3: deepseek_v4 auto-split seam)
//
// `MLXServerEngine.defaultReasoningParser(for:)` is the seam that lets
// `MLXOpenAIService` auto-select a reasoning parser from the resolved
// model's `model_type` when the request didn't specify one — see
// `libs/mlx-swift-lm`'s `MLXServerEngine`/`MLXOpenAIService`. These tests
// pin that `MultiModelBatchSchedulerEngine` wires it correctly for BOTH
// engine construction modes (registryProvider snapshot vs. the atomic
// `acquire` init's `modelTypeProvider`), and that it never forces a load.

@Test("defaultReasoningParser resolves deepseek_v4's model_type via the registryProvider snapshot")
func defaultReasoningParserResolvesDeepseekV4ViaRegistryProvider() async {
    let engine = MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in
            ["dsv4-flash": .init(
                scheduler: BatchScheduler(), tokenizer: TokenizerHandle(StubTokenizer()),
                modelType: "deepseek_v4")]
        }
    )
    let format = await engine.defaultReasoningParser(for: "dsv4-flash")
    #expect(format == ProviderLoop.inferReasoningParser(for: "deepseek_v4"))
}

@Test("defaultReasoningParser resolves a non-DeepSeek model_type without changing its behavior")
func defaultReasoningParserResolvesNonDeepseekModelType() async {
    let engine = MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in
            ["gemma": .init(
                scheduler: BatchScheduler(), tokenizer: TokenizerHandle(StubTokenizer()),
                modelType: "gemma3")]
        }
    )
    let format = await engine.defaultReasoningParser(for: "gemma")
    #expect(format == ProviderLoop.inferReasoningParser(for: "gemma3"))
    #expect(format != ProviderLoop.inferReasoningParser(for: "deepseek_v4"),
        "a non-DeepSeek model must resolve to a different default than deepseek_v4")
}

@Test("defaultReasoningParser resolves via modelTypeProvider on the atomic-acquire init")
func defaultReasoningParserResolvesViaModelTypeProviderForAtomicAcquireEngine() async {
    let engine = MultiModelBatchSchedulerEngine(
        acquire: { modelId in
            MultiModelBatchSchedulerEngine.AcquiredModel(
                scheduler: BatchScheduler(),
                tokenizer: TokenizerHandle(StubTokenizer()),
                releaseToken: OneShotRelease(release: { _ in }, modelId: modelId),
                modelType: "deepseek_v4")
        },
        tokenizerProvider: { _ in TokenizerHandle(StubTokenizer()) },
        availableModels: { ["dsv4-flash"] },
        modelTypeProvider: { _ in "deepseek_v4" }
    )
    let format = await engine.defaultReasoningParser(for: "dsv4-flash")
    #expect(format == ProviderLoop.inferReasoningParser(for: "deepseek_v4"))
}

@Test("defaultReasoningParser returns nil for the atomic-acquire init without a modelTypeProvider")
func defaultReasoningParserReturnsNilWithoutModelTypeProvider() async {
    // Mirrors the protocol's documented default: an engine with no
    // per-model opinion returns nil, and `MLXOpenAIService` falls back to
    // its own service-wide default / `.none` -- existing (pre-Part-3)
    // behavior for any caller that doesn't wire `modelTypeProvider`.
    let engine = MultiModelBatchSchedulerEngine(
        acquire: { modelId in
            MultiModelBatchSchedulerEngine.AcquiredModel(
                scheduler: BatchScheduler(),
                tokenizer: TokenizerHandle(StubTokenizer()),
                releaseToken: OneShotRelease(release: { _ in }, modelId: modelId),
                modelType: "deepseek_v4")
        },
        tokenizerProvider: { _ in TokenizerHandle(StubTokenizer()) },
        availableModels: { ["dsv4-flash"] }
    )
    let format = await engine.defaultReasoningParser(for: "dsv4-flash")
    #expect(format == nil)
}

@Test("defaultReasoningParser returns nil for an unknown model id via registryProvider")
func defaultReasoningParserReturnsNilForUnknownModelId() async {
    let engine = MultiModelBatchSchedulerEngine(
        registryProvider: { @Sendable in [:] }
    )
    let format = await engine.defaultReasoningParser(for: "missing/model")
    // No registry entry -> modelType resolves to nil -> the provider's
    // "safe default" (`inferReasoningParser(for: nil)`) still applies, same
    // as the coordinator WebSocket path's existing unconditional behavior.
    #expect(format == ProviderLoop.inferReasoningParser(for: nil))
}

// MARK: - Helpers

private actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

/// Minimal `Tokenizer` stub for tests that only need a `TokenizerHandle` to
/// exist (never actually encode/decode real text) -- e.g. the
/// `defaultReasoningParser` wiring tests above, which never submit a
/// request through the tokenizer.
private struct StubTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}
