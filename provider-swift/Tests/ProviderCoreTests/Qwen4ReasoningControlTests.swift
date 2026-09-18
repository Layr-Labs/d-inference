import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Native Qwen4 reasoning controls")
struct Qwen4ReasoningControlTests {
    @Test func typedResponsesEffortIsNotDroppedBeforeRendering() {
        let response = OpenAIResponseRequest(model: "owned-flash-next", input: .text("hello"),
            reasoning: .init(effort: "none"))
        let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
            for: response.chatCompletionRequest, controls: .init(reasoningEffort: "high"),
            modelType: "qwen4_exp")
        #expect(context?["enable_thinking"] as? Bool == false)
        #expect(context?["reasoning_effort"] as? String == "none")
    }

    @Test func explicitThinkingBooleanStillWinsOverTypedEffort() {
        let request = OpenAIChatCompletionRequest(model: "owned-flash-next",
            messages: [], reasoning: .init(enabled: true, effort: "none"))
        let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
            for: request, controls: .init(), modelType: "qwen4_exp")
        #expect(context?["enable_thinking"] as? Bool == true)
    }

    @Test func forcedToolsPreserveExplicitThinkingAndNestedPrecedence() {
        for type in ["qwen4_exp", "qwen4_exp_text"] {
            for enabled in [false, true] {
                let request = OpenAIChatCompletionRequest(
                    model: "owned-flash-next",
                    messages: [.init(role: .user, content: .text("call the tool"))],
                    reasoning: .init(enabled: enabled))
                let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                    for: request,
                    controls: .init(reasoningEffort: "high", enableThinking: !enabled, preserveThinking: true),
                    modelType: type, requiresToolCall: true)
                #expect(context?["enable_thinking"] as? Bool == enabled)
                #expect(context?["preserve_thinking"] as? Bool == true)
            }
            let request = OpenAIChatCompletionRequest(
                model: "owned-flash-next",
                messages: [.init(role: .user, content: .text("call the tool"))])
            let explicit = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, controls: .init(enableThinking: true),
                modelType: type, requiresToolCall: true)
            #expect(explicit?["enable_thinking"] as? Bool == true)
            let inherited = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, controls: .init(), modelType: type, requiresToolCall: true)
            #expect(inherited?["enable_thinking"] == nil)
        }
    }
}
