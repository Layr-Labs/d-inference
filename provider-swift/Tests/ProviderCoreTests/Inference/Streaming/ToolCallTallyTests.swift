import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// A finished response's tool calls reach its profile as counts: how many it
/// returned and how many of those break the request's declaration (returned
/// as generated: an undeclared function or arguments the declared schema
/// refuses). Nothing about a call but the counts leaves.
@Suite("Tool call tally")
struct ToolCallTallyTests {
    private static let tools = """
        [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
          "properties":{"location":{"type":"string"},"days":{"type":"integer"}},"required":["location"]}}},
         {"type":"function","function":{"name":"write_file","parameters":{"type":"object",
          "properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}]
        """

    private static func request(strict: Bool = false) throws -> OpenAIChatCompletionRequest {
        var request = OpenAIChatCompletionRequest(
            model: "qwen3.5-9b",
            messages: [.init(role: .user, content: .text("Write it."))],
            tools: try JSONDecoder().decode([OpenAITool].self, from: Data(tools.utf8)).map { tool in
                var tool = tool
                if strict { tool.function.strict = true }
                return tool
            },
            stream: true)
        request.streamToolCallDeltas = true
        request.reasoningParser = .qwen3
        return request
    }

    private static func qwenCall(_ name: String, _ parameters: [(String, String)]) -> String {
        "<tool_call>\n<function=\(name)>\n"
            + parameters.map { "<parameter=\($0.0)>\n\($0.1)\n</parameter>\n" }.joined()
            + "</function>\n</tool_call>"
    }

