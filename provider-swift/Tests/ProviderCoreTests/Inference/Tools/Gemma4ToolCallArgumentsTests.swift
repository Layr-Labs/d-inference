import Foundation
import Testing

@testable import ProviderCore

/// E3 tool-call `arguments` hardening (`Gemma4TemplateFix.normalizeMessages`
/// → `Gemma4ToolCallArguments`): the engine's `decodeToolCallArguments`
/// returns the RAW STRING when arguments are empty / malformed / non-object
/// JSON, and the served Gemma template's `is string` branch renders it as
/// double-brace garbage (`call:f{{"a":1}}`). Missing/empty become `{}`,
/// object strings are parsed, and everything else is a clean 400.
@Suite("Gemma4 tool-call arguments hardening (E3)")
struct Gemma4ToolCallArgumentsTests {

    private func assistantCall(arguments: (any Sendable)?) -> [[String: any Sendable]] {
        var function: [String: any Sendable] = ["name": "run"]
        if let arguments {
            function["arguments"] = arguments
        }
        return [
            [
                "role": "assistant", "content": "",
                "tool_calls": [
                    ["id": "call_1", "type": "function", "function": function]
                        as [String: any Sendable]
                ] as [any Sendable],
            ],
            ["role": "tool", "tool_call_id": "call_1", "content": "ok"],
        ]
    }

    private func normalizedArguments(
        _ messages: [[String: any Sendable]]
    ) throws -> [String: any Sendable]? {
        let out = try Gemma4TemplateFix.normalizeMessages(messages)
        let calls = out.first?["tool_calls"] as? [any Sendable]
        let call = calls?.first as? [String: any Sendable]
        let function = call?["function"] as? [String: any Sendable]
        return function?["arguments"] as? [String: any Sendable]
    }

    // MARK: - Empty / missing

    @Test func missingArgumentsBecomeEmptyObject() throws {
        let args = try normalizedArguments(assistantCall(arguments: nil))
        #expect(args?.isEmpty == true)
    }

    @Test func emptyAndWhitespaceStringsBecomeEmptyObject() throws {
        for raw in ["", "   ", "\n"] {
            let args = try normalizedArguments(assistantCall(arguments: raw))
            #expect(args?.isEmpty == true, "raw=\(raw.debugDescription)")
        }
    }

    // MARK: - Parseable object strings

    /// The raw-string shape the engine hands over on its non-object fallback:
    /// a VALID object string must become a mapping (the template's
    /// `is mapping` branch), never render verbatim.
    @Test func objectStringIsParsedIntoMapping() throws {
        let args = try normalizedArguments(
            assistantCall(arguments: #"{"command":"ls -la","depth":2}"#))
        #expect(args?["command"] as? String == "ls -la")
        #expect((args?["depth"] as? Int) == 2)
    }

    /// A null INSIDE the parsed object is re-stripped (the raw string bypassed
    /// the earlier sanitize pass; an NSNull leaf would crash the Jinja bridge).
    @Test func nullLeavesInsideParsedObjectAreStripped() throws {
        let args = try normalizedArguments(
            assistantCall(arguments: #"{"keep":1,"drop":null}"#))
        #expect(args?["keep"] as? Int == 1)
        #expect(args?["drop"] == nil)
    }

    // MARK: - Deterministic 400s

    @Test func malformedAndNonObjectStringsThrow() {
        for raw in ["{bad", "null", "[1,2]", "42", "\"str\"", "true"] {
            do {
                _ = try Gemma4TemplateFix.normalizeMessages(assistantCall(arguments: raw))
                Issue.record("\(raw.debugDescription): expected invalidToolPayload")
            } catch let error as MultiModelBatchSchedulerEngineError {
                guard case .invalidToolPayload(let message) = error else {
                    Issue.record("\(raw.debugDescription): wrong case \(error)")
                    continue
                }
                #expect(
                    message == "tool_calls[].function.arguments must be a JSON object",
                    "raw=\(raw.debugDescription)")
            } catch {
                Issue.record("\(raw.debugDescription): unexpected error \(error)")
            }
        }
    }

    @Test func nonStringNonMappingArgumentsThrow() {
        for raw: any Sendable in [[1, 2] as [any Sendable], 42, false] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                _ = try Gemma4TemplateFix.normalizeMessages(assistantCall(arguments: raw))
            }
        }
    }

    // MARK: - Preservation

    @Test func decodedObjectArgumentsPassThrough() throws {
        let args = try normalizedArguments(
            assistantCall(arguments: ["city": "SF"] as [String: any Sendable]))
        #expect(args?["city"] as? String == "SF")
    }

    @Test func nonAssistantAndCallLessMessagesUntouched() throws {
        let input: [[String: any Sendable]] = [
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "plain answer"],
        ]
        let out = try Gemma4TemplateFix.normalizeMessages(input)
        #expect(out.count == 2)
        #expect(out[1]["tool_calls"] == nil)
    }

    /// Wiring: the production chokepoint rejects the malformed shape for
    /// gemma4 contexts and leaves other model families on their own paths.
    @Test func chatTemplateFixesRejectsMalformedForGemma() {
        let gemma = ChatTemplateFixContext(
            modelId: "gemma-4-26b-a4b-it-qat-4bit", modelType: "gemma4_text")
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ChatTemplateFixes.normalizeMessages(
                assistantCall(arguments: "{bad"), context: gemma)
        }
        let qwen = ChatTemplateFixContext(modelId: "qwen3-8b", modelType: "qwen3")
        #expect(throws: Never.self) {
            _ = try ChatTemplateFixes.normalizeMessages(
                assistantCall(arguments: "{bad"), context: qwen)
        }
    }
}
