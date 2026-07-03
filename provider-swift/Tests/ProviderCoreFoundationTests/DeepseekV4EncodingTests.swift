import XCTest

@testable import ProviderCoreFoundation

/// Golden-fixture and behavioral tests for the DeepSeek-V4 DSML prompt
/// encoder (`DeepseekV4Encoding`), a native Swift port of
/// `encode_messages`/`render_message` in the reference `encoding_dsv4.py`.
///
/// Fixtures 1-4 are the official golden vectors mirrored verbatim under
/// `Fixtures/dsv4/` (test_input_N.json / test_output_N.txt).
///
/// KNOWN, DOCUMENTED DEVIATION: `test_output_1.txt` and `test_output_3.txt`
/// embed a `## Tools` system-prompt block whose per-tool JSON schema was
/// serialized by Python from a source dict that preserves the ORIGINAL
/// wire JSON's key insertion order. By the time an equivalent tool schema
/// reaches this encoder over the OpenAI wire (`OpenAITool.function.parameters`
/// → `JSONValue.object([String: JSONValue])`), that order is already
/// unrecoverable — see `DeepseekV4JSON`'s doc comment. This encoder instead
/// sorts schema object keys alphabetically for cross-run determinism.
/// `assertDeepseekV4PromptMatches` below therefore verifies the schema
/// section by PARSED (semantic) equality and everything else — turn
/// structure, DSML tool-call blocks, thinking blocks, tool_result wrapping —
/// by exact string equality. Fixtures 2 and 4 carry no tool schemas, so
/// they're checked by plain `XCTAssertEqual` on the full string.
final class DeepseekV4EncodingTests: XCTestCase {

