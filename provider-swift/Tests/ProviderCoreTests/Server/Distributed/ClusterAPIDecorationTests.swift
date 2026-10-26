import Foundation
import Hummingbird
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// The cluster's API decorates its own frames as the coordinator path does:
/// token logprobs on the next content-bearing frame, reasoning tokens on the
/// usage frame, both on a collected completion. Model-free.
@Suite struct ClusterAPIDecorationTests {
    typealias Responder = LocalChatUploadResponder<RouterResponder<BasicRequestContext>>

    static func entry(_ token: String, top: [String]) -> SSETokenLogprob {
        .init(token: token, logprob: -0.25, bytes: Array(token.utf8).map(Int.init),
              topLogprobs: top.map { .init(token: $0, logprob: -1, bytes: nil) })
    }

    /// One chat-completion chunk frame as the service writes it.
    static func frame(_ object: [String: Any]) -> String {
        var object = object
        object["id"] = "chatcmpl-1"; object["created"] = 1; object["model"] = "m"
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
    }

    static func payload(_ frame: String) -> [String: Any]? {
        guard let line = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
    }

    @Test func topLogprobsAreCutToTheRequestedCount() {
        let entries = [Self.entry("a", top: ["a", "b"])]
        #expect(Responder.requested(entries, top: nil).first?.topLogprobs.isEmpty == true)
        #expect(Responder.requested(entries, top: 1).first?.topLogprobs.map(\.token) == ["a"])
        #expect(Responder.requested(entries, top: 5).first?.topLogprobs.count == 2)
    }

    @Test func streamedFramesCarryLogprobsAndReasoningTokens() async throws {
        let channel = EngineV2LogprobsChannel()
        let plumbing = EngineV2LogprobsPlumbing(topLogprobs: 1, channel: channel)
        let frames = [
            Self.frame(["object": "chat.completion.chunk", "choices": [["index": 0, "delta": ["role": "assistant"]]]]),
            Self.frame(["object": "chat.completion.chunk",
                        "choices": [["index": 0, "delta": ["reasoning_content": "think think"]]]]),
            Self.frame(["object": "chat.completion.chunk", "choices": [["index": 0, "delta": ["content": "Hi"]]]]),
            Self.frame(["object": "chat.completion.chunk", "choices": [] as [Any],
                        "usage": ["prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7]]),
        ]
        let source = AsyncThrowingStream<String, Error> { continuation in
            channel.append([Self.entry("think", top: ["think", "x"]), Self.entry("Hi", top: ["Hi", "y"])])
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
        var out: [String] = []
        for try await frame in Responder.decorating(source, logprobs: plumbing,
                                                     countTokens: { $0.split(separator: " ").count }) {
            out.append(frame)
        }
        #expect(out.count == 4)
        #expect(out[0] == frames[0] && out[1] == frames[1])
        let content = try #require(Self.payload(out[2]))
        let choice = try #require((content["choices"] as? [[String: Any]])?.first)
        let entries = try #require((choice["logprobs"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(entries.map { $0["token"] as? String } == ["think", "Hi"])
        #expect(entries.allSatisfy { ($0["top_logprobs"] as? [Any])?.count == 1 })
        let usage = try #require(Self.payload(out[3])?["usage"] as? [String: Any])
        #expect((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int == 2)
    }

    @Test func framesPassThroughWithoutDecorations() async throws {
        let source = AsyncThrowingStream<String, Error> { $0.yield("data: [DONE]\n\n"); $0.finish() }
        var out: [String] = []
        for try await frame in Responder.decorating(source, logprobs: nil, countTokens: nil) { out.append(frame) }
        #expect(out == ["data: [DONE]\n\n"])
    }

    @Test func aCollectedCompletionCarriesLogprobsAndReasoningTokens() throws {
        let channel = EngineV2LogprobsChannel()
        channel.append([Self.entry("Hi", top: ["Hi"])])
        let completion = OpenAIChatCompletionResponse(id: "chatcmpl-1", model: "m", choices: [
            .init(index: 0, message: .init(role: .assistant, content: .text("Hi"), reasoningContent: "one two three"),
                  finishReason: "stop")], usage: .init(promptTokens: 3, completionTokens: 5))
        let bytes = try #require(try Responder.decoratedJSON(completion,
            logprobs: .init(topLogprobs: 0, channel: channel), countTokens: { $0.split(separator: " ").count }))
        let object = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let choice = try #require((object["choices"] as? [[String: Any]])?.first)
        let entries = try #require((choice["logprobs"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(entries.count == 1 && (entries[0]["top_logprobs"] as? [Any])?.isEmpty == true)
        let usage = try #require(object["usage"] as? [String: Any])
        #expect((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int == 3)
    }
}
