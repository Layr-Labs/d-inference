import XCTest

import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation

@testable import ProviderCore

/// A chat-completions request carrying JSON `null` inside a tool's
/// `function.parameters` schema or an assistant message's
/// `tool_calls[].function.arguments` previously reached `applyChatTemplate`
/// un-normalized and crashed `Jinja.Value(any:)`
/// (`Cannot convert value of type … to Jinja Value`), surfacing as a 500.
///
/// These tests exercise the sanitizer (`sanitizeForJinja` and the
/// `sanitizeJinjaMessages` / `sanitizeJinjaTools` adapters applied at the
/// three runtime chokepoints) against the EXACT value trees the runtime
/// builders produce — `OpenAIChatMessage.templateMessageDict()` and
/// `OpenAITool.toolSpec()` — proving the Jinja-unrepresentable null /
/// Optional leaves are dropped while non-null data and ordering survive.
final class JinjaSanitizationTests: XCTestCase {

    // MARK: - Leaf detection helper

    /// True if `value`'s tree still contains anything `Jinja.Value(any:)`
    /// would throw on: `NSNull`, the private `JSONNull` sentinel, a boxed
    /// Swift `Optional`, or a bare `nil`. Mirrors the bridge's blind spots.
    private func containsUnrepresentableLeaf(_ value: Any?) -> Bool {
        guard let value else { return true }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first else { return true }
            return containsUnrepresentableLeaf(wrapped.value)
        }
        if value is NSNull { return true }
        if String(describing: type(of: value)) == "JSONNull" { return true }
        if let dict = value as? [String: Any] {
            return dict.values.contains { containsUnrepresentableLeaf($0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsUnrepresentableLeaf($0) }
        }
        return false
    }

    // MARK: - (c) Core sanitizer: drops nulls, preserves data + order

    func testDropsNSNullDictionaryEntry() {
        let input: [String: any Sendable] = [
            "keep": "value",
            "drop": NSNull(),
        ]
        let output = sanitizeJinjaObject(input)
        XCTAssertEqual(output["keep"] as? String, "value")
        XCTAssertNil(output["drop"])
        XCTAssertFalse(containsUnrepresentableLeaf(output))
    }

    func testDropsNullArrayElementsPreservingOrder() {
        let input: [Any] = [1, NSNull(), 2, NSNull(), 3]
        let cleaned = sanitizeForJinja(input) as? [any Sendable]
        XCTAssertEqual(cleaned?.compactMap { $0 as? Int }, [1, 2, 3])
    }

    func testUnwrapsNonNilOptionalAndDropsNoneOptional() {
        // A non-nil Optional boxed in `Any` must be unwrapped to its payload
        // so no `Optional<…>` leaks into the bridge.
        let some: Any = Optional<String>.some("hello") as Any
        XCTAssertEqual(sanitizeForJinja(some) as? String, "hello")

        // A boxed `Optional.none` must be dropped (returns nil).
        let none: Any = Optional<String>.none as Any
        XCTAssertNil(sanitizeForJinja(none))
    }

    func testRecursesIntoNestedContainers() {
        let input: [String: any Sendable] = [
            "outer": [
                "inner_keep": 42,
                "inner_drop": NSNull(),
                "list": [true, NSNull(), "x"] as [any Sendable],
            ] as [String: any Sendable],
        ]
        let output = sanitizeJinjaObject(input)
        let outer = output["outer"] as? [String: any Sendable]
        XCTAssertEqual(outer?["inner_keep"] as? Int, 42)
        XCTAssertNil(outer?["inner_drop"])
        XCTAssertEqual((outer?["list"] as? [any Sendable])?.count, 2)
        XCTAssertFalse(containsUnrepresentableLeaf(output))
    }

    func testPreservesNonNullValuesByteForByte() {
        let input: [String: any Sendable] = [
            "s": "text",
            "i": 7,
            "d": 3.5,
            "b": true,
            "arr": [1, 2, 3] as [any Sendable],
        ]
        let output = sanitizeJinjaObject(input)
        XCTAssertEqual(output["s"] as? String, "text")
        XCTAssertEqual(output["i"] as? Int, 7)
        XCTAssertEqual(output["d"] as? Double, 3.5)
        XCTAssertEqual(output["b"] as? Bool, true)
        XCTAssertEqual((output["arr"] as? [any Sendable])?.compactMap { $0 as? Int }, [1, 2, 3])
    }

    func testSanitizeJinjaToolsNilInNilOut() {
        XCTAssertNil(sanitizeJinjaTools(nil))
    }

    // MARK: - (a) Message with a null tool-call argument

