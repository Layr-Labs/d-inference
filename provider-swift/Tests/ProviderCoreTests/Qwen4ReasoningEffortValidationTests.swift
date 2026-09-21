import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

@Suite("Owned Flash-Next reasoning effort request validation")
struct Qwen4ReasoningEffortValidationTests {
    private let owned = Qwen4SupportPolicy.ownedModelID

    @Test(arguments: [Qwen4SupportPolicy.ownedModelID, Qwen4SupportPolicy.registryModelID])
    func supportedAndDefaultEffortsReachTokenizerUnchanged(owned: String) throws {
        for effort: String? in [nil, "low", "medium", "xhigh"] {
            let tokenizer = ReasoningContextTokenizer()
            let request = OpenAIChatCompletionRequest(model: owned,
                messages: [.init(role: .user, content: .text("hi"))],
                reasoning: .init(enabled: true, effort: effort))
            let tokens = try tokenize(request, controls: .init(), tokenizer: tokenizer)
            #expect(tokens == [7, 8])
            #expect(tokenizer.context?["enable_thinking"] as? Bool == true)
            #expect(tokenizer.context?["reasoning_effort"] as? String == effort)
            #expect(tokenizer.calls == 1)
        }
    }

    @Test(arguments: [Qwen4SupportPolicy.ownedModelID, Qwen4SupportPolicy.registryModelID])
    func unsupportedEffortsAreRejectedBeforeTemplateInvocation(owned: String) throws {
        for effort in ["high", "minimal", "unsupported", "LOW", " low ", ""] {
            let tokenizer = ReasoningContextTokenizer()
            let request = OpenAIChatCompletionRequest(model: owned,
                messages: [.init(role: .user, content: .text("hi"))],
                reasoning: .init(enabled: true, effort: effort))
            #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort) {
                try tokenize(request, controls: .init(), tokenizer: tokenizer)
            }
            #expect(tokenizer.calls == 0)
        }
    }

    @Test func disabledThinkingPreservesEveryCallerEffort() throws {
        for effort in ["high", "minimal", "unsupported", "none"] {
            let tokenizer = ReasoningContextTokenizer()
            let request = OpenAIChatCompletionRequest(model: owned,
                messages: [.init(role: .user, content: .text("hi"))],
                reasoning: .init(enabled: false, effort: effort))
            _ = try tokenize(request, controls: .init(reasoningEffort: "xhigh", enableThinking: true), tokenizer: tokenizer)
            #expect(tokenizer.context?["enable_thinking"] as? Bool == false)
            #expect(tokenizer.context?["reasoning_effort"] as? String == effort)
        }
    }

    @Test func resolvedAliasAndTypedBooleanPrecedenceIsUnchanged() throws {
        let base = OpenAIChatCompletionRequest(model: owned, messages: [.init(role: .user, content: .text("hi"))])
        let disabled = ReasoningContextTokenizer()
        _ = try tokenize(base, controls: .init(reasoningEffort: "high", enableThinking: false), tokenizer: disabled)
        #expect(disabled.context?["enable_thinking"] as? Bool == false)
        #expect(disabled.context?["reasoning_effort"] as? String == "high")
        #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort) {
            try tokenize(base, controls: .init(reasoningEffort: "high"), tokenizer: ReasoningContextTokenizer())
        }
        for effort in ["none", "off", "0"] {
            let tokenizer = ReasoningContextTokenizer()
            _ = try tokenize(base, controls: .init(reasoningEffort: effort), tokenizer: tokenizer)
            #expect(tokenizer.context?["enable_thinking"] as? Bool == false)
            var explicit = base
            explicit.reasoning = .init(enabled: true, effort: effort)
            #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort) {
                try tokenize(explicit, controls: .init(enableThinking: false), tokenizer: ReasoningContextTokenizer())
            }
        }
    }

    @Test func nonOwnedAndNonNativeTemplatesRemainUntouched() throws {
        let combinations: [(String, String?)] = [
            ("another-qwen4", "qwen4_exp"), (owned + "-alias", "qwen4_exp_text"),
            (owned, "qwen3_5"), (owned, nil),
        ]
        for (modelID, modelType) in combinations {
            try Qwen4SupportPolicy.validateReasoningContext(modelID: modelID, modelType: modelType,
                additionalContext: ["enable_thinking": true, "reasoning_effort": "high"])
        }
        for type in ["qwen4_exp", "qwen4_exp_text"] {
            #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort) {
                try Qwen4SupportPolicy.validateReasoningContext(modelID: owned, modelType: type,
                    additionalContext: ["reasoning_effort": "high"])
            }
        }
    }

    @Test(arguments: [Qwen4SupportPolicy.ownedModelID, Qwen4SupportPolicy.registryModelID])
    func responsesTypedEffortUsesTheSameValidationBoundary(owned: String) throws {
        for effort in ["high", "minimal"] {
            let request = OpenAIResponseRequest(model: owned, input: .text("hi"), reasoning: .init(effort: effort))
            let tokenizer = ReasoningContextTokenizer()
            #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort) {
                try tokenize(request.chatCompletionRequest, controls: .init(enableThinking: true), tokenizer: tokenizer)
            }
            #expect(tokenizer.calls == 0)
        }
    }

    @Test func typedErrorUsesClient400ClassificationOnBothServingPaths() throws {
        let error = MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort
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

    private func tokenize(_ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls,
        tokenizer: ReasoningContextTokenizer) throws -> [Int] {
        try ProviderPromptContractPipeline.tokenize(prepared: ToolChoicePromptPolicy.prepare(request),
            request: request, tokenizer: tokenizer, modelType: "qwen4_exp", templateControls: controls)
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
