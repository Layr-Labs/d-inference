import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Local chat request decoding")
struct LocalChatRequestTests {
    @Test("template extensions preserve the complete upstream request")
    func upstreamFieldsArePreserved() throws {
        let data = Data(#"""
        {
          "model":"test/qwen",
          "messages":[
            {"role":"user","content":[
              {"type":"text","text":"Hello 🦋"},
              {"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}}
            ]},
            {"role":"assistant","content":"", "tool_calls":[
              {"id":"call_1","type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}
            ]},
            {"role":"tool","tool_call_id":"call_1","content":"Sunny"}
          ],
          "tools":[{"type":"function","function":{"name":"weather","parameters":{"type":"object","properties":{"city":{"type":"string"}}}}}],
          "tool_choice":"auto","parallel_tool_calls":false,
          "reasoning":{"enabled":true},"stream":true,
          "stream_options":{"include_usage":true,"continuous_usage_stats":true},
          "temperature":0.2,"top_p":0.9,"top_k":30,"min_p":0.1,
          "max_tokens":80,"stop":["stop"],
          "reasoning_effort":" high ","enable_thinking":false,
          "chat_template_kwargs":{"enable_thinking":true},"preserve_thinking":true,
          "unknown_extension":{"enable_thinking":true,"messages":"ignored"}
        }
        """#.utf8)
        let decoder = JSONDecoder()
        let local = try decoder.decode(LocalChatRequest.self, from: data)
        let upstream = try decoder.decode(OpenAIChatCompletionRequest.self, from: data)
        #expect(local.request == upstream)
        #expect(local.templateControls == ChatTemplateControls(
            reasoningEffort: "high", enableThinking: false, preserveThinking: true,
            promptDate: try #require(local.templateControls.promptDate)))
        #expect(local.request.reasoning?.enabled == true)
        #expect(local.request.streamOptions?.includeUsage == true)
        #expect(local.request.streamOptions?.continuousUsageStats == true)
    }

    @Test("malformed extension fields are isolated and retain alias precedence", arguments: [
        (#""reasoning_effort":7,"enable_thinking":false,"preserve_thinking":true"#,
         ChatTemplateControls(enableThinking: false, preserveThinking: true)),
        (#""reasoning_effort":" custom ","enable_thinking":"yes","chat_template_kwargs":{"enable_thinking":true},"preserve_thinking":false"#,
         ChatTemplateControls(reasoningEffort: "custom", enableThinking: true, preserveThinking: false)),
        (#""reasoning_effort":" \n ","enable_thinking":null,"chat_template_kwargs":{"enable_thinking":false},"preserve_thinking":{}"#,
         ChatTemplateControls(enableThinking: false)),
        (#""enable_thinking":true,"chat_template_kwargs":false,"preserve_thinking":false"#,
         ChatTemplateControls(enableThinking: true, preserveThinking: false)),
        (#""enable_thinking":0,"chat_template_kwargs":{"enable_thinking":1},"preserve_thinking":"false""#,
         ChatTemplateControls()),
        (#""unknown_extension":{"enable_thinking":true},"reasoning":{"enabled":false}"#,
         ChatTemplateControls()),
    ])
    func malformedExtensionsAreIndependent(fragment: String, expected: ChatTemplateControls) throws {
        let data = Data((#"{"model":"test/qwen","messages":[],"# + fragment + "}").utf8)
        let local = try JSONDecoder().decode(LocalChatRequest.self, from: data)
        #expect(local.templateControls == expected.withPromptDate(try #require(local.templateControls.promptDate)))
        #expect(ProviderLoop.extractChatTemplateControls(from: data) == expected)
    }

    @Test("batch controls follow their request, including items without extensions")
    func batchControlsStayWithTheirRequest() throws {
        let data = Data(#"""
        [
          {"model":"one","messages":[],"stream":true,"enable_thinking":false},
          {"model":"two","messages":[],"stream":false},
          {"model":"three","messages":[],"chat_template_kwargs":{"enable_thinking":true},"preserve_thinking":"invalid"}
        ]
        """#.utf8)
        let decoder = JSONDecoder()
        let local = try decoder.decode([LocalChatRequest].self, from: data)
        let upstream = try decoder.decode([OpenAIChatCompletionRequest].self, from: data)
        #expect(local.map(\.request) == upstream)
        let expected = [
            ChatTemplateControls(enableThinking: false),
            ChatTemplateControls(),
            ChatTemplateControls(enableThinking: true),
        ]
        for (item, controls) in zip(local, expected) {
            #expect(item.templateControls == controls.withPromptDate(try #require(item.templateControls.promptDate)))
        }
    }

    @Test("invalid upstream fields keep their original decode error", arguments: [
        #"{"model":7,"messages":[]}"#,
        #"{"model":"m","messages":[],"stream":"yes"}"#,
        #"{"model":"m","messages":[],"stream_options":{"include_usage":1}}"#,
        #"{"model":"m","messages":[],"reasoning":{"enabled":"yes"}}"#,
        #"{"model":"m","messages":[],"tools":[{"type":"function"}]}"#,
        #"{"model":"m","messages":null}"#,
        #"{"messages":[]}"#,
        "null", "[]", "{",
    ])
    func invalidRequestsKeepTheirError(json: String) throws {
        let data = Data(json.utf8)
        #expect(try failure(LocalChatRequest.self, data: data)
            == failure(OpenAIChatCompletionRequest.self, data: data))
        // The batch decoder must also reject the entire batch with the same
        // item index; valid optional controls cannot hide a malformed request.
        let batch = Data((#"[{"model":"ok","messages":[],"enable_thinking":false},"# + json + "]").utf8)
        #expect(try failure([LocalChatRequest].self, data: batch)
            == failure([OpenAIChatCompletionRequest].self, data: batch))
    }

    private func failure<T: Decodable>(_ type: T.Type, data: Data) throws -> String {
        do {
            _ = try JSONDecoder().decode(type, from: data)
            Issue.record("Malformed request unexpectedly decoded")
            return "unexpected success"
        } catch let error as DecodingError {
            switch error {
            case .dataCorrupted(let context):
                return "corrupt:\(context.codingPath.map(\.stringValue))"
            case .keyNotFound(let key, let context):
                return "missing:\(key.stringValue):\(context.codingPath.map(\.stringValue))"
            case .typeMismatch(_, let context):
                return "type:\(context.codingPath.map(\.stringValue))"
            case .valueNotFound(_, let context):
                return "null:\(context.codingPath.map(\.stringValue))"
            @unknown default:
                throw error
            }
        }
    }
}
