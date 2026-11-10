import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// The Qwen 3.8 template renders `low`, `medium` and `xhigh` (its default)
/// and raises for any other effort while thinking. Every effort a client sends
/// reaches it as one of those; one that is none of the names is refused before
/// the template runs.
@Suite("Qwen 3.8 effort template levels")
struct Qwen4ReasoningEffortValidationTests {
    private let owned = Qwen4SupportPolicy.ownedModelID
    private static let levels: [String?: String?] = [
        nil: nil, "minimal": "low", "low": "low", "medium": "medium", "high": "xhigh", "xhigh": "xhigh",
        "max": "xhigh", "LOW": "low", " low ": "low", "High": "xhigh",
    ]

    @Test(arguments: [Qwen4SupportPolicy.ownedModelID, Qwen4SupportPolicy.registryModelID])
    func everyEffortReachesTheTemplateAsOneOfItsLevels(owned: String) throws {
        for (effort, level) in Self.levels {
            let tokenizer = ReasoningContextTokenizer()
            let request = OpenAIChatCompletionRequest(model: owned,
                messages: [.init(role: .user, content: .text("hi"))],
                reasoning: .init(enabled: true, effort: effort))
            let tokens = try tokenize(request, controls: .init(), tokenizer: tokenizer)
            #expect(tokens == [7, 8])
            #expect(tokenizer.context?["enable_thinking"] as? Bool == true)
            #expect(tokenizer.context?["reasoning_effort"] as? String == level, "\(effort ?? "nil")")
            #expect(tokenizer.calls == 1)
        }
    }

