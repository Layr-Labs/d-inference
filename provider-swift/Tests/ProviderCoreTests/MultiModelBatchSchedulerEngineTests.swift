import Foundation
import MLXLMServer
import Testing
@testable import ProviderCore

// Unit tests for the `MLXServerEngine` adapter that bridges the
// multi-model slot registry (one `EngineV2Bridge` per entry as of the
// v0.7.5 one-engine shape) to the upstream MLXLMServer runtime. These
// tests focus on the dispatch + translation + lifecycle hooks that
// don't require a live engine. End-to-end generation is covered by the
// live test suites.

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
    // Verify the empty path; the sort property is documented and tested
    // via end-to-end live tests where real engine slots are present.
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

@Test("translate maps OpenAI fields onto the internal ChatCompletionRequest")
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

@Test("template context forwards OpenRouter reasoning.enabled")
func templateContextForwardsReasoningEnabled() {
    let enabled = OpenAIChatCompletionRequest(
        model: "gemma-4",
        messages: [.init(role: .user, content: .text("hi"))],
        reasoning: .init(enabled: true))
    let disabled = OpenAIChatCompletionRequest(
        model: "gemma-4",
        messages: [.init(role: .user, content: .text("hi"))],
        reasoning: .init(enabled: false))

    let enabledContext = MultiModelBatchSchedulerEngine.templateAdditionalContext(
        for: enabled, reasoningEffort: nil)
    let disabledContext = MultiModelBatchSchedulerEngine.templateAdditionalContext(
        for: disabled, reasoningEffort: nil)

    #expect(enabledContext?["enable_thinking"] as? Bool == true)
    #expect(disabledContext?["enable_thinking"] as? Bool == false)
}

@Test("template context composes reasoning.enabled with reasoning_effort")
func templateContextComposesReasoningControls() {
    let request = OpenAIChatCompletionRequest(
        model: "gemma-4",
        messages: [.init(role: .user, content: .text("hi"))],
        reasoning: .init(enabled: true))

    let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
        for: request, reasoningEffort: "high")

    #expect(context?["enable_thinking"] as? Bool == true)
    #expect(context?["reasoning_effort"] as? String == "high")
}

@Test("template context honors enableThinkingOverride when reasoning.enabled absent")
func templateContextHonorsEnableThinkingOverride() {
    let request = OpenAIChatCompletionRequest(
        model: "qwen",
        messages: [.init(role: .user, content: .text("hi"))])

    let disabled = MultiModelBatchSchedulerEngine.templateAdditionalContext(
        for: request, reasoningEffort: nil, enableThinkingOverride: false)
    let enabled = MultiModelBatchSchedulerEngine.templateAdditionalContext(
        for: request, reasoningEffort: nil, enableThinkingOverride: true)

    #expect(disabled?["enable_thinking"] as? Bool == false)
    #expect(enabled?["enable_thinking"] as? Bool == true)
}

@Test("template context maps reasoning_effort none/off to enable_thinking false; minimal stays on")
func templateContextMapsNoneEffortToDisableThinking() {
    let request = OpenAIChatCompletionRequest(
        model: "qwen",
        messages: [.init(role: .user, content: .text("hi"))])

    for effort in ["none", "off", "0", "NONE"] {
        let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
            for: request, reasoningEffort: effort)
        #expect(context?["enable_thinking"] as? Bool == false, "effort=\(effort)")
        #expect(context?["reasoning_effort"] as? String == effort)
    }

    let minimal = MultiModelBatchSchedulerEngine.templateAdditionalContext(
        for: request, reasoningEffort: "minimal")
    #expect(minimal?["enable_thinking"] as? Bool == nil, "minimal must not force disable")
    #expect(minimal?["reasoning_effort"] as? String == "minimal")
}

@Test("nested reasoning.enabled wins over enableThinkingOverride and none effort")
func nestedReasoningEnabledWins() {
    let request = OpenAIChatCompletionRequest(
        model: "qwen",
        messages: [.init(role: .user, content: .text("hi"))],
        reasoning: .init(enabled: true))

    let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
        for: request, reasoningEffort: "none", enableThinkingOverride: false)

    #expect(context?["enable_thinking"] as? Bool == true)
}

