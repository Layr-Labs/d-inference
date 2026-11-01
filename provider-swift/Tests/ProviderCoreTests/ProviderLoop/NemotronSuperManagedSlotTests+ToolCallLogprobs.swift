// Copyright © 2026 Eigen Labs.

import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Testing
@testable import ProviderCore

/// Logprob entries of a reply that calls a tool, on one managed owner: the
/// relay, the local endpoint's stream and its complete response carry the same
/// entries. A reply that ends with its call carries those of its reasoning and
/// answer tokens, in generation order, and none for the call's tokens.
extension NemotronSuperManagedSlotTests {
    @Test(.timeLimit(.minutes(3)))
    func toolCallReplyCarriesTheSameLogprobsOnEveryPath() async throws {
        let fixture = try await Self.fixture(mode: .auto)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let call = ["<tool_call>", "\n<function=get_weather>", "\n<parameter=city>", "\nParis",
                    "\n</parameter>", "\n</function>", "\n</tool_call>"]
        @Sendable func thinkingOn(stream: Bool = true) -> [String: Any] {
            ["stream": stream, "logprobs": true, "top_logprobs": 2, "chat_template_kwargs": ["enable_thinking": true],
             "tools": [["type": "function", "function": ["name": "get_weather", "parameters": ["type": "object",
                 "properties": ["city": ["type": "string"]], "required": ["city"]]]]]]
        }
        // Every request renders the same prompt tokens and decodes greedily, so
        // entry N of any reply belongs to generated token N: a plain reply's
        // entries name each position.
        let plain = (0..<12).map { "w\($0)" }
        let positions = SuperSSE(try await Self.send(Self.body(plain, script: script, ["logprobs": true,
            "top_logprobs": 2]), to: loop, recorder: recorder, consumer: consumer).sse).logprobs
        #expect(positions.count == plain.count)
        // Each reply and the leading tokens whose entries it carries: its
        // reasoning, then `</think>` with the answer when one precedes the call.
        // Text after the call (Super's own call turns end with a newline after
        // `</tool_call>`) shows, so every entry before it rides it on each path.
        let replies: [(label: String, pieces: [String], carried: Int)] = [
            ("reasoning, then a call", ["Use tool.", "</think>"] + call, 1),
            ("reasoning and an answer, then a call", ["Use tool.", "</think>", "Checking", " Paris."] + call, 4),
            ("a call, then a newline", ["Use tool.", "</think>"] + call + ["\n"], 10),
        ]
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "super-managed"), defaultMaxTokens: 16,
            acquire: { id in try await loop.acquireModelForLocal(id) },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { [Self.modelID] }, mtpSlots: { [] },
            managedSuperEngine: { body, request, logprobs in
                guard request.model == Self.modelID else { return nil }
                return NemotronSuperLocalEndpointEngine(body: body, hasMedia: false, cacheScope: "local",
                    acquire: { try await loop.acquireNemotronSuperForLocal(Self.modelID) }, logprobs: logprobs)
            })
        try await app.test(.live) { client in
            let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer super-managed"]
            func local(_ pieces: [String], stream: Bool) async throws -> String {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                    body: ByteBuffer(bytes: try Self.body(pieces, script: script, thinkingOn(stream: stream)))) { response in
                    #expect(response.status == .ok)
                    return String(buffer: response.body)
                }
            }
            for reply in replies {
                let relayed = SuperSSE(try await Self.send(Self.body(reply.pieces, script: script, thinkingOn()),
                    to: loop, recorder: recorder, consumer: consumer).sse)
                let streamed = SuperSSE(try await local(reply.pieces, stream: true))
                let complete = try SuperJSON(try await local(reply.pieces, stream: false))
                for calls in [relayed.toolCalls, streamed.toolCalls, complete.toolCalls] {
                    #expect(calls.map(\.name) == ["get_weather"] && calls.map(\.arguments) == [#"{"city":"Paris"}"#],
                            "\(reply.label)")
                }
                #expect(relayed.reasoning == "Use tool." && relayed.textlessFrameLogprobs == 0, "\(reply.label)")
                #expect(relayed.logprobs == Array(positions.prefix(reply.carried)), "\(reply.label): relay")
                #expect(streamed.logprobs == relayed.logprobs, "\(reply.label): local stream")
                #expect(complete.logprobs == relayed.logprobs, "\(reply.label): local complete")
            }
        }
        #expect(await loop.unloadModel(Self.modelID))
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }
}
