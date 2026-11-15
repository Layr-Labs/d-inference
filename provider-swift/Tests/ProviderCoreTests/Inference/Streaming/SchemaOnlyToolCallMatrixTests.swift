import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

#if DEBUG
/// Every served family's tool path on an `auto` call that keeps its native
/// grammar but breaks the caller's schema: the production event stream (the
/// family's parser, router and withheld or streamed calls) returns the call
/// as generated, never its markup as text or a failure. Pairs run the same
/// router on their leader; GLM's pair flag is covered too.
@Suite("Calls that break only their schema, every family")
struct SchemaOnlyToolCallMatrixTests {
    enum Shape: String, CaseIterable, Sendable {
        case missingRequired, undeclaredWithoutAdditionalProperties
        case undeclaredWithAdditionalPropertiesFalse, untypedParameter
        case nullableUnionParameter, mismatchedType
    }

    struct Family: Sendable, CustomTestStringConvertible {
        let name: String
        let modelType: String
        var glmPair = false
        var testDescription: String { name }
    }

    static let families: [Family] = [
        .init(name: "Gemma 4 26B", modelType: "gemma4"),
        .init(name: "GPT-OSS 20B", modelType: "gpt_oss"),
        .init(name: "Qwen 3.5 9B", modelType: "qwen3_5"),
        .init(name: "Qwen 3.5 35B / 3.6", modelType: "qwen3_5_moe"),
        .init(name: "Qwen 3.8", modelType: "qwen4_exp"),
        .init(name: "Nemotron 3.5 Lightning", modelType: "nemotron_h"),
        .init(name: "Nemotron 3.5 Super", modelType: "nemotron_h_omni"),
        .init(name: "MiMo V2.6", modelType: "mimo_v2"),
        .init(name: "GLM-5.3-Flash", modelType: "glm5_next"),
        .init(name: "GLM-5.3-Flash pair", modelType: "glm5_next", glmPair: true),
    ]

