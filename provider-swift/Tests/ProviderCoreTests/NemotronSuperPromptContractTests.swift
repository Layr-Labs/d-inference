import Foundation
import Jinja
import MLXLMServer
import XCTest
@testable import ProviderCore

final class NemotronSuperPromptContractTests: XCTestCase {
    private static func templateBytes() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: superImagePinnedTemplateBase64, options: .ignoreUnknownCharacters))
    }

    /// One user message's reference prompt text, thinking on.
    private static func userPrompt(_ content: String) -> String {
        "<|im_start|>system\n<|im_end|>\n<|im_start|>user\n" + content
            + "<|im_end|>\n<|im_start|>assistant\n<think>\n"
    }

    /// Rendering merges each run of adjacent text parts; the pinned template
    /// over one value per part renders the same tokens, including empty
    /// parts, text around images and a placeholder split across parts.
    func testMergedTextPartsRenderTheBytesOfTheSplitParts() throws {
        let template = try Self.templateBytes()
        let image = "data:image/png;base64,AA=="
        let cases: [[OpenAIContentPart]] = [
            [.text("a"), .text(""), .text("b\n"), .text("")],
            [.text(""), .text("")],
            [.text("x"), .text(""), .imageURL(image), .text(""), .text("y"), .text("z"), .imageURL(image), .text("")],
            [.imageURL(image), .text(""), .imageURL(image)],
            [.text("Look:"), .text("\n"), .imageURL(image), .text("a "), .text("<ima"), .text("ge>")],
        ]
        let tokenizer = SuperVideoTextTokenizer()
        let chatTemplate = try NemotronSuperPromptContract.verifiedTemplate(template)
        var context = NemotronSuperPromptContract.additionalContext(.init())
        context["add_generation_prompt"] = true
        for parts in cases {
            let messages = [OpenAIChatMessage(role: .system, content: .parts(parts)),
                            OpenAIChatMessage(role: .user, content: .parts(parts))]
            let merged = try NemotronSuperPromptContract.render(messages: messages, body: Data("{}".utf8),
                declared: nil, controls: .init(), templateBytes: template, tokenizer: tokenizer)
            let split: [[String: any Sendable]] = messages.map { message in
                ["role": message.role.rawValue, "content": Value.array(parts.map { part -> Value in
                    switch part {
                    case .text(let text): .object(["type": "text", "text": .string(text)])
                    case .imageURL(let uri): .object(["type": "image_url", "image_url": .object(["url": .string(uri)])])
                    default: .null
                    }
                })]
            }
            XCTAssertEqual(merged, try tokenizer.applyChatTemplate(messages: split, chatTemplate: chatTemplate,
                                                                   tools: nil, additionalContext: context), "\(parts)")
        }
        let text = try NemotronSuperPromptContract.render(messages: [OpenAIChatMessage(role: .user,
            content: .parts([.text("a"), .text(""), .text("b\n"), .text("")]))], body: Data("{}".utf8),
            declared: nil, controls: .init(), templateBytes: template, tokenizer: tokenizer)
        XCTAssertEqual(SuperVideoTextTokenizer.text(text), Self.userPrompt("ab\n"))
    }

    /// The separator before a media part follows Python's `endswith`, which
    /// compares code points: text ending in "\r\n" ends with "\n" and takes no
    /// separator (swift-jinja's own `endswith` compares Characters).
    func testSeparatorBeforeAnImageFollowsPythonEndsWith() throws {
        let template = try Self.templateBytes()
        XCTAssertFalse(try NemotronSuperPromptContract.verifiedTemplate(template).contains(".endswith("))
        let image = OpenAIContentPart.imageURL("data:image/png;base64,AA==")
        let tokenizer = SuperVideoTextTokenizer()
        for (text, content) in [("Look:\r\n", "Look:\r\n<image>"), ("Look:\n", "Look:\n<image>"),
                                ("Look:", "Look:\n<image>"), ("Look:\r", "Look:\r\n<image>")] {
            let tokens = try NemotronSuperPromptContract.render(
                messages: [OpenAIChatMessage(role: .user, content: .parts([.text(text), image]))],
                body: Data("{}".utf8), declared: nil, controls: .init(), templateBytes: template, tokenizer: tokenizer)
            XCTAssertEqual(tokens, tokenizer.encode(text: Self.userPrompt(content), addSpecialTokens: false),
                           text.debugDescription)
        }
    }

    /// A request carries at most `maximumContentParts` parts: a 100,000-part
    /// body is refused when the plan is built, before any render; one at the
    /// bound renders its merged text.
    func testContentPartsAreBoundedBeforeRendering() throws {
        func body(parts: Int) -> Data {
            Data(("{\"model\":\"" + NemotronSuperLocalBinding.modelID + #"","messages":[{"role":"user","content":["#
                + Array(repeating: #"{"type":"text","text":"a"}"#, count: parts).joined(separator: ",")
                + "]}]}").utf8)
        }
        XCTAssertThrowsError(try NemotronSuperRequestPlan(body: body(parts: 100_000))) {
            XCTAssertEqual($0 as? NemotronSuperRequestPlan.Failure, .tooManyContentParts)
        }
        let bounded = body(parts: NemotronSuperRequestPlan.maximumContentParts)
        let tokens = try NemotronSuperRequestPlan(body: bounded).textPromptTokens(body: bounded,
            templateBytes: Self.templateBytes(), tokenizer: SuperVideoTextTokenizer())
        XCTAssertEqual(SuperVideoTextTokenizer.text(tokens),
                       Self.userPrompt(String(repeating: "a", count: NemotronSuperRequestPlan.maximumContentParts)))
    }

    func testOfficialDefaultsAndMediumEffort() throws {
        let defaults = try NemotronSuperPromptContract.additionalContext(body: Data("{}".utf8))
        XCTAssertEqual(defaults["enable_thinking"] as? Bool, true)
        XCTAssertEqual(defaults["medium_effort"] as? Bool, false)
        XCTAssertEqual(defaults["truncate_history_thinking"] as? Bool, true)
        XCTAssertEqual(try NemotronSuperPromptContract.controls(body: Data("{}".utf8)), .init())
        let medium = try NemotronSuperPromptContract.additionalContext(body: Data(
            #"{"reasoning_effort":"medium","chat_template_kwargs":{"truncate_history_thinking":false}}"#.utf8))
        XCTAssertEqual(medium["medium_effort"] as? Bool, true)
        XCTAssertEqual(medium["truncate_history_thinking"] as? Bool, false)
        let forced = try NemotronSuperPromptContract.controls(body: Data(
            #"{"chat_template_kwargs":{"enable_thinking":true,"force_nonempty_content":true}}"#.utf8))
        XCTAssertEqual(forced, .init(enableThinking: true, mediumEffort: false,
                                     truncateHistoryThinking: true, forceNonemptyContent: true))
        let off = try NemotronSuperPromptContract.controls(body: Data(#"{"enable_thinking":false}"#.utf8))
        XCTAssertFalse(off.enableThinking)
    }

    func testStrictUnsupportedAndConflictingControls() {
        for body in [#"{"reasoning_effort":"off","enable_thinking":true}"#,
                     #"{"reasoning_effort":"medium","medium_effort":false}"#,
                     #"{"reasoning_effort":"high","reasoning":{"effort":"medium"}}"#,
                     #"{"enable_thinking":true,"reasoning":{"enabled":false}}"#,#"{"enable_thinking":"false"}"#,
                     #"{"reasoning_effort":"low"}"#,
                     #"{"preserve_thinking":true}"#,
                     #"{"enable_thinking":false,"medium_effort":true}"#,
                     #"{"enable_thinking":false,"chat_template_kwargs":{"enable_thinking":true}}"#,
                     #"{"force_nonempty_content":false,"chat_template_kwargs":{"force_nonempty_content":true}}"#,
                     #"{"chat_template_kwargs":{"force_nonempty_content":"yes"}}"#] {
            XCTAssertThrowsError(try NemotronSuperPromptContract.additionalContext(body: Data(body.utf8)), body)
        }
        XCTAssertThrowsError(try NemotronSuperPromptContract.verifiedTemplate(Data("altered".utf8)))
    }

    /// Fields the template cannot honor are refused instead of dropped; their
    /// default spellings still parse to the same controls.
    func testUnhonoredReasoningFieldsAreRefused() throws {
        for body in [#"{"chat_template_kwargs":{"reasoning_effort":"low"}}"#,
                     #"{"chat_template_kwargs":{"preserve_thinking":true}}"#,
                     #"{"chat_template_kwargs":{"unknown":null}}"#,
                     #"{"reasoning":{"max_tokens":64}}"#,
                     #"{"reasoning":{"exclude":true}}"#,
                     #"{"reasoning":{"exclude":0}}"#,
                     #"{"reasoning":{"exclude":"false"}}"#,
                     #"{"reasoning":{"summary":"verbose"}}"#,
                     #"{"reasoning":{"summary":true}}"#,
                     #"{"reasoning":{"effort":"medium","generate_summary":"auto"}}"#] {
            XCTAssertThrowsError(try NemotronSuperPromptContract.controls(body: Data(body.utf8)), body) { error in
                guard case .unsupportedControl = error as? NemotronSuperPromptContract.Failure else {
                    return XCTFail("\(body): \(error)")
                }
            }
        }
        for body in [#"{"reasoning":"on"}"#, #"{"chat_template_kwargs":[]}"#] {
            XCTAssertThrowsError(try NemotronSuperPromptContract.controls(body: Data(body.utf8)), body)
        }
        let plain = try NemotronSuperPromptContract.controls(body: Data("{}".utf8))
        for body in [#"{"reasoning":{"exclude":false}}"#, #"{"reasoning":{"max_tokens":null,"exclude":null}}"#,
                     #"{"reasoning":null,"chat_template_kwargs":null}"#,
                     #"{"reasoning":{"summary":"auto"}}"#, #"{"reasoning":{"summary":"detailed"}}"#,
                     #"{"chat_template_kwargs":{"thinking":true}}"#,
                     #"{"chat_template_kwargs":{"truncate_history_thinking":true,"force_nonempty_content":false}}"#] {
            XCTAssertEqual(try NemotronSuperPromptContract.controls(body: Data(body.utf8)), plain, body)
        }
        let medium = try NemotronSuperPromptContract.controls(body: Data(
            #"{"reasoning":{"effort":"medium","exclude":false,"summary":"concise"},"chat_template_kwargs":{"enable_thinking":true,"medium_effort":true}}"#.utf8))
        XCTAssertEqual(medium, .init(enableThinking: true, mediumEffort: true,
                                     truncateHistoryThinking: true, forceNonemptyContent: false))
    }

    /// OpenRouter's `chat_template_kwargs.thinking` is the template's
    /// `enable_thinking`, under the same conflict rules as every spelling.
    func testOpenRouterThinkingSwitchesTheTemplate() throws {
        let off = try NemotronSuperPromptContract.controls(body: Data(#"{"chat_template_kwargs":{"thinking":false}}"#.utf8))
        XCTAssertFalse(off.enableThinking)
        let medium = try NemotronSuperPromptContract.controls(body: Data(
            #"{"reasoning_effort":"medium","chat_template_kwargs":{"thinking":true}}"#.utf8))
        XCTAssertEqual(medium, .init(enableThinking: true, mediumEffort: true,
                                     truncateHistoryThinking: true, forceNonemptyContent: false))
        for body in [#"{"reasoning_effort":"none","chat_template_kwargs":{"thinking":true}}"#,
                     #"{"reasoning_effort":"high","chat_template_kwargs":{"thinking":false}}"#,
                     #"{"enable_thinking":true,"chat_template_kwargs":{"thinking":false}}"#,
                     #"{"chat_template_kwargs":{"enable_thinking":false,"thinking":true}}"#,
                     #"{"chat_template_kwargs":{"thinking":"no"}}"#] {
            XCTAssertThrowsError(try NemotronSuperPromptContract.controls(body: Data(body.utf8)), body)
        }
    }

    func testImageOrderAndOrderedToolArguments() throws {
        let body = Data(#"{"model":"local","messages":[{"role":"user","content":[{"type":"text","text":"before"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}},{"type":"text","text":"after"}]},{"role":"assistant","content":null,"tool_calls":[{"id":"c","type":"function","function":{"name":"f","arguments":"{\"z\":1,\"a\":[true,null]}"}}]}]}"#.utf8)
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let messages = try NemotronSuperPromptContract.messages(request.messages)
        guard case .array(let parts)? = messages[0]["content"] as? Value else { return XCTFail("parts") }
        XCTAssertEqual(parts.compactMap { part -> String? in
            guard case .object(let fields) = part, case .string(let type)? = fields["type"] else { return nil }
            return type
        }, ["text", "image_url", "text"])
        XCTAssertEqual(messages[1]["content"] as? Value, .null)
        guard case .array(let calls)? = messages[1]["tool_calls"] as? Value,
            case .object(let call)? = calls.first, case .object(let function)? = call["function"],
            case .object(let arguments)? = function["arguments"]
        else { return XCTFail("tool call") }
        XCTAssertEqual(Array(arguments.keys), ["z", "a"])
        XCTAssertEqual(arguments["a"], .array([.boolean(true), .null]))
    }

    /// The template iterates tool-call arguments with `items`, which raises in
    /// the reference for anything but a mapping; such arguments are refused
    /// instead of rendering an empty call.
    func testNonObjectToolCallArgumentsAreRefused() throws {
        func history(_ arguments: String) -> [OpenAIChatMessage] {
            [OpenAIChatMessage(role: .user, content: .text("q")),
             OpenAIChatMessage(role: .assistant, content: .null, toolCalls: [
                OpenAIToolCall(id: "c", function: .init(name: "f", arguments: arguments))])]
        }
        for arguments in ["[1]", "5", "null", #""s""#, "true", "{"] {
            XCTAssertThrowsError(try NemotronSuperPromptContract.messages(history(arguments)), arguments) {
                guard case .invalidToolArguments = $0 as? NemotronSuperPromptContract.Failure else {
                    return XCTFail("\(arguments): \($0)")
                }
            }
        }
        for arguments in ["", "{}", #"{"a":[1]}"#] {
            XCTAssertNoThrow(try NemotronSuperPromptContract.messages(history(arguments)), arguments)
        }
    }

    func testImagePlaceholderExpansionMatchesProcessor() throws {
        XCTAssertEqual(try NemotronSuperPromptContract.expandImagePlaceholders(
            [1, 18, 2, 18, 3], featureCounts: [2, 1], contextLength: 64),
            [1, 19, 18, 18, 20, 2, 19, 18, 20, 3])
        XCTAssertThrowsError(try NemotronSuperPromptContract.expandImagePlaceholders(
            [1, 18, 2], featureCounts: [2, 1], contextLength: 64))
        XCTAssertThrowsError(try NemotronSuperPromptContract.expandImagePlaceholders(
            [1, 18, 2], featureCounts: [0], contextLength: 64))
        XCTAssertThrowsError(try NemotronSuperPromptContract.expandImagePlaceholders(
            [1, 18, 2], featureCounts: [3], contextLength: 6))
        XCTAssertEqual(try NemotronSuperPromptContract.expandImagePlaceholders(
            [1, 18, 2], featureCounts: [3], contextLength: 7).count, 7)
    }

    func testOrderedJSONKeepsPythonDecodingSemantics() throws {
        let value = try NemotronSuperOrderedJSON.parse(
            #" {"b": 1, "a": {"y": 2.5, "x": -0}, "b": "last", "e": 1E2, "s": "\u00e9\ud83d\ude00\n\/"} "#)
        guard case .object(let root) = value, case .object(let nested)? = root["a"] else { return XCTFail() }
        XCTAssertEqual(Array(root.keys), ["b", "a", "e", "s"])
        XCTAssertEqual(root["b"], .string("last"))
        XCTAssertEqual(Array(nested.keys), ["y", "x"])
        XCTAssertEqual(nested["x"], .int(0))
        XCTAssertEqual(root["e"], .double(100))
        XCTAssertEqual(root["s"], .string("é😀\n/"))
        for invalid in ["[1,]", "{\"a\":NaN}", "\"\\ud83d\"", "01", "[1] x", "\"\u{01}\"", "{'a':1}"] {
            XCTAssertThrowsError(try NemotronSuperOrderedJSON.parse(invalid), invalid)
        }
        XCTAssertThrowsError(try NemotronSuperOrderedJSON.parse("12345678901234567890")) {
            XCTAssertEqual($0 as? NemotronSuperOrderedJSON.Failure, .limit)
        }
        let deep = String(repeating: "[", count: 66) + String(repeating: "]", count: 66)
        XCTAssertThrowsError(try NemotronSuperOrderedJSON.parse(deep))
    }

    /// Only the requested top-level member is parsed, and held to the limits;
    /// the others need only well-formed extents. A repeated key keeps its last
    /// value, as in Python.
    func testOrderedJSONMemberParsesOnlyItsKey() throws {
        func tools(_ body: String) throws -> Value? {
            try NemotronSuperOrderedJSON.member("tools", of: Data(body.utf8))
        }
        let deep = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        XCTAssertEqual(try tools(#"{"seed": 9223372036854775808, "deep": "# + deep
            + #", "tools": [1], "s": "}\"[\\", "e": 1e999, "tools": [{"b": 1, "a": null}]}"#),
            .array([.object(["b": .int(1), "a": .null])]))
        XCTAssertNil(try tools(#"{"seed": 18446744073709551616}"#))
        XCTAssertThrowsError(try tools(#"{"tools": [12345678901234567890]}"#)) {
            XCTAssertEqual($0 as? NemotronSuperOrderedJSON.Failure, .limit)
        }
        for invalid in ["[]", #"{"a": }"#, #"{"a": [1}"#, #"{"a": "x}"#, #"{"a": 1] }"#, #"{"a": 1} x"#,
                        #"{"a": 1"#, "{\"a\": \"\u{01}\"}"] {
            XCTAssertThrowsError(try tools(invalid), invalid)
        }
    }

    /// The body is parsed strictly only for `tools`: a `seed` the SDK decodes
    /// as UInt64 but beyond Int64 no longer refuses a tool request.
    func testSeedBeyondInt64DoesNotRefuseATooledRequest() throws {
        let body = Data(("{\"model\":\"" + NemotronSuperLocalBinding.modelID
            + #"","seed":9223372036854775808,"messages":[{"role":"user","content":"q"}],"#
            + #""tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","#
            + #""properties":{"b":{"type":"string"},"a":{"type":"integer"}}}}}]}"#).utf8)
        let plan = try NemotronSuperRequestPlan(body: body)
        XCTAssertEqual(plan.request.seed, 1 << 63)
        let prompt = SuperVideoTextTokenizer.text(try plan.textPromptTokens(body: body,
            templateBytes: Self.templateBytes(), tokenizer: SuperVideoTextTokenizer()))
        XCTAssertTrue(prompt.contains("<name>b</name>\n<type>string</type>\n</parameter>\n<parameter>\n<name>a</name>"),
                      prompt)
    }

    /// String bytes decode exactly, as Python's `json.loads` reads them: a
    /// U+FEFF that starts a raw segment survives, and invalid UTF-8 (a stray
    /// byte, an encoded surrogate, an overlong or truncated sequence) is refused.
    func testOrderedJSONKeepsByteOrderMarksAndRefusesInvalidUTF8() throws {
        XCTAssertEqual(try NemotronSuperOrderedJSON.parse("{\"\u{FEFF}k\": \"\u{FEFF}v\\n\u{FEFF}w\"}"),
                       .object(["\u{FEFF}k": .string("\u{FEFF}v\n\u{FEFF}w")]))
        for bytes: [UInt8] in [[0x22, 0xFF, 0x22], [0x22, 0xED, 0xA0, 0x80, 0x22], [0x22, 0xC0, 0xAF, 0x22],
                               [0x22, 0xE2, 0x82, 0x22]] {
            XCTAssertThrowsError(try NemotronSuperOrderedJSON.parse(Data(bytes)), "\(bytes)") {
                XCTAssertEqual($0 as? NemotronSuperOrderedJSON.Failure, .invalid)
            }
        }
    }

    /// Expected strings were produced by CPython 3.14 `repr`, `str`,
    /// `json.dumps(ensure_ascii=False)` and `str.strip`.
    func testTemplateFiltersMatchPython() throws {
        let floats: [(Double, String)] = [
            (1, "1.0"), (0.25, "0.25"), (1e16, "1e+16"), (1e15, "1000000000000000.0"),
            (1e-05, "1e-05"), (0.0001, "0.0001"), (-0.0, "-0.0"), (123456789.123, "123456789.123"),
            (1.5e300, "1.5e+300"), (5e-324, "5e-324"), (0.1 + 0.2, "0.30000000000000004"),
            (2.5e-05, "2.5e-05"), (100, "100.0"), (1234567890123456789, "1.2345678901234568e+18"),
        ]
        for (number, expected) in floats {
            XCTAssertEqual(NemotronSuperTemplateFilters.pythonFloat(number, json: false), expected)
            XCTAssertEqual(NemotronSuperTemplateFilters.pythonFloat(number, json: true), expected)
        }
        XCTAssertEqual(NemotronSuperTemplateFilters.pythonFloat(.infinity, json: true), "Infinity")
        let reprs: [(String, String)] = [
            ("it's", #""it's""#), ("a'b\"c", #"'a\'b"c'"#), ("\n\t\r", #"'\n\t\r'"#),
            ("\u{7f}", #"'\x7f'"#), ("é", "'é'"), ("\u{a0}", #"'\xa0'"#), ("\u{200b}", #"'\u200b'"#),
            ("\u{1f}", #"'\x1f'"#), ("\\", #"'\\'"#), ("😀", "'😀'"), ("\u{301}", "'\u{301}'"),
        ]
        for (text, expected) in reprs {
            XCTAssertEqual(NemotronSuperTemplateFilters.pythonRepr(text), expected, text)
        }
        let nested = Value.array([.boolean(true), .null, .double(1.5), .string("x"),
                                  .object(["k": .array([.int(1)])])])
        XCTAssertEqual(try NemotronSuperTemplateFilters.pythonString(nested),
                       "[True, None, 1.5, 'x', {'k': [1]}]")
        XCTAssertEqual(try NemotronSuperTemplateFilters.pythonString(.boolean(false)), "False")
        XCTAssertEqual(try NemotronSuperTemplateFilters.pythonString(.undefined), "")
        var json = ""
        try NemotronSuperTemplateFilters.writeJSON(.object(["a": .string("é\u{1f}\"\u{7f}"),
            "b": .array([.boolean(false), .null, .double(0.5)])]), to: &json, depth: 0)
        XCTAssertEqual(json, #"{"a": "é\u001f\""# + "\u{7f}" + #"", "b": [false, null, 0.5]}"#)
        XCTAssertEqual(NemotronSuperTemplateFilters.pythonStrip(" \u{3000}\u{a0}\u{1f}hi\u{200b} \u{1c}"),
                       "hi\u{200b}")
        XCTAssertEqual(NemotronSuperTemplateFilters.bind(template: "{{ x | string }}{{ y|string|trim }}{% if x is string %}"),
            "{{ x | __nemotron_super_string }}{{ y|__nemotron_super_string|trim }}{% if x is string %}")
    }
}