    // MARK: - Fixture loading

    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "dsv4"),
            "missing fixture \(name)")
    }

    private func loadJSON(_ name: String) throws -> Any {
        let data = try Data(contentsOf: fixtureURL(name))
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func loadText(_ name: String) throws -> String {
        try String(contentsOf: fixtureURL(name), encoding: .utf8)
    }

    /// `[Any]` (JSONSerialization output) → `[DSV4Msg]`, converting every
    /// element through `DeepseekV4JSON.asSendable`.
    private func messages(from json: Any) -> [DSV4Msg] {
        guard let array = json as? [Any] else { return [] }
        return array.compactMap { DeepseekV4JSON.asSendable($0) as? DSV4Msg }
    }

    // MARK: - Semantic comparison for the tool-schema section

    private static let schemaSectionHeader = "### Available Tool Schemas\n\n"
    private static let schemaSectionFooter =
        "\n\nYou MUST strictly follow the above defined tool name and parameter schemas to invoke tool calls."

    /// Compare an encoded prompt against a fixture's expected text. When the
    /// fixture carries a `## Tools` schema section, the section preceding
    /// and following the schema JSON is compared byte-for-byte, and the
    /// schema JSON itself is compared by parsed (key-order-independent)
    /// equality — see the class doc comment for why.
    private func assertDeepseekV4PromptMatches(
        _ actual: String,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let expectedHeaderRange = expected.range(of: Self.schemaSectionHeader) else {
            XCTAssertEqual(actual, expected, file: file, line: line)
            return
        }
        let actualHeaderRange = try XCTUnwrap(
            actual.range(of: Self.schemaSectionHeader),
            "actual prompt is missing the tool schema section the fixture expects",
            file: file, line: line)

        XCTAssertEqual(
            String(actual[..<actualHeaderRange.upperBound]),
            String(expected[..<expectedHeaderRange.upperBound]),
            "text before/including '### Available Tool Schemas' header differs",
            file: file, line: line)

        let actualRest = actual[actualHeaderRange.upperBound...]
        let expectedRest = expected[expectedHeaderRange.upperBound...]
        let actualFooterRange = try XCTUnwrap(
            actualRest.range(of: Self.schemaSectionFooter), "actual missing schema section footer",
            file: file, line: line)
        let expectedFooterRange = try XCTUnwrap(
            expectedRest.range(of: Self.schemaSectionFooter), "expected missing schema section footer",
            file: file, line: line)

        XCTAssertEqual(
            String(actualRest[actualFooterRange.lowerBound...]),
            String(expectedRest[expectedFooterRange.lowerBound...]),
            "text from the schema-section footer onward differs",
            file: file, line: line)

        let actualSchemaLines = String(actualRest[..<actualFooterRange.lowerBound])
            .components(separatedBy: "\n")
        let expectedSchemaLines = String(expectedRest[..<expectedFooterRange.lowerBound])
            .components(separatedBy: "\n")
        XCTAssertEqual(
            actualSchemaLines.count, expectedSchemaLines.count,
            "different number of tool schema lines", file: file, line: line)

        for (actualLine, expectedLine) in zip(actualSchemaLines, expectedSchemaLines) {
            let actualObj = try JSONSerialization.jsonObject(with: Data(actualLine.utf8)) as? NSDictionary
            let expectedObj = try JSONSerialization.jsonObject(with: Data(expectedLine.utf8)) as? NSDictionary
            XCTAssertEqual(
                actualObj, expectedObj,
                "tool schema JSON differs semantically:\n  actual:   \(actualLine)\n  expected: \(expectedLine)",
                file: file, line: line)
        }
    }

    // MARK: - Fixture 1: thinking mode + tools + tool round-trip

    func testFixture1ThinkingWithToolsAndToolRoundTrip() throws {
        let input = try loadJSON("test_input_1.json") as! [String: Any]
        let expected = try loadText("test_output_1.txt")

        let messages = messages(from: input["messages"]!)
        let tools = (input["tools"] as? [Any])?.compactMap {
            DeepseekV4JSON.asSendable($0) as? DSV4Msg
        }

        let prompt = try DeepseekV4Encoding.encode(messages: messages, tools: tools, thinkingMode: "thinking")
        try assertDeepseekV4PromptMatches(prompt, expected)
    }

    // MARK: - Fixture 2: plain multi-turn, drop_thinking removes earlier reasoning

    func testFixture2PlainMultiTurnDropsEarlierThinking() throws {
        let input = try loadJSON("test_input_2.json")
        let expected = try loadText("test_output_2.txt")

        let prompt = try DeepseekV4Encoding.encode(messages: messages(from: input), thinkingMode: "thinking")

        XCTAssertEqual(prompt, expected)
        XCTAssertFalse(prompt.contains("The user said hello"), "drop_thinking must strip the earlier turn's reasoning")
    }

    // MARK: - Fixture 3: developer role + tools + latest_reminder, interleaved thinking

    func testFixture3DeveloperToolsAndLatestReminder() throws {
        // Encoder-level: `developer` role and per-message `tools` (rather
        // than a request-level `tools` field) have no OpenAI wire
        // representation, so this fixture is fed straight to the encoder's
        // full field set instead of round-tripping through OpenAI types.
        let input = try loadJSON("test_input_3.json")
        let expected = try loadText("test_output_3.txt")

        let prompt = try DeepseekV4Encoding.encode(messages: messages(from: input), thinkingMode: "thinking")
        try assertDeepseekV4PromptMatches(prompt, expected)
    }

    // MARK: - Fixture 4: quick-instruction task + latest_reminder, chat mode

    func testFixture4QuickInstructionTaskChatMode() throws {
        // Encoder-level: `latest_reminder` role and the `task`/`mask` fields
        // have no OpenAI wire representation.
        let input = try loadJSON("test_input_4.json")
        let expected = try loadText("test_output_4.txt")

        let prompt = try DeepseekV4Encoding.encode(messages: messages(from: input), thinkingMode: "chat")

        XCTAssertEqual(prompt, expected)
    }

    // MARK: - thinking vs chat mode

    func testChatModeClosesThinkingImmediately() throws {
        let messages: [DSV4Msg] = [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "What is 2+2?"],
        ]
        let prompt = try DeepseekV4Encoding.encode(messages: messages, thinkingMode: "chat")
        XCTAssertTrue(prompt.hasSuffix("<｜Assistant｜></think>"))
    }

    func testThinkingModeLeavesThinkOpen() throws {
        let messages: [DSV4Msg] = [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "What is 2+2?"],
        ]
        let prompt = try DeepseekV4Encoding.encode(messages: messages, thinkingMode: "thinking")
        XCTAssertEqual(
            prompt,
            "<｜begin▁of▁sentence｜>You are a helpful assistant.<｜User｜>What is 2+2?<｜Assistant｜><think>")
    }

    func testInvalidThinkingModeThrows() {
        let messages: [DSV4Msg] = [["role": "user", "content": "hi"]]
        XCTAssertThrowsError(try DeepseekV4Encoding.encode(messages: messages, thinkingMode: "bogus")) { error in
            XCTAssertEqual(error as? DeepseekV4EncodingError, .invalidThinkingMode("bogus"))
        }
    }

    // MARK: - drop_thinking on/off, with/without tools

    private var twoTurnHistoryWithReasoning: [DSV4Msg] {
        [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "Hello"],
            [
                "role": "assistant", "reasoning_content": "EARLIER_REASONING_MARKER",
                "content": "Hi there!",
            ],
            ["role": "user", "content": "What's 2+2?"],
            ["role": "assistant", "reasoning_content": "LATEST_REASONING_MARKER", "content": "4"],
        ]
    }

    func testDropThinkingTrueStripsEarlierReasoningOnly() throws {
        let prompt = try DeepseekV4Encoding.encode(
            messages: twoTurnHistoryWithReasoning, thinkingMode: "thinking", dropThinking: true)
        XCTAssertFalse(prompt.contains("EARLIER_REASONING_MARKER"))
        XCTAssertTrue(prompt.contains("LATEST_REASONING_MARKER"))
    }

    func testDropThinkingFalsePreservesAllReasoning() throws {
        let prompt = try DeepseekV4Encoding.encode(
            messages: twoTurnHistoryWithReasoning, thinkingMode: "thinking", dropThinking: false)
        XCTAssertTrue(prompt.contains("EARLIER_REASONING_MARKER"))
        XCTAssertTrue(prompt.contains("LATEST_REASONING_MARKER"))
    }

    func testDropThinkingAutoDisabledWhenToolsPresent() throws {
        // Same history, but the system message declares tools. Even with
        // drop_thinking requested True, the reference disables it whenever
        // ANY message declares tools -- tool-calling conversations need
        // full context.
        let tools: [DSV4Msg] = [
            [
                "type": "function",
                "function": ["name": "noop", "description": "does nothing", "parameters": ["type": "object"] as DSV4Msg]
                    as DSV4Msg,
            ]
        ]
        let prompt = try DeepseekV4Encoding.encode(
            messages: twoTurnHistoryWithReasoning, tools: tools, thinkingMode: "thinking", dropThinking: true)
        XCTAssertTrue(
            prompt.contains("EARLIER_REASONING_MARKER"),
            "drop_thinking must be auto-disabled whenever any message declares tools")
    }

    // MARK: - reasoning_effort = max prefix

    func testReasoningEffortMaxPrependsFixedPrefix() throws {
        let messages: [DSV4Msg] = [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "hi"],
        ]
        let prompt = try DeepseekV4Encoding.encode(
            messages: messages, thinkingMode: "thinking", reasoningEffort: "max")

        XCTAssertTrue(
            prompt.hasPrefix(
                "<｜begin▁of▁sentence｜>Reasoning Effort: Absolute maximum with no shortcuts permitted.\n"))
        XCTAssertTrue(prompt.contains("rejected hypothesis to ensure absolutely no assumption is left unchecked.\n\n"))
        // Only takes effect in thinking mode.
        let chatPrompt = try DeepseekV4Encoding.encode(
            messages: messages, thinkingMode: "chat", reasoningEffort: "max")
        XCTAssertFalse(chatPrompt.contains("Reasoning Effort:"))
    }

    func testInvalidReasoningEffortThrows() {
        let messages: [DSV4Msg] = [["role": "user", "content": "hi"]]
        XCTAssertThrowsError(
            try DeepseekV4Encoding.encode(messages: messages, reasoningEffort: "ultra")
        ) { error in
            XCTAssertEqual(error as? DeepseekV4EncodingError, .invalidReasoningEffort("ultra"))
        }
    }

    // MARK: - tool_result ordering with multiple concurrent tool calls

    func testToolResultsSortedByOriginalToolCallOrder() throws {
        // Two tool calls issued in order [alpha, beta]; results arrive on
        // the wire in the REVERSE order [beta, alpha] (as separate `tool`
        // messages, the shape multiple parallel OpenAI tool results take).
        // The encoder must reorder the merged <tool_result> blocks back to
        // the original [alpha, beta] call order.
        let messages: [DSV4Msg] = [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "Look up two things for me."],
            [
                "role": "assistant",
                "reasoning_content": "Need both lookups.",
                "tool_calls": [
                    [
                        "id": "call_alpha", "type": "function",
                        "function": ["name": "lookup", "arguments": "{\"q\": \"alpha\"}"] as DSV4Msg,
                    ] as DSV4Msg,
                    [
                        "id": "call_beta", "type": "function",
                        "function": ["name": "lookup", "arguments": "{\"q\": \"beta\"}"] as DSV4Msg,
                    ] as DSV4Msg,
                ] as [DSV4Msg],
            ],
            ["role": "tool", "content": "BETA_RESULT", "tool_call_id": "call_beta"],
            ["role": "tool", "content": "ALPHA_RESULT", "tool_call_id": "call_alpha"],
            ["role": "assistant", "reasoning_content": "Got both.", "content": "Done."],
        ]

        let prompt = try DeepseekV4Encoding.encode(messages: messages, thinkingMode: "thinking")

        let alphaRange = try XCTUnwrap(prompt.range(of: "ALPHA_RESULT"))
        let betaRange = try XCTUnwrap(prompt.range(of: "BETA_RESULT"))
        XCTAssertTrue(
            alphaRange.lowerBound < betaRange.lowerBound,
            "tool_result for the FIRST tool_call (alpha) must be emitted before the second (beta), "
                + "regardless of the order the `tool` messages arrived in")
        // Multiple content_blocks within one user turn are joined by "\n\n"
        // (`render_message`'s `"\n\n".join(parts)`).
        XCTAssertTrue(
            prompt.contains("<tool_result>ALPHA_RESULT</tool_result>\n\n<tool_result>BETA_RESULT</tool_result>"))
    }

    // MARK: - tool_calls with mixed string / JSON parameter types

    func testToolCallStringVsJSONParameterEncoding() throws {
        let messages: [DSV4Msg] = [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "Search."],
            [
                "role": "assistant",
                "reasoning_content": "Calling search.",
                "tool_calls": [
                    [
                        "id": "call_1", "type": "function",
                        "function": [
                            "name": "search",
                            "arguments": "{\"query\": \"weather\", \"num_results\": 3, \"verbose\": true}",
                        ] as DSV4Msg,
                    ] as DSV4Msg
                ] as [DSV4Msg],
            ],
        ]

        let prompt = try DeepseekV4Encoding.encode(messages: messages, thinkingMode: "thinking")

        XCTAssertTrue(prompt.contains(
            "<｜DSML｜parameter name=\"query\" string=\"true\">weather</｜DSML｜parameter>"))
        XCTAssertTrue(prompt.contains(
            "<｜DSML｜parameter name=\"num_results\" string=\"false\">3</｜DSML｜parameter>"))
        XCTAssertTrue(prompt.contains(
            "<｜DSML｜parameter name=\"verbose\" string=\"false\">true</｜DSML｜parameter>"))
    }

    // MARK: - Malformed tool-call arguments fall back like the reference

    func testMalformedToolCallArgumentsFallBackToWrappedString() throws {
        let messages: [DSV4Msg] = [
            ["role": "user", "content": "hi"],
            [
                "role": "assistant",
                "tool_calls": [
                    [
                        "id": "call_1", "type": "function",
                        "function": ["name": "f", "arguments": "not valid json"] as DSV4Msg,
                    ] as DSV4Msg
                ] as [DSV4Msg],
            ],
        ]
        let prompt = try DeepseekV4Encoding.encode(messages: messages, thinkingMode: "chat")
        XCTAssertTrue(prompt.contains(
            "<｜DSML｜parameter name=\"arguments\" string=\"true\">not valid json</｜DSML｜parameter>"))
    }

    // MARK: - Unmergeable / unsupported shapes

    func testDeveloperMessageRequiresNonEmptyContent() {
        let messages: [DSV4Msg] = [["role": "developer", "content": ""]]
        XCTAssertThrowsError(try DeepseekV4Encoding.encode(messages: messages))
    }
}
