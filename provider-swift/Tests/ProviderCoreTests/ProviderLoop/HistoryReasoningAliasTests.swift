// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

/// A history turn's reasoning echoed back as OpenRouter returns it
/// (`reasoning`) or as `thinking` reaches the chat template as
/// `reasoning_content`, the field the templates read, with transformers'
/// precedence: the first non-null of `reasoning_content`, `thinking`,
/// `reasoning`.
@Suite("History reasoning aliases")
struct HistoryReasoningAliasTests {
    private static func body(_ assistantFields: String) -> Data {
        Data(#"{"model":"m","messages":[{"role":"user","content":"Q1"},{"role":"assistant","content":"A1",\#(assistantFields)},{"role":"user","content":"Q2"}]}"#.utf8)
    }

    /// Each message's `reasoningContent` on every decode path that serves a
    /// request: admission (`decodeInboundChatRequest`), the prompt pipeline
    /// and Super's plan (`decodeOpenAIRequest`), and the local API
    /// (`LocalChatRequest`, after the same repair the local responder retries
    /// with). All three must agree.
    private static func reasoning(_ body: Data) throws -> [String?] {
        let inbound = try ProviderLoop.decodeInboundChatRequest(body).request.messages.map(\.reasoningContent)
        let pipeline = try ProviderLoop.decodeOpenAIRequest(body).messages.map(\.reasoningContent)
        var localBody = body
        if (try? JSONDecoder().decode(LocalChatRequest.self, from: body)) == nil {
            localBody = try InboundChatNormalization.normalize(body)
        }
        let local = try JSONDecoder().decode(LocalChatRequest.self, from: localBody)
            .request.messages.map(\.reasoningContent)
        let batch = try JSONDecoder().decode([LocalChatRequest].self, from: Data("[".utf8) + localBody + Data("]".utf8))
        #expect(inbound == pipeline)
        #expect(pipeline == local)
        #expect(batch.map { $0.request.messages.map(\.reasoningContent) } == [local])
        #expect(try PromptPreparationProbe.bodyDecodesAgree(body))
        return inbound
    }

    @Test("an echoed reasoning or thinking field becomes reasoning_content", arguments: [
        (#""reasoning":"R1""#, "R1"),
        (#""thinking":"T1""#, "T1"),
        (#""reasoning_content":null,"reasoning":"R1""#, "R1"),
        (#""thinking":null,"reasoning":"R1""#, "R1"),
        (#""thinking":"T1","reasoning":"R1""#, "T1"),
        (#""reasoning_content":"C1","thinking":"T1","reasoning":"R1""#, "C1"),
        // The native field wins when it is not null, even empty.
        (#""reasoning_content":"","reasoning":"R1""#, ""),
    ])
    func aliasesFollowTransformersPrecedence(fields: String, expected: String) throws {
        #expect(try Self.reasoning(Self.body(fields)) == [nil, expected, nil])
    }

    /// A thought no template can render aliases nothing, and the request
    /// still decodes. The first non-null spelling decides, as in
    /// transformers, so an empty `thinking` is not overridden by `reasoning`.
    @Test("an unrenderable alias is ignored", arguments: [
        #""reasoning":{"effort":"high"}"#,
        #""reasoning":"""#,
        #""thinking":7,"reasoning":"R1""#,
        #""thinking":"","reasoning":"R1""#,
        #""reasoning_details":[{"type":"reasoning.text","text":"D1"}]"#,
    ])
    func unrenderableAliasesAreIgnored(fields: String) throws {
        #expect(try Self.reasoning(Self.body(fields)) == [nil, nil, nil])
    }

    /// Repairs (typeless tool schemas, the `developer` role) rewrite the body
    /// before the decode; the alias stays on its message.
    @Test("repaired bodies keep each alias on its message")
    func repairedBodiesKeepAliases() throws {
        let body = Data(#"""
            {"model":"m","messages":[{"role":"developer","content":"be brief"},{"role":"user","content":"Q1"},
             {"role":"assistant","reasoning":"R1","tool_calls":[{"id":"c1","type":"function","function":{"name":"f","arguments":"{}"}}]},
             {"role":"tool","tool_call_id":"c1","content":"ok"},{"role":"assistant","content":"A1","thinking":"T2"},
             {"role":"user","content":"Q2"}],
             "tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"a":{"enum":["x"]}}}}}]}
            """#.utf8)
        #expect(try Self.reasoning(body) == [nil, nil, "R1", nil, "T2", nil])
    }

    /// The template input is where the alias matters: Qwen 3.8's template
    /// replays every past thought, Qwen 3.5/3.6's and Gemma 4's the turns
    /// after the last user message, all from `reasoning_content`.
    @Test("the template message carries the echoed thought")
    func templateMessageCarriesTheThought() throws {
        let request = try ProviderLoop.decodeOpenAIRequest(Self.body(#""reasoning":"R1""#))
        let messages = request.messages.map { $0.templateMessageDict() }
        #expect(messages[1]["reasoning_content"] as? String == "R1")
        #expect(messages[0]["reasoning_content"] as? String == nil)
        #expect(messages[2]["reasoning_content"] as? String == nil)
    }
}
