import Foundation
import MLXLMCommon
import MLXLMServer
import MLXVLM
import Testing

@testable import ProviderCore

@Suite("Native media tool preparation")
struct NativeMediaToolPreparationTests {
    private func request(mode: String = "auto") throws -> OpenAIChatCompletionRequest {
        let json = #"""
        {"model":"DarkBloom/Qwen3.8-Flash-Next-Q4-mtp","tool_choice":"auto",
         "messages":[{"role":"user","content":"Inspect the picture"},
          {"role":"assistant","content":"","reasoning_content":"Read 42.",
           "tool_calls":[{"id":"call-test","type":"function","function":{"name":"report_number","arguments":"{\"number\":42}"}}]},
          {"role":"tool","tool_call_id":"call-test","name":"report_number","content":"saved"}],
         "tools":[{"type":"function","function":{"name":"report_number","description":"Record a number",
          "parameters":{"type":"object","properties":{"number":{"type":"integer"}},"required":["number"]}}}]}
        """#.replacingOccurrences(of: #""tool_choice":"auto""#, with: "\"tool_choice\":\"\(mode)\"")
        return try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data(json.utf8))
    }

    @Test func nativeInputPreservesDefinitionsAndToolHistory() async throws {
        let request = try request()
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let input = try await MediaIngest.buildUserInput(from: request,
            tools: prepared.tools?.map { $0.toolSpec() }, preserveTemplateFields: true)
        #expect(input.tools?.count == 1)
        let messages = Qwen3VLMessageGenerator().generate(from: input)
        #expect(messages.count == 3)
        #expect(messages[1]["reasoning_content"] as? String == "Read 42.")
        let calls = try #require(messages[1]["tool_calls"] as? [[String: any Sendable]])
        #expect(calls.count == 1)
        #expect(calls[0]["id"] as? String == "call-test")
        let function = try #require(calls[0]["function"] as? [String: any Sendable])
        #expect(function["name"] as? String == "report_number")
        let arguments = try #require(function["arguments"] as? [String: any Sendable])
        #expect(arguments["number"] as? Int == 42)
        #expect(messages[2]["tool_call_id"] as? String == "call-test")
        #expect(messages[2]["name"] as? String == "report_number")
        #expect(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "qwen4_exp") != nil)
    }

    @Test func noneHidesDefinitionsWithoutDeletingHistory() async throws {
        let request = try request(mode: "none")
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        let input = try await MediaIngest.buildUserInput(from: request,
            tools: prepared.tools?.map { $0.toolSpec() }, preserveTemplateFields: true)
        #expect(input.tools == nil)
        #expect(Qwen3VLMessageGenerator().generate(from: input)[1]["tool_calls"] != nil)
        #expect(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "qwen4_exp") == nil)
    }

    @Test func legacyPreparationKeepsExistingDefaults() async throws {
        let input = try await MediaIngest.buildUserInput(from: request())
        #expect(input.tools == nil)
        #expect(Qwen3VLMessageGenerator().generate(from: input)[1]["tool_calls"] == nil)
    }

    @Test func metadataCannotReplaceRolesOrNativeContentLayout() {
        var message = Chat.Message.user("original")
        message.templateFields = ["role": "system", "content": "replaced", "unknown": "discard",
                                  "name": "viewer", "reasoning_content": "literal"]
        let result = Qwen3VLMessageGenerator().generate(messages: [message])[0]
        #expect(result["role"] as? String == "user")
        let content = result["content"] as? [[String: String]]
        #expect(content?.last?["text"] == "original")
        #expect(result["unknown"] == nil)
        #expect(result["name"] as? String == "viewer")
    }

    @Test func nativeMediaRejectsUnsupportedEffortBeforeDecodingPixels() async throws {
        let body = #"""
        {"model":"DarkBloom/Qwen3.8-Flash-Next-Q4-mtp",
         "reasoning":{"enabled":true,"effort":"high"},
         "messages":[{"role":"user","content":[
           {"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}},
           {"type":"text","text":"Inspect the picture"}]}]}
        """#
        let decoded = try JSONDecoder().decode(
            OpenAIChatCompletionRequest.self, from: Data(body.utf8))
        do {
            _ = try await MediaIngest.buildUserInput(
                from: decoded, preserveTemplateFields: true, modelType: "qwen4_exp")
            Issue.record("unsupported native effort unexpectedly reached pixel decoding")
        } catch MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort {
            // The invalid image must not be decoded before the control error.
        }
    }
}
