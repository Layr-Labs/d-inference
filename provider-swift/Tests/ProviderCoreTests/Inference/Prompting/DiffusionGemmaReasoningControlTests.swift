import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("DiffusionGemma binary native reasoning control")
struct DiffusionGemmaReasoningControlTests {
    @Test func emissionPermissionMatchesNativeRenderingPrecedence() throws {
        for nested: Bool? in [nil, false, true] {
            for raw: Bool? in [nil, false, true] {
                for effort: String? in [nil, "none", "OFF", "0", "minimal", "medium", "xhigh", "max"] {
                    let request = OpenAIChatCompletionRequest(model: "native-diffusion", messages: [],
                        reasoning: .init(enabled: nested, effort: effort))
                    let controls = ChatTemplateControls(reasoningEffort: "high", enableThinking: raw)
                    let expected = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                        for: request, controls: controls, modelType: "diffusion_gemma")?["enable_thinking"] as? Bool ?? false
                    #expect(DiffusionGemmaReasoningControl.enabled(for: request, controls: controls) == expected)
                }
            }
        }
        #expect(!DiffusionGemmaReasoningControl.enabled(
            for: .init(model: "native-diffusion", messages: []), controls: .init()))
    }

    @Test func nativeTemplateNormalizationDoesNotEnableARConstraints() {
        #expect(!Gemma4TemplateFix.applies(to: .init(modelId: "native", modelType: "diffusion_gemma")))
        #expect(!Gemma4ToolConstraintContract.supports(modelType: "diffusion_gemma"))
        for type in ["llama", "qwen4_exp", "prism_hadamard_qwen35"] {
            #expect(!Gemma4TemplateFix.applies(to: .init(modelId: "native-diffusion", modelType: type)))
        }
    }

    @Test func responsesPositiveEffortActivatesNativeThinking() throws {
        for effort in ["minimal", "low", "medium", "high", "xhigh", "max", " Max "] {
            let request = OpenAIResponseRequest(model: "native-diffusion", input: .text("hello"),
                reasoning: .init(effort: effort)).chatCompletionRequest
            try ReasoningEffortPolicy.validate(request, controls: .init(), modelType: "diffusion_gemma")
            let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, controls: .init(), modelType: "diffusion_gemma")
            #expect(context?["enable_thinking"] as? Bool == true)
        }
    }

    @Test func offAbsenceAndExplicitBooleanKeepTheirDistinctContracts() throws {
        let base = OpenAIChatCompletionRequest(model: "native-diffusion", messages: [])
        #expect(MultiModelBatchSchedulerEngine.templateAdditionalContext(
            for: base, controls: .init(), modelType: "diffusion_gemma")?["enable_thinking"] == nil)
        for effort in ["none", "off", "0"] {
            var request = base
            request.reasoning = .init(effort: effort)
            #expect(MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, controls: .init(reasoningEffort: "high"), modelType: "diffusion_gemma")?["enable_thinking"] as? Bool == false)
        }
        for enabled in [false, true] {
            var request = base
            request.reasoning = .init(enabled: enabled, effort: "medium")
            #expect(MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, controls: .init(enableThinking: !enabled), modelType: "diffusion_gemma")?["enable_thinking"] as? Bool == enabled)
        }
    }

    @Test func unknownEffortFailsClosedWithoutChangingOtherModels() throws {
        let request = OpenAIChatCompletionRequest(model: "native-diffusion", messages: [],
            reasoning: .init(effort: "unsupported"))
        #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(.reasoningObject)) {
            try ReasoningEffortPolicy.validate(request, controls: .init(), modelType: "diffusion_gemma")
        }
        for type: String? in [nil, "qwen4_exp", "gemma4", "llama"] {
            let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, controls: .init(), modelType: type)
            #expect(context?["enable_thinking"] == nil)
        }
        // A model that doesn't reason ignores the effort.
        for type: String? in [nil, "llama"] {
            try ReasoningEffortPolicy.validate(request, controls: .init(), modelType: type)
        }
        #expect(ProviderLoop.mapInferenceErrorToStatus(
            MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(.reasoningObject)) == 400)
    }
}
