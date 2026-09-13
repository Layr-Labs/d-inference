import Foundation
import Jinja
import MLXLMServer
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

struct PromptDateRenderingTests {
    private func render(_ controls: ChatTemplateControls) throws -> String {
        let request = try ProviderLoop.decodeOpenAIRequest(
            Data(#"{"model":"gpt-oss-20b","messages":[{"role":"user","content":"hello"}]}"#.utf8))
        let additional = MultiModelBatchSchedulerEngine.templateAdditionalContext(
            for: request, controls: controls, modelType: "gpt_oss") ?? [:]
        let context = try additional.mapValues { try Value(any: $0) }
        let template = try Template(
            normalizeSwiftJinjaTemplate(#"Current date: {{ strftime_now("%Y-%m-%d") }}"#),
            with: .init(lstripBlocks: true, trimBlocks: true))
        return try template.render(context)
    }

    @Test func remoteDateStaysPinnedAcrossRenderingAndMidnight() throws {
        let body = Data(#"{"_darkbloom_prompt_date":"2028-02-29","reasoning_effort":"medium"}"#.utf8)
        let controls = ProviderLoop.extractChatTemplateControls(from: body)
        let nextDay = try #require(ISO8601DateFormatter().date(from: "2028-03-01T00:00:01Z"))
        let retry = controls.resolvingPromptDate(at: nextDay)
        #expect(retry == controls)
        #expect(try render(controls) == "Current date: 2028-02-29")
        #expect(try render(retry) == "Current date: 2028-02-29")
        #expect(try render(ChatTemplateControls().resolvingPromptDate(at: nextDay)) == "Current date: 2028-03-01")
    }

    @Test func localHTTPReplacesCallerDate() throws {
        let before = PromptRenderDate.capture()
        let body = Data(#"{"model":"gpt-oss-20b","messages":[],"_darkbloom_prompt_date":"1999-01-01"}"#.utf8)
        let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
        let after = PromptRenderDate.capture()
        let captured = try #require(local.templateControls.promptDate)
        #expect(captured == before || captured == after)
        #expect(try render(local.templateControls) == "Current date: \(captured.value)")
    }

    @Test func malformedDateDoesNotEraseOtherControls() {
        let controls = ProviderLoop.extractChatTemplateControls(
            from: Data(#"{"_darkbloom_prompt_date":"2026-02-29","enable_thinking":false}"#.utf8))
        #expect(controls.promptDate == nil)
        #expect(controls.enableThinking == false)
    }
}