    /// One Qwen 3.5 response over the production forwarder; the usage signal
    /// the provider frames loop reads at the terminal.
    private static func serve(_ text: String, streamToolCalls: Bool, strict: Bool = false) async throws
        -> EngineV2RequestUsageSignal
    {
        let request = try Self.request(strict: strict)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
        let handler = try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "qwen3_5", streamToolCalls: streamToolCalls)
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        for character in text { upstream.continuation.yield(.chunk(String(character))) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 40, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        let usage = EngineV2RequestUsageSignal()
        let stream = try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream.stream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
            toolHandler: handler, usageSignal: usage)
        for try await _ in stream {}
        return usage
    }

    @Test(arguments: [true, false])
    func returnedCallsAndThoseBreakingTheDeclarationAreCounted(streamToolCalls: Bool) async throws {
        let text = Self.qwenCall("get_weather", [("location", "Paris"), ("days", "3")])
            + Self.qwenCall("write_file", [("path", "fib.py")])
        let usage = try await Self.serve(text, streamToolCalls: streamToolCalls)
        #expect(usage.toolCalls == ToolCallTally(returned: 2, breakingDeclaration: 1))
    }

    /// `strict` calls are validated before they return, so none returned
    /// breaks the declaration; an answer without calls records nothing.
    @Test func strictCallsAndAnswersWithoutCallsBreakNothing() async throws {
        let valid = Self.qwenCall("get_weather", [("location", "Paris")])
        let strict = try await Self.serve(valid, streamToolCalls: true, strict: true)
        #expect(strict.toolCalls == ToolCallTally(returned: 1, breakingDeclaration: 0))
        let answer = try await Self.serve("It is sunny in Paris.", streamToolCalls: true)
        #expect(answer.toolCalls == nil)
    }

    @Test func breaksDeclarationReadsTheCallersSchema() throws {
        let prepared = try ToolChoicePromptPolicy.prepare(Self.request(), modelType: "qwen3_5")
        func call(_ name: String, _ arguments: [String: MLXLMCommon.JSONValue]) -> ToolCall {
            ToolCall(function: .init(name: name, arguments: arguments))
        }
        #expect(!ToolConstraintValidation.breaksDeclaration(
            call("get_weather", ["location": .string("Paris"), "days": .int(3)]), prepared: prepared))
        #expect(ToolConstraintValidation.breaksDeclaration(
            call("get_weather", ["days": .int(3)]), prepared: prepared))
        #expect(ToolConstraintValidation.breaksDeclaration(
            call("get_weather", ["location": .string("Paris"), "days": .string("three")]), prepared: prepared))
        #expect(ToolConstraintValidation.breaksDeclaration(
            call("delete_everything", ["path": .string("/")]), prepared: prepared))

        // Only calls returned as generated are counted: before the response
        // started, `strict` calls are validated instead.
        let breaking = [call("get_weather", ["days": .int(3)]), call("delete_everything", [:])]
        #expect(ToolConstraintValidation.countBreakingDeclaration(breaking, prepared: prepared,
            responseStarted: false) == 2)
        let strict = try ToolChoicePromptPolicy.prepare(Self.request(strict: true), modelType: "qwen3_5")
        #expect(ToolConstraintValidation.countBreakingDeclaration(breaking, prepared: strict,
            responseStarted: false) == 0)
    }

    /// A parameter declared by a local `$ref` is checked against its target,
    /// as OpenRouter's validator resolves it: an object returned as a JSON
    /// string breaks the declaration.
    @Test func breaksDeclarationFollowsLocalReferences() throws {
        var request = try Self.request()
        request.tools = try JSONDecoder().decode([OpenAITool].self, from: Data(#"""
            [{"type":"function","function":{"name":"plot","parameters":{"type":"object",
              "$defs":{"Point":{"type":"object","properties":{"x":{"type":"integer"}},"required":["x"]}},
              "properties":{"at":{"$ref":"#/$defs/Point"}},"required":["at"]}}}]
            """#.utf8))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
        func plot(_ at: MLXLMCommon.JSONValue) -> ToolCall {
            ToolCall(function: .init(name: "plot", arguments: ["at": at]))
        }
        #expect(ToolConstraintValidation.breaksDeclaration(plot(.string(#"{"x": 1}"#)), prepared: prepared))
        #expect(ToolConstraintValidation.breaksDeclaration(plot(.object(["x": .string("1")])), prepared: prepared))
        #expect(!ToolConstraintValidation.breaksDeclaration(plot(.object(["x": .int(1)])), prepared: prepared))
    }

    /// A reference the coordinator could not inline (a cycle) keeps its
    /// target's `type` beside it; the check reads that type, and still
    /// follows the schema's other references.
    @Test func breaksDeclarationReadsTheTypeBesideAReferenceKeptByTheCoordinator() throws {
        var request = try Self.request()
        request.tools = try JSONDecoder().decode([OpenAITool].self, from: Data(#"""
            [{"type":"function","function":{"name":"grow","parameters":{"type":"object",
              "$defs":{"Node":{"type":"object","properties":{"child":{"$ref":"#/$defs/Node","type":"object"}}},
                       "Size":{"type":"integer"}},
              "properties":{"tree":{"$ref":"#/$defs/Node","type":"object"},"size":{"$ref":"#/$defs/Size"}},
              "required":["tree"]}}}]
            """#.utf8))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
        func grow(_ arguments: [String: MLXLMCommon.JSONValue]) -> ToolCall {
            ToolCall(function: .init(name: "grow", arguments: arguments))
        }
        #expect(ToolConstraintValidation.breaksDeclaration(grow(["tree": .string(#"{"child": {}}"#)]),
            prepared: prepared))
        #expect(ToolConstraintValidation.breaksDeclaration(
            grow(["tree": .object([:]), "size": .string("3")]), prepared: prepared))
        #expect(!ToolConstraintValidation.breaksDeclaration(
            grow(["tree": .object(["child": .object([:])]), "size": .int(3)]), prepared: prepared))
    }

    /// The type hint is read only on a reference node: a properties map that
    /// declares parameters named `$ref` and `type` keeps both.
    @Test func breaksDeclarationKeepsParametersNamedLikeReferenceKeywords() throws {
        var request = try Self.request()
        request.tools = try JSONDecoder().decode([OpenAITool].self, from: Data(#"""
            [{"type":"function","function":{"name":"tag","parameters":{"type":"object",
              "$defs":{"Node":{"type":"object","properties":{"child":{"$ref":"#/$defs/Node","type":"object"}}}},
              "properties":{"$ref":{"type":"string"},"type":{"type":"string"},
                            "loop":{"$ref":"#/$defs/Node","type":"object"}},
              "additionalProperties":false}}}]
            """#.utf8))
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
        let call = ToolCall(function: .init(name: "tag",
            arguments: ["$ref": .string("a"), "type": .string("b"), "loop": .object([:])]))
        #expect(!ToolConstraintValidation.breaksDeclaration(call, prepared: prepared))
    }

    @Test func profileCarriesTheTallyOnlyWhenSet() throws {
        let builder = RequestProfileBuilder()
        let quiet = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(builder.wireObject())) as? [String: Any]
        #expect(quiet?["tool_calls"] == nil && quiet?["tool_calls_breaking_declaration"] == nil)
        builder.update { f, _ in
            f.set(.toolCalls, 3)
            f.set(.toolCallsBreakingDeclaration, 1)
        }
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(builder.wireObject())) as? [String: Any]
        #expect(object?["tool_calls"] as? Int64 == 3)
        #expect(object?["tool_calls_breaking_declaration"] as? Int64 == 1)
    }
}
