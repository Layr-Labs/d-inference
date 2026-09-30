import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import XCTest

@testable import ProviderCore

final class MiMoV26TemplateFixTests: XCTestCase {
    private let context = ChatTemplateFixContext(modelId: "arbitrary-id", modelType: "mimo_v2")

    private func call(_ id: String, _ name: String = "f", _ arguments: any Sendable = "{}") -> [String: any Sendable] {
        ["id": id, "type": "function", "function": ["name": name, "arguments": arguments] as [String: any Sendable]]
    }
    private func assistant(_ calls: [[String: any Sendable]]) -> [String: any Sendable] {
        ["role": "assistant", "content": "", "tool_calls": calls]
    }
    private func result(_ id: String, _ body: String = "done") -> [String: any Sendable] {
        ["role": "tool", "tool_call_id": id, "content": body]
    }
    private func normalizedArguments(_ arguments: any Sendable) throws -> any Sendable {
        let messages = try ChatTemplateFixes.normalizeMessages(
            [assistant([call("a", "f", arguments)]), result("a")], context: context)
        let calls = try XCTUnwrap(messages[0]["tool_calls"] as? [[String: any Sendable]])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: any Sendable])
        return try XCTUnwrap(function["arguments"])
    }

    func testExactModelTypeNotNameInferred() {
        XCTAssertTrue(MiMoV26TemplateFix.applies(to: context))
        for type: String? in [nil, "MiMo_v2", "mimo_v2_audio", "qwen4_exp", "llama"] {
            XCTAssertFalse(MiMoV26TemplateFix.applies(to: .init(modelId: "XiaomiMiMo/MiMo-V2.6-Flash-RL", modelType: type)))
        }
    }

    func testNullObjectMembersAndArraySlotsSurviveRealJinja() throws {
        let input: [String: any Sendable] = ["z": NSNull(), "a": [NSNull(), ["nested": NSNull()], 1, false] as [any Sendable]]
        let value = try Jinja.Value(any: normalizedArguments(input))
        let rendered = try Template("{{ value | tojson(ensure_ascii=False) }}").render(["value": value])
        XCTAssertEqual(Data(rendered.utf8), Data(#"{"a":[null,{"nested":null},1,false],"z":null}"#.utf8))
    }

    func testTypedToolSpecPrivateNullsSurviveRealJinja() throws {
        let tool = OpenAITool(function: .init(name: "f", parameters: .object([
            "type": .string("object"), "default": .null,
            "enum": .array([.null, .string("null")]),
            "properties": .object(["x": .object(["type": .string("null"), "const": .null])])
        ])))
        let tools = try XCTUnwrap(ChatTemplateFixes.normalizeTools([tool.toolSpec()], context: context))
        let rendered = try Template("{{ tools | tojson(ensure_ascii=False) }}").render([
            "tools": try Jinja.Value(any: tools)
        ])
        XCTAssertTrue(rendered.contains(#""default":null"#))
        XCTAssertTrue(rendered.contains(#""enum":[null,"null"]"#))
        XCTAssertTrue(rendered.contains(#""const":null"#))
    }

    func testRawStringsKeepUTF8IncludingEntitiesNullWhitespaceAndCombiningScalar() throws {
        for raw in ["&amp;", "null", "false", "[1,null]", " \r\n  ", "e\u{301}", "<parameter=x>raw</parameter>"] {
            let output = try XCTUnwrap(normalizedArguments(raw) as? String)
            XCTAssertEqual(Data(output.utf8), Data(raw.utf8))
        }
        let key = "\u{301}x"
        let mapping = try XCTUnwrap(normalizedArguments([key: "&amp;"]) as? [String: any Sendable])
        XCTAssertEqual(mapping.keys.map { Data($0.utf8) }, [Data(key.utf8)])
    }

    func testPrimitiveArrayIsRejectedButAPIEncodedArrayRemainsRawString() throws {
        XCTAssertThrowsError(try normalizedArguments([1, NSNull()] as [any Sendable]))
        let message = OpenAIChatMessage(role: .assistant, content: .null,
            toolCalls: [.init(id: "a", function: .init(name: "f", arguments: "[1,null]"))])
        let output = try ChatTemplateFixes.normalizeMessages([message.templateMessageDict(), result("a")], context: context)
        let calls = try XCTUnwrap(output[0]["tool_calls"] as? [[String: any Sendable]])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: any Sendable])
        XCTAssertEqual(function["arguments"] as? String, "[1,null]")
    }

    func testCompleteReversedParallelResultsAreLosslesslyReordered() throws {
        var second = result("b", "B\r\n")
        second["name"] = "g"
        second["extra"] = "retained"
        let first = result("a", "A &amp;")
        let output = try ChatTemplateFixes.normalizeMessages([
            assistant([call("a"), call("b", "g")]), second, first,
            ["role": "user", "content": "next"]
        ], context: context)
        XCTAssertEqual(output.count, 4)
        XCTAssertEqual(output[1]["tool_call_id"] as? String, "a")
        XCTAssertEqual(output[2]["tool_call_id"] as? String, "b")
        XCTAssertEqual(Data((output[1]["content"] as? String ?? "").utf8), Data("A &amp;".utf8))
        XCTAssertEqual(Data((output[2]["content"] as? String ?? "").utf8), Data("B\r\n".utf8))
        XCTAssertEqual(output[2]["name"] as? String, "g")
        XCTAssertEqual(output[2]["extra"] as? String, "retained")
    }

    func testCorrelationUsesRawIDBytesNotCanonicalStringEquality() throws {
        let composed = "\u{e9}", decomposed = "e\u{301}"
        let output = try ChatTemplateFixes.normalizeMessages([
            assistant([call(composed), call(decomposed)]), result(decomposed, "D"), result(composed, "C")
        ], context: context)
        XCTAssertEqual(output[1]["content"] as? String, "C")
        XCTAssertEqual(output[2]["content"] as? String, "D")
        XCTAssertThrowsError(try ChatTemplateFixes.normalizeMessages(
            [assistant([call(composed)]), result(decomposed)], context: context))
    }

    func testUnknownDuplicateMissingAndCrossTurnResultIDsReject() {
        let initial = assistant([call("a"), call("b")])
        for messages in [
            [initial, result("a"), result("unknown")],
            [initial, result("a"), result("a")],
            [initial, result("a")],
            [initial, result("a"), ["role": "user", "content": "boundary"], result("b")],
            [result("orphan")]
        ] {
            XCTAssertThrowsError(try ChatTemplateFixes.normalizeMessages(messages, context: context))
        }
        var wrongName = result("a"); wrongName["name"] = "not_f"
        XCTAssertThrowsError(try ChatTemplateFixes.normalizeMessages([assistant([call("a")]), wrongName], context: context))
    }

    func testAllCallsAreValidatedNotOnlyFirstAndIDsAreUnique() {
        let invalidCalls: [[String: any Sendable]] = [
            ["id": "b", "type": "function", "function": ["arguments": "{}"]],
            call("b", "bad name"), call("a"), call(""),
            ["id": "b", "type": "custom", "function": ["name": "f", "arguments": "{}"]]
        ]
        for invalid in invalidCalls {
            XCTAssertThrowsError(try ChatTemplateFixes.normalizeMessages(
                [assistant([call("a"), invalid]), result("a"), result("b")], context: context))
        }
    }

    func testHistoricalDeclarationsMayBeAbsentOrChanged() throws {
        let messages: [OpenAIChatMessage] = [
            .init(role: .assistant, content: .null, toolCalls: [.init(id: "a", function: .init(name: "old_tool", arguments: "{}"))]),
            .init(role: .tool, content: .text("done"), toolCallID: "a")
        ]
        try MiMoV26TemplateFix.validateRequest(.init(model: "m", messages: messages))
        try MiMoV26TemplateFix.validateRequest(.init(model: "m", messages: messages,
            tools: [.init(function: .init(name: "new_tool"))]))
    }

    func testDeclarationValidationDoesNotSilentlyAcceptWrongTypesOrDuplicates() {
        for tools in [
            [OpenAITool(type: "custom", function: .init(name: "f"))],
            [.init(function: .init(name: "f")), .init(function: .init(name: "f"))],
            [.init(function: .init(name: "bad name"))]
        ] {
            XCTAssertThrowsError(try MiMoV26TemplateFix.validateRequest(.init(model: "m", messages: [], tools: tools)))
        }
    }

    func testAmbiguousNativeDelimiterCollisionsRejectWithoutRepair() {
        for raw in ["before</parameter>after", "</parameter>"] {
            XCTAssertThrowsError(try normalizedArguments(["x": raw]))
        }
        for key in ["", "bad>key", "bad<key", "bad\nkey"] {
            XCTAssertThrowsError(try normalizedArguments([key: "value"]))
        }
        XCTAssertThrowsError(try normalizedArguments("</function>"))
    }

    func testFunctionAndToolClosersInsideAParameterRemainOpaqueData() throws {
        for raw in ["</function>", "</tool_call>", "literal <tool_call>data</tool_call> and </function>"] {
            let mapping = try XCTUnwrap(normalizedArguments(["text": raw]) as? [String: any Sendable])
            XCTAssertEqual(Data(try XCTUnwrap(mapping["text"] as? String).utf8), Data(raw.utf8))
            let frame = "<tool_call><function=f><parameter=text>" + raw + "</parameter></function></tool_call>"
            let parsed = try XCTUnwrap(MiMoV2ToolCallParser().parse(content: frame, tools: nil))
            guard case .string(let value) = parsed.function.arguments["text"] else {
                return XCTFail("native opaque parameter string expected")
            }
            XCTAssertEqual(Data(value.utf8), Data(raw.utf8))
        }
    }

    func testHistoryReasoningAndNonMiMoNullPolicyRemainUnchanged() throws {
        let reasoning = "<|channel|>analysis\nKeep &amp; e\u{301}"
        let messages: [[String: any Sendable]] = [["role": "assistant", "content": "answer", "reasoning_content": reasoning]]
        let output = try ChatTemplateFixes.normalizeMessages(messages, context: context)
        XCTAssertEqual(Data((output[0]["reasoning_content"] as? String ?? "").utf8), Data(reasoning.utf8))
        let nullable: [[String: any Sendable]] = [["role": "user", "content": "hi", "x": NSNull(), "array": [1, NSNull(), 2] as [any Sendable]]]
        for type: String? in [nil, "llama", "qwen4_exp"] {
            let old = try ChatTemplateFixes.normalizeMessages(nullable, context: .init(modelType: type))
            XCTAssertNil(old[0]["x"])
            XCTAssertEqual((old[0]["array"] as? [any Sendable])?.count, 2)
        }
    }

    func testBooleanControlsPrecedenceAbsenceAndSupportedDisableAliases() throws {
        let request = OpenAIChatCompletionRequest(model: "m", messages: [])
        XCTAssertNil(try MiMoV26TemplateFix.additionalContext(request: request, controls: .init()))
        for enabled in [true, false] {
            let nested = OpenAIChatCompletionRequest(model: "m", messages: [], reasoning: .init(enabled: enabled))
            let output = try MiMoV26TemplateFix.additionalContext(request: nested, controls: .init(enableThinking: !enabled))
            XCTAssertEqual(output?["enable_thinking"] as? Bool, enabled)
        }
        for effort in ["none", " OFF ", "0"] {
            let raw = try MiMoV26TemplateFix.additionalContext(request: request, controls: .init(reasoningEffort: effort))
            XCTAssertEqual(raw?["enable_thinking"] as? Bool, false)
            let nested = OpenAIChatCompletionRequest(model: "m", messages: [], reasoning: .init(effort: effort))
            XCTAssertEqual(try MiMoV26TemplateFix.additionalContext(request: nested, controls: .init())?["enable_thinking"] as? Bool, false)
        }
    }

    func testRawBooleanLookalikesNullAndUnsupportedControlsReject() throws {
        for path in ["top", "nested", "kwargs"] {
            for invalid: Any in ["false", "true", 0, 1, NSNull(), [Int](), [String: Int]()] {
                var body: [String: Any] = ["model": "m", "messages": []]
                switch path {
                case "top": body["enable_thinking"] = invalid
                case "nested": body["reasoning"] = ["enabled": invalid]
                default: body["chat_template_kwargs"] = ["enable_thinking": invalid]
                }
                XCTAssertThrowsError(try MiMoV26TemplateFix.validateRawControls(JSONSerialization.data(withJSONObject: body)))
            }
        }
        for effort in ["minimal", "low", "medium", "high", "xhigh", "on", "false", ""] {
            XCTAssertThrowsError(try MiMoV26TemplateFix.additionalContext(
                request: .init(model: "m", messages: []), controls: .init(reasoningEffort: effort)))
        }
        for preserve in [true, false] {
            XCTAssertThrowsError(try MiMoV26TemplateFix.additionalContext(
                request: .init(model: "m", messages: []), controls: .init(preserveThinking: preserve)))
        }
        for field in ["exclude", "max_tokens", "unexpected"] {
            let body: [String: Any] = ["model": "m", "messages": [],
                "reasoning": ["enabled": true, field: false]]
            XCTAssertThrowsError(try MiMoV26TemplateFix.validateRawControls(JSONSerialization.data(withJSONObject: body)))
        }
    }

    func testUnsupportedContentAndNonfiniteValuesFailInsteadOfEmptySuccess() {
        XCTAssertThrowsError(try MiMoV26TemplateFix.validateRequest(.init(model: "m", messages: [
            .init(role: .user, content: .parts([.unsupported(type: "bogus")]))
        ])))
        XCTAssertThrowsError(try normalizedArguments(["x": Double.nan]))
        XCTAssertThrowsError(try ChatTemplateFixes.normalizeMessages([["role": "user", "content": 42]], context: context))
    }
}