    @Test(arguments: [Qwen4SupportPolicy.ownedModelID, Qwen4SupportPolicy.registryModelID])
    func anUnknownEffortIsRefusedBeforeTemplateInvocation(owned: String) throws {
        for effort in ["unsupported", "", "on"] {
            let tokenizer = ReasoningContextTokenizer()
            let request = OpenAIChatCompletionRequest(model: owned,
                messages: [.init(role: .user, content: .text("hi"))],
                reasoning: .init(enabled: true, effort: effort))
            #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(.reasoningObject)) {
                try tokenize(request, controls: .init(), tokenizer: tokenizer)
            }
            #expect(tokenizer.calls == 0)
        }
    }

    @Test func disabledThinkingKeepsTheCallerEffortTheTemplateIgnores() throws {
        for effort in ["high", "minimal", "none", "max"] {
            let tokenizer = ReasoningContextTokenizer()
            let request = OpenAIChatCompletionRequest(model: owned,
                messages: [.init(role: .user, content: .text("hi"))],
                reasoning: .init(enabled: false, effort: effort))
            _ = try tokenize(request, controls: .init(reasoningEffort: "xhigh", enableThinking: true), tokenizer: tokenizer)
            #expect(tokenizer.context?["enable_thinking"] as? Bool == false)
            #expect(tokenizer.context?["reasoning_effort"] as? String == effort)
        }
        let request = OpenAIChatCompletionRequest(model: owned,
            messages: [.init(role: .user, content: .text("hi"))],
            reasoning: .init(enabled: false, effort: "unsupported"))
        #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(.reasoningObject)) {
            try tokenize(request, controls: .init(), tokenizer: ReasoningContextTokenizer())
        }
    }

    @Test func resolvedAliasAndTypedBooleanPrecedenceIsUnchanged() throws {
        let base = OpenAIChatCompletionRequest(model: owned, messages: [.init(role: .user, content: .text("hi"))])
        let disabled = ReasoningContextTokenizer()
        _ = try tokenize(base, controls: .init(reasoningEffort: "high", enableThinking: false), tokenizer: disabled)
        #expect(disabled.context?["enable_thinking"] as? Bool == false)
        #expect(disabled.context?["reasoning_effort"] as? String == "high")
        let raw = ReasoningContextTokenizer()
        _ = try tokenize(base, controls: .init(reasoningEffort: "high"), tokenizer: raw)
        #expect(raw.context?["reasoning_effort"] as? String == "xhigh")
        for effort in ["none", "off", "0"] {
            let tokenizer = ReasoningContextTokenizer()
            _ = try tokenize(base, controls: .init(reasoningEffort: effort), tokenizer: tokenizer)
            #expect(tokenizer.context?["enable_thinking"] as? Bool == false)
            // Thinking switched on explicitly: `none` is the lowest level.
            var explicit = base
            explicit.reasoning = .init(enabled: true, effort: effort)
            let on = ReasoningContextTokenizer()
            _ = try tokenize(explicit, controls: .init(enableThinking: false), tokenizer: on)
            #expect(on.context?["enable_thinking"] as? Bool == true)
            #expect(on.context?["reasoning_effort"] as? String == "low")
        }
    }

    /// The levels follow the template: the Qwen 3.5 template family (its
    /// strictest member is 3.8's) and the owned Flash-Next build. Another
    /// Qwen4 artifact may ship another template; its effort goes as sent.
    @Test func levelsFollowTheTemplateNotTheArchitecture() {
        let mapped: [(String, String?)] = [
            (owned, "qwen4_exp"), (owned, "qwen4_exp_text"), (owned, "qwen3_5"), ("Qwen3.5-9B", "qwen3_5"),
            ("eigenlabs/qwen3.8-27b-4bit-mtp", "qwen3_5"), ("bonsai", "prism_hadamard_qwen35"),
            (ModelRuntimeRequirements.qwen38ConcreteModelID, nil),
        ]
        let untouched: [(String, String?)] = [
            ("another-qwen4", "qwen4_exp"), (owned + "-alias", "qwen4_exp_text"), (owned, nil),
            ("qwen3-vl-30b-a3b-instruct", "qwen3_vl_moe"), ("gemma-4-26b", "gemma4"),
        ]
        for (cases, expected) in [(mapped, "xhigh"), (untouched, "high")] {
            for (model, type) in cases {
                let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                    for: .init(model: model, messages: []), controls: .init(reasoningEffort: "high"), modelType: type)
                #expect(context?["reasoning_effort"] as? String == expected, "\(model) \(type ?? "nil")")
            }
        }
    }

    @Test(arguments: [Qwen4SupportPolicy.ownedModelID, Qwen4SupportPolicy.registryModelID])
    func responsesTypedEffortReachesTheSameLevels(owned: String) throws {
        for (effort, level) in [("high", "xhigh"), ("minimal", "low"), ("max", "xhigh")] {
            let request = OpenAIResponseRequest(model: owned, input: .text("hi"), reasoning: .init(effort: effort))
            let tokenizer = ReasoningContextTokenizer()
            _ = try tokenize(request.chatCompletionRequest, controls: .init(enableThinking: true), tokenizer: tokenizer)
            #expect(tokenizer.context?["reasoning_effort"] as? String == level)
        }
    }

    @Test(arguments: [MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(.reasoningEffort),
                      .conflictingReasoningEfforts])
    func typedErrorUsesClient400ClassificationOnBothServingPaths(error: MultiModelBatchSchedulerEngineError) throws {
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .streamStart)
        #expect(failure.statusCode == 400)
        #expect(failure.code == .invalidRequest)
        #expect(failure.errorReason == .clientError)
        #expect(classifyInferenceErrorReason(error) == nil)
        let wire = try ProviderProtocolCodec.encodeProviderMessage(.inferenceError(.init(requestId: "effort-fixture", failure: failure)))
        let json = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(json["status_code"] as? Int == 400)
        #expect(json["error_reason"] as? String == "client_error")
        #expect(!String(decoding: wire, as: UTF8.self).contains("jinja"))
    }

    @Test(arguments: ModelRuntimeRequirements.qwen38ConcreteModelIDs.sorted())
    func qwen38BuildsShareTheEffortLevels(model: String) throws {
        let hi: [OpenAIChatMessage] = [.init(role: .user, content: .text("hi"))]
        // Raw-body `reasoning_effort`, the shape OpenRouter and Hermes send.
        for (effort, level) in Self.levels {
            let tokenizer = ReasoningContextTokenizer()
            _ = try tokenize(.init(model: model, messages: hi), controls: .init(reasoningEffort: effort),
                tokenizer: tokenizer, modelType: "qwen3_5")
            #expect(tokenizer.context?["reasoning_effort"] as? String == level, "\(effort ?? "nil")")
        }
        let tokenizer = ReasoningContextTokenizer()
        #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(.reasoningEffort)) {
            try tokenize(.init(model: model, messages: hi), controls: .init(reasoningEffort: "turbo"),
                tokenizer: tokenizer, modelType: "qwen3_5")
        }
        #expect(tokenizer.calls == 0)
        _ = try tokenize(.init(model: model, messages: hi), controls: .init(reasoningEffort: "high", enableThinking: false),
            tokenizer: ReasoningContextTokenizer(), modelType: "qwen3_5")
    }

    private func tokenize(_ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls,
        tokenizer: ReasoningContextTokenizer, modelType: String = "qwen4_exp") throws -> [Int] {
        try ProviderPromptContractPipeline.tokenize(prepared: ToolChoicePromptPolicy.prepare(request),
            request: request, tokenizer: tokenizer, modelType: modelType, templateControls: controls)
    }
}

private final class ReasoningContextTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedContext: [String: any Sendable]?
    private var count = 0
    var context: [String: any Sendable]? { lock.withLock { recordedContext } }
    var calls: Int { lock.withLock { count } }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [7, 8] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "hi" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        lock.withLock { recordedContext = additionalContext; count += 1 }
        return [7, 8]
    }
}
