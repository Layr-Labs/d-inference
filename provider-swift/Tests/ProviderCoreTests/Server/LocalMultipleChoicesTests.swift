// Copyright © 2026 Eigen Labs.

import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// The local API answers a request for more than one choice as the coordinator
/// answers it (`refuseMultipleChoices`): a 400 before the engine sees the
/// request, not one choice for the `n` asked.
struct LocalMultipleChoicesTests {
    private static func app(_ engine: LocalChoiceCountFixture) -> some ApplicationProtocol {
        let upload = LocalChatUploadResponder(inner: Router<BasicRequestContext>().buildResponder(),
                                              service: MLXOpenAIService(engine: engine))
        return Application(responder: CORSResponder(inner: upload),
                           configuration: .init(address: .hostname("127.0.0.1", port: 0)))
    }

    private static func chat(_ fields: String, role: String = "user") -> String {
        #"{"model":"fixture"\#(fields),"messages":[{"role":"\#(role)","content":"hi"}]}"#
    }

    @Test("n > 1 is a 400 naming n, streamed or not, before the engine sees it",
          arguments: ["2", "8", "2.0", "2.5"])
    func refused(n: String) async throws {
        let engine = LocalChoiceCountFixture()
        try await Self.app(engine).test(.router) { client in
            var bodies = [false, true].map { Self.chat(#","stream":\#($0),"n":\#(n)"#) }
            // A body that needs the ingress repair (a `developer` message) is refused the same way.
            bodies.append(Self.chat(#","n":\#(n)"#, role: "developer"))
            for (uri, body) in bodies.map({ ("/v1/chat/completions", $0) })
                + [("/chat/completions", bodies[0]), ("/v1/chat/completions/batch", "[\(Self.chat("")),\(bodies[0])]")] {
                try await client.execute(uri: uri, method: .post, headers: [.contentType: "application/json"],
                                         body: ByteBuffer(string: body)) { response in
                    #expect(response.status == .badRequest, "\(uri) \(body)")
                    #expect(response.headers[.contentType] == "application/json")
                    let envelope = try #require(JSONSerialization.jsonObject(
                        with: Data(String(buffer: response.body).utf8)) as? [String: Any])
                    let error = try #require(envelope["error"] as? [String: Any])
                    #expect(error["message"] as? String == "n > 1 is not supported")
                    #expect(error["type"] as? String == "invalid_request_error")
                    #expect(error["param"] as? String == "n")
                }
            }
        }
        #expect(engine.calls == 0)
    }

    @Test("n absent, null, 0, 1, below 2 or not a number is served as before",
          arguments: ["", #","n":null"#, #","n":0"#, #","n":1"#, #","n":1.5"#, #","n":"2""#, #","n":true"#])
    func served(field: String) async throws {
        let engine = LocalChoiceCountFixture()
        try await Self.app(engine).test(.router) { client in
            for stream in [false, true] {
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                                         headers: [.contentType: "application/json"],
                                         body: ByteBuffer(string: Self.chat(#","stream":\#(stream)\#(field)"#))) {
                    #expect($0.status == .ok, "\(field) stream=\(stream)")
                }
            }
        }
        #expect(engine.calls == 2)
    }
}

/// Counts the requests that reach the engine; each one answers "ok".
private final class LocalChoiceCountFixture: MLXServerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func availableModels() async throws -> [MLXServerModel] { [.init(id: "fixture")] }
    func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws
        -> AsyncThrowingStream<MLXServerGenerationEvent, Error>
    {
        lock.withLock { count += 1 }
        return AsyncThrowingStream { continuation in
            continuation.yield(.content("ok"))
            continuation.finish()
        }
    }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: [1]) }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "ok") }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: [1]) }
}
