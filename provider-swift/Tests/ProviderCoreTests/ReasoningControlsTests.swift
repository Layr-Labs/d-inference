import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("OpenRouter reasoning controls")
struct ReasoningControlsTests {

    @Test("unspecified leaves thinking at the template default")
    func unspecified() {
        let controls = ReasoningControls.parse(from: Data(#"{"model":"m","messages":[]}"#.utf8))
        #expect(controls.thinkingEnabled == nil)
        #expect(!controls.thinkingDisabled)
        #expect(!controls.suppressOutput)
        #expect(controls.effortForTemplate == nil)
    }

    @Test("enabled false disables thinking and suppresses output")
    func enabledFalse() {
        let controls = ReasoningControls.parse(
            from: Data(#"{"reasoning":{"enabled":false}}"#.utf8))
        #expect(controls.thinkingDisabled)
        #expect(controls.suppressOutput)
    }

    @Test("effort none disables thinking")
    func effortNone() {
        let object = ReasoningControls.parse(
            from: Data(#"{"reasoning":{"effort":"none"}}"#.utf8))
        let topLevel = ReasoningControls.parse(
            from: Data(#"{"reasoning_effort":"NONE"}"#.utf8))
        #expect(object.thinkingDisabled)
        #expect(object.effortForTemplate == nil)
        #expect(topLevel.thinkingDisabled)
        #expect(topLevel.effortForTemplate == nil)
    }

    @Test("max_tokens 0 disables thinking")
    func maxTokensZero() {
        let controls = ReasoningControls.parse(
            from: Data(#"{"reasoning":{"max_tokens":0}}"#.utf8))
        let asString = ReasoningControls.parse(
            from: Data(#"{"reasoning":{"max_tokens":"0"}}"#.utf8))
        #expect(controls.thinkingDisabled)
        #expect(controls.suppressOutput)
        #expect(asString.thinkingDisabled)
    }

    @Test("exclude hides the trace without disabling thinking")
    func excludeOnly() {
        let controls = ReasoningControls.parse(
            from: Data(#"{"reasoning":{"exclude":true}}"#.utf8))
        #expect(!controls.thinkingDisabled)
        #expect(controls.suppressOutput)
    }

    @Test("include_reasoning false is exclude, not disable")
    func includeReasoningFalse() {
        let controls = ReasoningControls.parse(
            from: Data(#"{"include_reasoning":false}"#.utf8))
        #expect(!controls.thinkingDisabled)
        #expect(controls.suppressOutput)
    }

    @Test("chat_template_kwargs and top-level enable_thinking disable")
    func templateKwargs() {
        let kwargs = ReasoningControls.parse(
            from: Data(#"{"chat_template_kwargs":{"enable_thinking":false}}"#.utf8))
        let topLevel = ReasoningControls.parse(
            from: Data(#"{"enable_thinking":false}"#.utf8))
        #expect(kwargs.thinkingDisabled)
        #expect(topLevel.thinkingDisabled)
    }

    @Test("boolean reasoning false disables")
    func booleanFalse() {
        let controls = ReasoningControls.parse(from: Data(#"{"reasoning":false}"#.utf8))
        #expect(controls.thinkingDisabled)
    }

    @Test("high effort stays enabled and is forwarded to the template")
    func highEffort() {
        let controls = ReasoningControls.parse(
            from: Data(#"{"reasoning":{"effort":"high","enabled":true}}"#.utf8))
        #expect(controls.thinkingEnabled == true)
        #expect(controls.effortForTemplate == "high")
        #expect(!controls.suppressOutput)
    }

    @Test("template context maps every disable shape to enable_thinking false")
    func templateContextDisableShapes() {
        let request = OpenAIChatCompletionRequest(
            model: "qwen3.6",
            messages: [.init(role: .user, content: .text("hi"))])
        let bodies = [
            #"{"reasoning":{"enabled":false}}"#,
            #"{"reasoning":{"effort":"none"}}"#,
            #"{"reasoning":{"max_tokens":0}}"#,
            #"{"reasoning_effort":"none"}"#,
            #"{"enable_thinking":false}"#,
        ]
        for body in bodies {
            let controls = ReasoningControls.parse(from: Data(body.utf8))
            let context = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, reasoningEffort: nil, controls: controls)
            #expect(context?["enable_thinking"] as? Bool == false, "body \(body)")
            #expect(context?["reasoning_effort"] == nil, "none must not reach Harmony")
        }
    }
}