@Test("extractEnableThinking reads top-level and chat_template_kwargs")
func extractEnableThinkingFromBody() throws {
    let top = #"{"model":"q","messages":[],"enable_thinking":false}"#.data(using: .utf8)!
    #expect(ProviderLoop.extractEnableThinking(from: top) == false)

    let kwargs = #"{"model":"q","messages":[],"chat_template_kwargs":{"enable_thinking":false}}"#
        .data(using: .utf8)!
    #expect(ProviderLoop.extractEnableThinking(from: kwargs) == false)

    let missing = #"{"model":"q","messages":[]}"#.data(using: .utf8)!
    #expect(ProviderLoop.extractEnableThinking(from: missing) == nil)
}

// MARK: - Engine error mapping (P2 #6)
//
// Pins the `MultiModelBatchSchedulerEngineError.fromSchedulerMessage`
// translator that converts engine `.error(message)` payloads into typed
// errors so `ProviderLoop.mapInferenceErrorToStatus` can return 429/503
// instead of collapsing every admission failure into 500. The string
// prefixes here MUST stay in sync with the `token_budget_exhausted:`
// message contract `EngineV2Bridge` and `EngineV2Translation` emit.

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

@Test("platformTerminal maps each cause to its client status, never 429")
func platformTerminalStatusMapping() {
    // Client-facing status only — the coordinator's HEALTH decisions key off
    // terminal_cause, not this code. The incident report forbids 429 for any
    // policy deadline.
    let cases: [(InferenceTerminalCause, UInt16)] = [
        (.admissionTimeout, 503),
        (.safetyDeadline, 504),
        (.backpressureTimeout, 504),
        (.prefillStall, 500),
        (.decodeStall, 500),
        (.watchdog, 500),
        (.cancelled, 499),
        (.engineError, 500),
    ]
    for (cause, expected) in cases {
        let err = MultiModelBatchSchedulerEngineError.platformTerminal(
            cause: cause, message: "\(cause.rawValue): x",
            attemptUsage: UsageInfo(promptTokens: 1, completionTokens: 2))
        let status = ProviderLoop.mapInferenceErrorToStatus(err)
        #expect(status == expected, "cause \(cause.rawValue) → \(status), expected \(expected)")
        #expect(status != 429, "a policy deadline must never be relabeled a rate limit")
    }
}

@Test("platformTerminal carries cause + usage to the handler; legacy errors do not")
func platformTerminalMetadataExtraction() {
    let usage = UsageInfo(promptTokens: 9, completionTokens: 4)
    let terminal = MultiModelBatchSchedulerEngineError.platformTerminal(
        cause: .decodeStall, message: "decode_stall: no progress", attemptUsage: usage)
    let meta = ProviderLoop.inferenceTerminalMetadata(from: terminal)
    #expect(meta.cause == .decodeStall)
    #expect(meta.usage?.promptTokens == 9)
    #expect(meta.usage?.completionTokens == 4)
    // The human-readable error stays informative (cause-prefixed).
    #expect(terminal.errorDescription == "decode_stall: no progress")

    // Mixed-version: a legacy string error yields today's exact wire shape —
    // no typed cause, no attempt usage, still 500.
    let legacy = MultiModelBatchSchedulerEngineError.generationFailed("boom")
    let legacyMeta = ProviderLoop.inferenceTerminalMetadata(from: legacy)
    #expect(legacyMeta.cause == nil)
    #expect(legacyMeta.usage == nil)
    #expect(ProviderLoop.mapInferenceErrorToStatus(legacy) == 500)
}

@Test("legacy-request-timeout kill-switch: only affirmative values enable it")
func legacyRequestTimeoutKillSwitchParse() {
    let key = EngineV2Factory.legacyRequestTimeoutEnvKey
    // Absent → new-lease default (kill-switch off).
    #expect(EngineV2Factory.legacyRequestTimeoutEnabled(environment: [:]) == false)
    for on in ["1", "true", "TRUE", "yes", "on", " On "] {
        #expect(
            EngineV2Factory.legacyRequestTimeoutEnabled(environment: [key: on]) == true,
            "\(on) should enable the kill-switch")
    }
    // A typo must not silently re-arm the flat 120s wall.
    for off in ["0", "false", "no", "off", "", "garbage"] {
        #expect(
            EngineV2Factory.legacyRequestTimeoutEnabled(environment: [key: off]) == false,
            "\(off) must not enable the kill-switch")
    }
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
    let ids = ModelEOSPolicy.effectiveEOSTokenIds(
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
    let ids = ModelEOSPolicy.effectiveEOSTokenIds(
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
    let ids = ModelEOSPolicy.effectiveEOSTokenIds(
        modelId: "mlx-community/Qwen3-0.6B",
        base: [151645]
    ) { _ in 200012 }

    #expect(ids == [151645])
}

// MARK: - Helpers

private actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
