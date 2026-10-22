// Copyright © 2026 Eigen Labs Inc.

import CryptoKit
import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Flint pinned-template history replay")
struct FlintTemplateReplayTests {
    private static let historicalArguments = #"""
        {
            "nullable": null,
            "positions": [null, 1, null, 2, null],
            "nested": {"leaf": null, "items": [1, null, 2]},
            "raw": " \t[null, 雪]\n "
        }
        """#

    private static let schema = #"""
        {
            "type": "object",
            "default": null,
            "properties": {
                "nullable": {
                    "type": ["string", "null"],
                    "default": null,
                    "enum": [null, "null", "雪"]
                },
                "positions": {
                    "type": "array",
                    "items": {"type": ["integer", "null"]},
                    "default": [1, null, 2]
                },
                "nested": {"type": "object", "default": {"leaf": null}},
                "raw": {"type": "string"}
            }
        }
        """#

    private func json(_ source: String) throws -> MLXLMCommon.JSONValue {
        try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(source.utf8))
    }

    private func request() throws -> OpenAIChatCompletionRequest {
        let typed = OpenAIChatCompletionRequest(
            model: "RecursiveSI/flint-int4",
            messages: [
                .init(role: .user, content: .text("Record these values.")),
                .init(
                    role: .assistant, content: .null,
                    toolCalls: [
                        .init(
                            id: "call_capture",
                            function: .init(name: "capture", arguments: Self.historicalArguments))
                    ]),
                .init(role: .tool, content: .text("Recorded."), toolCallID: "call_capture"),
                .init(role: .user, content: .text("Continue.")),
            ],
            tools: [.init(function: .init(name: "capture", parameters: try json(Self.schema)))],
            toolChoice: .mode(.auto))
        // Exercise the same Codable DTO used at the HTTP boundary, including
        // JSON-string arguments and typed JSONValue.null schema members.
        return try JSONDecoder().decode(
            OpenAIChatCompletionRequest.self, from: JSONEncoder().encode(typed))
    }

    private func fixture(_ name: String, extension fileExtension: String? = nil) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: fileExtension, subdirectory: "Fixtures/Flint"))
        return try Data(contentsOf: url)
    }

    func render(
        _ request: OpenAIChatCompletionRequest, modelType: String?,
        controls: ChatTemplateControls = .init()
    ) throws -> String {
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        let input = try ProviderPromptContractPipeline.normalizedInput(
            prepared: prepared, request: request, modelType: modelType,
            templateControls: controls)
        var context: [String: Jinja.Value] = [
            "messages": try Jinja.Value(any: input.messages),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools = input.tools { context["tools"] = try Jinja.Value(any: tools) }
        for (key, value) in input.additionalContext ?? [:] {
            context[key] = try Jinja.Value(any: value)
        }
        let bytes = try fixture("chat_template", extension: "jinja")
        let source = try #require(String(data: bytes, encoding: .utf8))
        let template = try Template(
            source, with: .init(lstripBlocks: true, trimBlocks: true))
        return try template.render(context)
    }

    private func between(_ start: String, _ end: String, in text: String) throws -> String {
        let startRange = try #require(text.range(of: start))
        let tail = text[startRange.upperBound...]
        let endRange = try #require(tail.range(of: end))
        return String(tail[..<endRange.lowerBound])
    }

    private func argument(_ key: String, in frame: String) throws -> String {
        try between("<arg_key>\(key)</arg_key><arg_value>", "</arg_value>", in: frame)
    }

    private func renderedFunction(in prompt: String) throws -> MLXLMCommon.JSONValue {
        // The prose also mentions <tools></tools>. The last opening marker
        // identifies the declaration; Jinja whitespace trimming can put JSON
        // immediately after it. Decode JSON instead of relying on key order.
        let opening = try #require(prompt.range(of: "<tools>", options: .backwards))
        let tail = String(prompt[opening.upperBound...])
        let closing = try #require(tail.range(of: "</tools>"))
        return try json(String(tail[..<closing.lowerBound]))
    }

    @Test func fixtureMatchesPinnedReleaseBytes() throws {
        let hashes = [
            (try fixture("chat_template", extension: "jinja"),
             "7940f4ffa3275c36caa4a582f845aaad79da11018b3961e8fbcad6ae29733466"),
            (try fixture("LICENSE"),
             "43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1"),
        ]
        for (bytes, expected) in hashes {
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            #expect(actual == expected)
        }
    }

    @Test func historicalNullKeysAndArrayPositionsSurviveProductionReplay() throws {
        let prompt = try render(request(), modelType: "flint")
        let frame = try between("<tool_call>capture", "</tool_call>", in: prompt)
        #expect(frame.components(separatedBy: "<arg_key>").count - 1 == 4)
        #expect(try argument("nullable", in: frame) == "null")
        #expect(try json(argument("positions", in: frame)) == json("[null,1,null,2,null]"))
        #expect(try json(argument("nested", in: frame)) == json(#"{"leaf":null,"items":[1,null,2]}"#))
        #expect(try Data(argument("raw", in: frame).utf8) == Data(" \t[null, 雪]\n ".utf8))
        #expect(prompt.contains("<|observation|><tool_response>Recorded.</tool_response>"))
        #expect(prompt.hasSuffix("<|user|>Continue.<|assistant|>"))
    }

    @Test func typedToolSpecNullSentinelsSurviveSchemaRendering() throws {
        let request = try self.request()
        let tool = try #require(request.tools?.first)
        let function = try #require(tool.toolSpec()["function"] as? [String: any Sendable])
        let parameters = try #require(function["parameters"] as? [String: any Sendable])
        let null = try #require(parameters["default"])
        // Use the SDK's real private sentinel, not a test-only lookalike or NSNull.
        let typeName = String(reflecting: type(of: null))
        #expect(typeName.hasPrefix("MLXLMServer."))
        #expect(typeName.split(separator: ".").last == "JSONNull")
        #expect(!(null is NSNull))

        let prompt = try render(request, modelType: "flint")
        #expect(try renderedFunction(in: prompt) == .object([
            "name": .string("capture"), "parameters": json(Self.schema),
        ]))
    }

    /// Recursive documents that Flint always chooses whether to reason. The
    /// accepted controls reach the production context but not the prompt.
    @Test func acceptedReasoningControlsDoNotChangeThePrompt() throws {
        let baseline = try render(request(), modelType: "flint")
        var body = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request())) as? [String: Any])
        for controls: [String: Any] in [
            ["reasoning": ["effort": "high", "enabled": false, "exclude": true], "include_reasoning": false],
            ["reasoning_effort": "none", "enable_thinking": false],
            ["chat_template_kwargs": ["enable_thinking": true, "thinking": true]],
            ["reasoning": ["effort": "minimal", "enabled": true]],
        ] {
            body.merge(controls) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: body)
            // The same body decodes, without the local endpoint's render date.
            let typed = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: data)
            let templateControls = try JSONDecoder().decode(ChatTemplateControls.self, from: data)
            #expect(try render(typed, modelType: "flint", controls: templateControls) == baseline)
            body = body.filter { !controls.keys.contains($0.key) }
        }
    }

    @Test(arguments: [nil, "llama", "Flint", " flint ", "flint_mtp"] as [String?])
    func otherArchitecturesKeepGenericNullSanitization(modelType: String?) throws {
        // Keep the Flint-looking request.model fixed to prove selection is by
        // exact architecture. The Flint fixture is only a render probe here;
        // this does not assert which template another model serves.
        let prompt = try render(request(), modelType: modelType)
        let frame = try between("<tool_call>capture", "</tool_call>", in: prompt)
        #expect(frame.components(separatedBy: "<arg_key>").count - 1 == 3)
        #expect(!frame.contains("<arg_key>nullable</arg_key>"))
        #expect(try json(argument("positions", in: frame)) == json("[1,2]"))
        #expect(try json(argument("nested", in: frame)) == json(#"{"items":[1,2]}"#))
        #expect(try Data(argument("raw", in: frame).utf8) == Data(" \t[null, 雪]\n ".utf8))
        let sanitizedSchema = try json(#"""
            {
                "type": "object",
                "properties": {
                    "nullable": {"type": ["string", "null"], "enum": ["null", "雪"]},
                    "positions": {
                        "type": "array", "items": {"type": ["integer", "null"]}, "default": [1, 2]
                    },
                    "nested": {"type": "object", "default": {}},
                    "raw": {"type": "string"}
                }
            }
            """#)
        #expect(try renderedFunction(in: prompt) == .object([
            "name": .string("capture"), "parameters": sanitizedSchema,
        ]))
    }
}
