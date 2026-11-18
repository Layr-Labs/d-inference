#if DEBUG
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// GLM-5.3-Flash tool calls through the production coordinator handler, from
/// scripted engine output (not a model-quality assertion). The provider
/// streams to the coordinator whether the client streams or not.
@Suite("GLM-5.3-Flash tool calls over the coordinator relay", .serialized)
struct GLM5NextToolCallRelayTests {
    static let modelID = "test/glm5-tools"

    /// A call that omits a required argument leaves as a call, with
    /// `finish_reason: tool_calls` and no content, as do its parallel calls.
    @Test(arguments: [true, false])
    func aCallMissingARequiredArgumentLeavesAsACall(stream: Bool) async throws {
        let call = GLM5ToolFailureTests.read("CONTEXT.md")
        for (output, paths) in [
            (call, ["CONTEXT.md"]),
            (GLM5ToolFailureTests.read("a.md", intent: "first") + "\n" + call, ["a.md", "CONTEXT.md"]),
        ] {
            let run = try await relay(stream: stream, chunks: ["Read it.", "</think>"] + Self.pieces(output))
            #expect(run.errors.isEmpty, "\(run.errors)")
            #expect(run.finishReason == "tool_calls")
            #expect(run.content.isEmpty)
            #expect(run.reasoning == "Read it.")
            #expect(run.calls.map(\.name) == Array(repeating: "read", count: paths.count))
            let arguments = try run.calls.map {
                try #require(JSONSerialization.jsonObject(with: Data($0.arguments.utf8)) as? [String: String])
            }
            #expect(arguments.compactMap { $0["path"] } == paths)
        }
    }

    /// One engine delta per frame tag or value.
    static func pieces(_ output: String) -> [String] {
        output.replacingOccurrences(of: "<", with: "\u{0}<").split(separator: "\u{0}").map(String.init)
    }

    struct RelayRun {
        var content = ""
        var reasoning = ""
        var calls: [(name: String, arguments: String)] = []
        /// Frames carrying `tool_calls`.
        var toolFrames = 0
        var finishReason: String?
        var errors: [InferenceFailure] = []
    }

    func relay(stream: Bool, chunks: [String]) async throws -> RelayRun {
        let fields = [
            #""model":"\#(Self.modelID)""#,
            #""messages":[{"role":"system","content":"When calling read, ONLY pass the path argument. Never pass i."},{"role":"user","content":"Read CONTEXT.md now."}]"#,
            #""max_tokens":600"#, #""stream":\#(stream)"#,
            #""tools":["# + GLM5ToolFailureTests.readTool() + "]",
        ]
        let tokenizer = TokenizerHandle(try GLM5NextThinkingTokenizer(base: GLMVisibilityTokenizer()))
        let output = try await ScriptedCoordinatorRelay.run(modelID: Self.modelID, modelType: "glm5_next",
            tokenizer: tokenizer, containerTokenizer: GLMVisibilityTokenizer(),
            eosTokenIds: GLM5NextReasoningVisibilityTests.stops, requestID: "glm-tools-request",
            fields: fields) { continuation, _ in
            for chunk in chunks {
                continuation.yield(.delta(text: chunk, tokens: [5], logprobs: nil))
            }
            continuation.yield(.finished(reason: .stop, usage: .init(promptTokens: 1, completionTokens: 20)))
            continuation.finish()
        }
        return try Self.parse(output)
    }

    /// The content, reasoning, calls (rebuilt from their fragments by index),
    /// finish reason and errors a client reads from the relay's frames.
    static func parse(_ output: ScriptedCoordinatorRelay.Output) throws -> RelayRun {
        var run = RelayRun()
        for frame in output.frames {
            for line in frame.split(separator: "\n") where line.hasPrefix("data: ") && line != "data: [DONE]" {
                guard let object = try JSONSerialization.jsonObject(
                    with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                    let choice = (object["choices"] as? [[String: Any]])?.first
                else { continue }
                if let reason = choice["finish_reason"] as? String { run.finishReason = reason }
                guard let delta = choice["delta"] as? [String: Any] else { continue }
                run.content += delta["content"] as? String ?? ""
                run.reasoning += delta["reasoning_content"] as? String ?? ""
                if delta["tool_calls"] != nil { run.toolFrames += 1 }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any]
                    let index = call["index"] as? Int ?? 0
                    if index == run.calls.count {
                        run.calls.append((function?["name"] as? String ?? "", ""))
                    }
                    run.calls[index].arguments += function?["arguments"] as? String ?? ""
                }
            }
        }
        for case .inferenceError(_, let failure, _) in output.terminals {
            run.errors.append(failure)
        }
        return run
    }
}
#endif
