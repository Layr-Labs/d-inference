#if DEBUG
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// GLM-5.3-Flash tool calls to a client that streams, through the production
/// coordinator handler from scripted engine output (not a model-quality
/// assertion). The prompt opens the thought, as GLM's template does.
@Suite("GLM-5.3-Flash streamed tool calls", .serialized)
struct GLM5StreamedToolCallTests {
    static let modelID = "test/glm5-streamed-tools"

    static let writeTool = #"{"type":"function","function":{"name":"write_file","parameters":{"type":"object","#
        + #""properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}"#
    static let storeTool = #"{"type":"function","function":{"name":"store","parameters":{"type":"object","#
        + #""properties":{"doc":{"type":"object"},"path":{"type":"string"}},"required":["doc"]}}}"#

    static let auto = #""auto""#
    static let required = #""required""#
    static let named = #"{"type":"function","function":{"name":"write_file"}}"#

    static func write(_ path: String, _ content: String) -> String {
        "<tool_call>write_file<arg_key>path</arg_key><arg_value>\(path)</arg_value>"
            + "<arg_key>content</arg_key><arg_value>\(content)</arg_value></tool_call>"
    }

    /// One engine delta per frame tag, value and line.
    static func pieces(_ output: String) -> [String] {
        GLM5NextToolCallRelayTests.pieces(output).flatMap { piece in
            piece.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
                index == 0 ? String(line) : "\n" + line
            }.filter { !$0.isEmpty }
        }
    }

    typealias Script = (AsyncStream<CBv2Event>.Continuation, ScriptedCoordinatorRelay.Progress) async throws -> Void

    static func relay(choice: String, stream: Bool = true, tools: [String] = [writeTool],
                      parallel: Bool? = nil, extra: [String] = [], script: Script)
        async throws -> GLM5NextToolCallRelayTests.RelayRun
    {
        var fields = [
            #""model":"\#(modelID)""#,
            #""messages":[{"role":"user","content":"Write long.py now."}]"#,
            #""max_tokens":2000"#, #""stream":\#(stream)"#,
            #""tools":["# + tools.joined(separator: ",") + "]",
            #""tool_choice":"# + choice,
        ] + extra
        if let parallel { fields.append(#""parallel_tool_calls":\#(parallel)"#) }
        let tokenizer = TokenizerHandle(try GLM5NextThinkingTokenizer(base: GLMVisibilityTokenizer()))
        let output = try await ScriptedCoordinatorRelay.run(modelID: modelID, modelType: "glm5_next",
            tokenizer: tokenizer, containerTokenizer: GLMVisibilityTokenizer(),
            eosTokenIds: GLM5NextReasoningVisibilityTests.stops, requestID: "glm-streamed-tools",
            fields: fields, script: script)
        return try GLM5NextToolCallRelayTests.parse(output)
    }

    /// The whole output in one script: one delta per piece, then the finish.
    static func relay(choice: String, stream: Bool = true, tools: [String] = [writeTool], parallel: Bool? = nil,
                      output: [String], finish: CBv2FinishReason = .stop)
        async throws -> GLM5NextToolCallRelayTests.RelayRun
    {
        try await relay(choice: choice, stream: stream, tools: tools, parallel: parallel) { continuation, _ in
            for chunk in output { continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil)) }
            continuation.yield(.finished(reason: finish, usage: .init(promptTokens: 1, completionTokens: 300)))
            continuation.finish()
        }
    }

    static func arguments(_ call: (name: String, arguments: String)) throws -> [String: MLXLMCommon.JSONValue] {
        try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(call.arguments.utf8))
    }

    // MARK: - Red: a long tool answer had no first content before the end

    /// GLM held every tool answer back until generation ended (`.glm5` was
    /// not a streamed format, and forced calls were withheld), so a long one
    /// missed the coordinator's first-content deadline. The call's name must
    /// reach the wire while its arguments are still being generated, in every
    /// tool_choice mode, and the call a client rebuilds is the whole call.
    @Test(arguments: [auto, required, named])
    func longGLMCallsReachTheWireBeforeTheirFrameCloses(choice: String) async throws {
        let content = String(repeating: "print('long answer')\n", count: 40)
        let call = Self.write("long.py", content)
        let head = "<tool_call>write_file<arg_key>path</arg_key><arg_value>long.py</arg_value>"
            + "<arg_key>content</arg_key><arg_value>print("
        var early = false
        let run = try await Self.relay(choice: choice) { continuation, progress in
            for chunk in ["Plan.", "</think>"] + Self.pieces(head) {
                continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil))
            }
            // Most of the answer has not been generated yet.
            try await progress.wait { $0.contains { $0.contains("\"tool_calls\"") } }
            early = try progress.frames().contains { $0.contains("\"tool_calls\"") }
            for chunk in Self.pieces(String(call.dropFirst(head.count))) {
                continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil))
            }
            continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 1, completionTokens: 300)))
            continuation.finish()
        }
        #expect(early, "\(choice): the call's first content must leave before its frame closes")
        #expect(run.errors.isEmpty, "\(choice): \(run.errors)")
        #expect(run.finishReason == "tool_calls", "\(choice)")
        #expect(run.calls.map(\.name) == ["write_file"], "\(choice)")
        #expect(try run.calls.map(Self.arguments) == [["path": .string("long.py"), "content": .string(content)]],
            "\(choice)")
        #expect(run.content.isEmpty, "\(choice)")
        #expect(run.reasoning == "Plan.", "\(choice)")
    }
}
#endif