    /// `read(path, i)`, both required, as oh-my-pi declares its tools.
    static func tool(_ shape: Shape) -> String {
        let intent = switch shape {
        case .untypedParameter: #"{"description":"intent"}"#
        case .nullableUnionParameter: #"{"anyOf":[{"type":"string"},{"type":"null"}],"default":null}"#
        case .mismatchedType: #"{"type":"integer"}"#
        default: #"{"type":"string"}"#
        }
        return #"{"type":"function","function":{"name":"read","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"},"i":"#
            + intent + #"},"required":["path","i"]"#
            + (shape == .undeclaredWithAdditionalPropertiesFalse ? #","additionalProperties":false"# : "") + "}}}"
    }

    static func arguments(_ shape: Shape) -> [(String, String)] {
        switch shape {
        case .missingRequired: [("path", "CONTEXT.md")]
        case .undeclaredWithoutAdditionalProperties, .undeclaredWithAdditionalPropertiesFalse:
            [("path", "CONTEXT.md"), ("i", "read it"), ("extra", "more")]
        case .untypedParameter, .nullableUnionParameter, .mismatchedType: [("path", "CONTEXT.md"), ("i", "read it")]
        }
    }

    /// One `read` call in the family's native frame; every value a string.
    static func frame(_ modelType: String, _ arguments: [(String, String)]) -> String {
        let json = "{" + arguments.map { "\"\($0.0)\":\"\($0.1)\"" }.joined(separator: ",") + "}"
        switch modelType {
        case "gemma4":
            return "<|tool_call>call:read{" + arguments.map { "\($0.0):<|\"|>\($0.1)<|\"|>" }.joined(separator: ",")
                + "}<tool_call|>"
        case "gpt_oss":
            return "<|start|>assistant to=functions.read<|channel|>commentary json<|message|>" + json + "<|call|>"
        case "glm5_next":
            return "<tool_call>read" + arguments.map { "<arg_key>\($0.0)</arg_key><arg_value>\($0.1)</arg_value>" }
                .joined() + "</tool_call>"
        case "mimo_v2":
            return "<tool_call><function=read>" + arguments.map { "<parameter=\($0.0)>\($0.1)</parameter>" }.joined()
                + "</function></tool_call>"
        default:
            return "<tool_call>\n<function=read>\n" + arguments.map { "<parameter=\($0.0)>\n\($0.1)\n</parameter>\n" }
                .joined() + "</function>\n</tool_call>"
        }
    }

    struct Outcome {
        var calls: [ToolCall] = []
        var visible = ""
        var failure: MultiModelBatchSchedulerEngineError?
        var markupLeaked: Bool {
            ["<tool_call", "tool_call>", "<|tool_call>", "<|start|>", "<arg_key>", "<function="]
                .contains { visible.contains($0) }
        }
    }

    /// `streams`: the client streams, so a family whose parser exposes calls
    /// while generated does.
    static func run(_ family: Family, output: String, tool: String, streams: Bool) async throws -> Outcome {
        var body = try #require(JSONSerialization.jsonObject(with: Data((#"{"model":"fixture","messages":[{"role":"user","content":"Read CONTEXT.md now."}],"tools":["#
            + tool + #"],"tool_choice":"auto","stream":"# + (streams ? "true" : "false") + "}").utf8)) as? [String: Any])
        body["max_tokens"] = 600
        var request = try ProviderLoop.decodeOpenAIRequest(JSONSerialization.data(withJSONObject: body))
        request.streamToolCallDeltas = streams
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: family.modelType,
            glm5PairPostValidation: family.glmPair)
        prepared.cutAnswersEndAtLength = true
        let handler = try #require(try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
            modelType: family.modelType, streamToolCalls: streams))
        let upstream = AsyncStream<GenerationEvent> { continuation in
            let characters = Array(output)
            for start in stride(from: 0, to: characters.count, by: 3) {
                continuation.yield(.chunk(String(characters[start ..< min(start + 3, characters.count)])))
            }
            continuation.yield(.info(promptTokens: 1, completionTokens: 1, tokensPerSecond: 1, finishReason: "stop"))
            continuation.finish()
        }
        let stream = try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: "fixture"), toolHandler: handler,
            nativeMiMoChannels: family.modelType == "mimo_v2")
        var outcome = Outcome()
        do {
            for try await event in stream {
                switch event {
                case .toolCall(let call): outcome.calls.append(call)
                case .toolCallDelta(let delta): if let call = delta.completed { outcome.calls.append(call) }
                case .content(let text): outcome.visible += text
                case .parsed(let value): outcome.visible += value.content
                default: break
                }
            }
        } catch { outcome.failure = try #require(error as? MultiModelBatchSchedulerEngineError) }
        return outcome
    }

    @Test(arguments: families, [false, true])
    func aCallThatBreaksOnlyItsSchemaIsACall(family: Family, streams: Bool) async throws {
        for shape in Shape.allCases {
            let result = try await Self.run(family, output: Self.frame(family.modelType, Self.arguments(shape)),
                tool: Self.tool(shape), streams: streams)
            #expect(result.failure == nil, "\(family.name) \(shape)")
            #expect(result.calls.map(\.function.name) == ["read"], "\(family.name) \(shape)")
            #expect(!result.markupLeaked, "\(family.name) \(shape): \(result.visible)")
        }
    }

    @Test(arguments: families, [false, true])
    func aParallelBatchKeepsEveryCall(family: Family, streams: Bool) async throws {
        for shape in Shape.allCases {
            let valid = Self.frame(family.modelType, [("path", "a.md"), ("i", shape == .mismatchedType ? "1" : "first")])
            let output = valid + "\n" + Self.frame(family.modelType, Self.arguments(shape)) + "\n" + valid
            let result = try await Self.run(family, output: output, tool: Self.tool(shape), streams: streams)
            #expect(result.failure == nil, "\(family.name) \(shape)")
            #expect(result.calls.count == 3, "\(family.name) \(shape): \(result.visible)")
            #expect(!result.markupLeaked, "\(family.name) \(shape): \(result.visible)")
        }
    }

    /// The switch restores 0.10.13's GLM run rule with the parser's refusals:
    /// one refused member makes the whole run text.
    @Test func theSwitchRestoresTheWholeRunRule() throws {
        let tools: [[String: any Sendable]] = [["type": "function", "function": [
            "name": "read",
            "parameters": ["type": "object", "properties": ["path": ["type": "string"] as [String: any Sendable]]
                as [String: any Sendable], "required": ["path"]] as [String: any Sendable],
        ] as [String: any Sendable]]]
        let good = "<tool_call>read<arg_key>path</arg_key><arg_value>a.md</arg_value></tool_call>"
        let suffix = "Use <tool_call>.</think>" + good + "<tool_call>read</tool_call>"
        guard case .text(let text, let calls) = GLM5ToolSuffix.split(suffix, tools: tools, grammarOnly: true) else {
            Issue.record("expected text and calls")
            return
        }
        #expect(text == "Use <tool_call>.</think>" && calls.count == 2)
        #expect(GLM5ToolSuffix.split(suffix, tools: tools, grammarOnly: false) == .text(suffix, calls: []))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(GrammarOnlyToolParsing.environmentKey))
    }

    /// Off, values are read as 0.10.13 read them too: an object-typed value
    /// that is not JSON breaks its frame, which owns the rest of the response.
    @Test func theSwitchRestoresTheValueReading() throws {
        let object: [String: any Sendable] = ["type": "object"]
        let text: [String: any Sendable] = ["type": "string"]
        let tools: [[String: any Sendable]] = [
            ["type": "function", "function": ["name": "store", "parameters": ["type": "object",
                "properties": ["doc": object] as [String: any Sendable]] as [String: any Sendable]] as [String: any Sendable]],
            ["type": "function", "function": ["name": "echo", "parameters": ["type": "object",
                "properties": ["text": text] as [String: any Sendable]] as [String: any Sendable]] as [String: any Sendable]],
        ]
        let bad = "<tool_call>store<arg_key>doc</arg_key><arg_value>{bad}</arg_value></tool_call>"
        let echo = "<tool_call>echo<arg_key>text</arg_key><arg_value>hi</arg_value></tool_call>"
        let draft = "Draft " + bad + "PRIVATE</think>Answer"
        #expect(GLM5ToolSuffix.split(bad + echo, tools: tools, grammarOnly: false) == .text(bad + echo, calls: []))
        #expect(GLM5ToolSuffix.split(draft, tools: tools, grammarOnly: false) == .ambiguous)
        guard case .text("", let calls) = GLM5ToolSuffix.split(bad + echo, tools: tools, grammarOnly: true) else {
            Issue.record("expected two calls")
            return
        }
        #expect(calls.map { $0.function.arguments } == [["doc": .string("{bad}")], ["text": .string("hi")]])
        #expect(GLM5ToolSuffix.split(draft, tools: tools, grammarOnly: true) == .text(draft, calls: []))
    }
}
#endif
