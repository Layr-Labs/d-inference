import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

struct LocalStreamingFailureTests {
    @Test(arguments: ["/v1/chat/completions", "/chat/completions"])
    func interceptedChatKeepsAuthAndFramesLateFailure(path: String) async throws {
        let router = Router<BasicRequestContext>()
        let service = MLXOpenAIService(engine: LocalFailureFixture())
        let upload = LocalChatUploadResponder(inner: router.buildResponder(), service: service)
        let app = Application(responder: LocalAuthResponder(
            inner: CORSResponder(inner: upload), token: "synthetic-fixture-token"),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        let body = ByteBuffer(string:
            #"{"model":"fixture","stream":true,"messages":[{"role":"user","content":"hi"}]}"#)
        try await app.test(.router) { client in
            try await client.execute(uri: path, method: .post,
                headers: [.contentType: "application/json"], body: body) { response in
                #expect(response.status == .unauthorized)
            }
            try await client.execute(uri: path, method: .post,
                headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                body: body) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.accessControlAllowOrigin] == "*")
                let text = String(buffer: response.body)
                #expect(text.contains("classified reasoning"))
                #expect(!text.contains("sensitive_fixture_detail"))
                #expect(!text.contains("[DONE]"))
                let lines = text.components(separatedBy: "\n").filter { $0.hasPrefix("data: ") }
                let last = try #require(lines.last)
                let event = try #require(JSONSerialization.jsonObject(
                    with: Data(last.dropFirst(6).utf8)) as? [String: Any])
                let error = try #require(event["error"] as? [String: Any])
                #expect(error["message"] as? String == "Response generation failed")
                let choices = try #require(event["choices"] as? [[String: Any]])
                #expect(choices.first?["finish_reason"] as? String == "error")
            }
        }
    }
}

private struct LocalFailureFixture: MLXServerEngine {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "sensitive_fixture_detail" }
    }
    func availableModels() async throws -> [MLXServerModel] { [.init(id: "fixture")] }
    func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws
        -> AsyncThrowingStream<MLXServerGenerationEvent, Error>
    {
        AsyncThrowingStream { continuation in
            continuation.yield(.parsed(.init(content: "", reasoningContent: "classified reasoning")))
            continuation.finish(throwing: Failure())
        }
    }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: [1]) }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "ok") }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: [1]) }
}