    func testMessageWithNullToolCallArgumentIsSanitized() {
        let message = OpenAIChatMessage(
            role: .assistant,
            content: .null,
            toolCalls: [
                OpenAIToolCall(
                    id: "call_0001",
                    type: "function",
                    function: .init(
                        name: "get_weather",
                        // JSON `null` inside the arguments — decoded to NSNull
                        // by `decodeToolCallArguments`.
                        arguments: #"{"city":"SF","unit":null}"#
                    )
                )
            ]
        )

        let raw = message.templateMessageDict()
        // Precondition: the raw builder output really does carry a null leaf
        // (otherwise this test would pass vacuously).
        XCTAssertTrue(containsUnrepresentableLeaf(raw))

        let sanitized = sanitizeJinjaMessages([raw])[0]
        XCTAssertFalse(containsUnrepresentableLeaf(sanitized))

        // Non-null argument survives; the null `unit` key is dropped.
        let toolCalls = sanitized["tool_calls"] as? [any Sendable]
        let firstCall = toolCalls?.first as? [String: any Sendable]
        let function = firstCall?["function"] as? [String: any Sendable]
        let arguments = function?["arguments"] as? [String: any Sendable]
        XCTAssertEqual(arguments?["city"] as? String, "SF")
        XCTAssertNil(arguments?["unit"])
    }

    // MARK: - (b) Tool schema with null values

    func testToolSchemaWithNullValuesIsSanitized() {
        let tool = OpenAITool(
            type: "function",
            function: OpenAIFunctionDefinition(
                name: "get_weather",
                description: "Get the weather",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "unit": .object([
                            "type": .string("string"),
                            // null enum element + null default — both become
                            // the private `JSONNull` via `sendableValue`.
                            "enum": .array([.string("celsius"), .string("fahrenheit"), .null]),
                            "default": .null,
                        ]),
                    ]),
                    "required": .array([.string("unit")]),
                ])
            )
        )

        let rawSpec = tool.toolSpec()
        XCTAssertTrue(containsUnrepresentableLeaf(rawSpec))

        let sanitized = sanitizeJinjaTools([rawSpec])
        XCTAssertNotNil(sanitized)
        let spec = sanitized![0]
        XCTAssertFalse(containsUnrepresentableLeaf(spec))

        // Structure + ordering of real values preserved; nulls dropped.
        let function = spec["function"] as? [String: any Sendable]
        let parameters = function?["parameters"] as? [String: any Sendable]
        let properties = parameters?["properties"] as? [String: any Sendable]
        let unit = properties?["unit"] as? [String: any Sendable]
        XCTAssertEqual(unit?["type"] as? String, "string")
        XCTAssertNil(unit?["default"])
        let enumValues = unit?["enum"] as? [any Sendable]
        // Assert the element COUNT (not just the String-filtered view): the null
        // element must actually be removed, so a regression that left an
        // unrepresentable leaf in the array would fail here rather than be
        // silently hidden by the `as? String` cast below.
        XCTAssertEqual(enumValues?.count, 2)
        XCTAssertEqual(enumValues?.compactMap { $0 as? String }, ["celsius", "fahrenheit"])
    }

    // MARK: - (d) End-to-end shape that previously crashed the bridge

    func testFullNullBearingRequestHasNoUnrepresentableLeavesAfterSanitize() {
        // The exact combination from the incident: tools (with a null in the
        // schema) + an assistant tool-call message (with a null argument).
        let messages = [
            OpenAIChatMessage(role: .user, content: .text("Weather in SF?")),
            OpenAIChatMessage(
                role: .assistant,
                content: .null,
                toolCalls: [
                    OpenAIToolCall(
                        id: "call_0001",
                        type: "function",
                        function: .init(name: "get_weather", arguments: #"{"city":"SF","unit":null}"#)
                    )
                ]
            ),
        ]
        let tool = OpenAITool(
            type: "function",
            function: OpenAIFunctionDefinition(
                name: "get_weather",
                description: "Get the weather",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "unit": .object([
                            "type": .string("string"),
                            "default": .null,
                        ]),
                    ]),
                ])
            )
        )

        let rawMessages = messages.map { $0.templateMessageDict() }
        let rawTools = [tool.toolSpec()]
        XCTAssertTrue(rawMessages.contains { containsUnrepresentableLeaf($0) })
        XCTAssertTrue(rawTools.contains { containsUnrepresentableLeaf($0) })

        let cleanMessages = sanitizeJinjaMessages(rawMessages)
        let cleanTools = sanitizeJinjaTools(rawTools)
        XCTAssertFalse(cleanMessages.contains { containsUnrepresentableLeaf($0) })
        XCTAssertFalse((cleanTools ?? []).contains { containsUnrepresentableLeaf($0) })
    }
}
