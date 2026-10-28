import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import MLXLMServer
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

/// The local API (one Mac's and a pair's: the same application) refuses a content part type no engine serves with a
/// 400 that names the type, before any model is acquired, instead of answering from the text that is left; and a
/// `response_format` answer cut off by `max_tokens` says so.
@Suite("Local API request honesty")
struct LocalContentPartRefusalTests {
    @Test(arguments: [false, true])
    func unknownPartTypesAre400NamingTheTypeBeforeAcquisition(streaming: Bool) async throws {
        let spy = PartRefusalSpy()
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "synthetic-fixture-token"),
            defaultMaxTokens: 32,
            acquire: { id in
                await spy.mark()
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id)
            },
            tokenizerProvider: { _ in
                throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
            },
            availableModels: { ["fixture"] }, mtpSlots: { [] })
        try await app.test(.router) { client in
            for type in ["input_file", "input_video", "refusal"] {
                let part = #"{"type":"\#(type)","file_id":"file-fixture"}"#
                let chat = #"{"model":"fixture","messages":[{"role":"user","content":[{"type":"text","text":"Summarize it."},\#(part)]}],"stream":\#(streaming)}"#
                for (path, body) in [
                    ("/v1/chat/completions", chat), ("/chat/completions", chat), ("/v1/chat/completions/batch", "[" + chat + "]"),
                    ("/v1/responses", #"{"model":"fixture","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"Summarize it."},\#(part)]}],"stream":\#(streaming)}"#),
                ] {
                    try await client.execute(uri: path, method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer synthetic-fixture-token"],
                        body: ByteBuffer(string: body)) { response in
                        #expect(response.status == .badRequest, "\(path) \(type)")
                        let text = String(buffer: response.body)
                        let error = try JSONDecoder().decode(OpenAIErrorResponse.self, from: Data(text.utf8))
                        #expect(error.error.type == "invalid_request_error")
                        #expect(error.error.message == "Content part type \"\(type)\" is not supported. "
                            + "Send text, image_url, video_url or input_audio parts.", "\(path): \(error.error.message)")
                        #expect(!text.contains("data:"))
                    }
                }
            }
        }
        #expect(await spy.count == 0)
    }

    @Test func aResponseFormatAnswerCutOffByMaxTokensSaysSo() async throws {
        let context = BasicRequestContext(source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(), logger: Logger(label: #function)))
        func render(_ error: MLXOpenAIServiceError) async throws -> (HTTPResponse.Status, String?) {
            let request = Request(head: .init(method: .post, scheme: "http", authority: "localhost", path: "/v1/chat/completions"),
                                  body: .init(buffer: ByteBuffer()))
            let response = try await CORSResponder(inner: PartRefusalThrowingResponder(error: error)).respond(to: request, context: context)
            let body = PartRefusalCollectedBody()
            try await response.body.write(body)
            let envelope = try JSONSerialization.jsonObject(with: Data(String(buffer: body.bytes).utf8)) as? [String: Any]
            return (response.status, (envelope?["error"] as? [String: Any])?["message"] as? String)
        }
        let (status, message) = try await render(.responseFormatCutOffByMaxTokens)
        #expect(status == .unprocessableContent)
        #expect(message == MLXOpenAIServiceError.responseFormatCutOffByMaxTokens.errorDescription)
        #expect(message?.contains("max_tokens") == true)
        // Malformed JSON keeps the closed message (no generated text in the error).
        let (invalidStatus, invalid) = try await render(.invalidResponseFormatOutput("model output was not valid JSON"))
        #expect(invalidStatus == .unprocessableContent)
        #expect(invalid == InferenceFailureCode.internalFailure.message)
        // On the coordinator path: the request's own limit, a client error with the closed vocabulary.
        let error = MLXOpenAIServiceError.responseFormatCutOffByMaxTokens
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422)
        #expect(classifyTypedInferenceErrorReason(error) == .clientError)
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation)
        #expect(failure.statusCode == 422 && failure.code == .invalidRequest && failure.errorReason == .clientError)
        #expect(failure.message == InferenceFailureCode.invalidRequest.message)
        // The shared preparation's refusals are 400s on both paths.
        #expect(ProviderLoop.mapInferenceErrorToStatus(OpenAIRequestValidationError.unsupportedContentPart(type: "input_file")) == 400)
    }
}

private actor PartRefusalSpy {
    var count = 0
    func mark() { count += 1 }
}

private struct PartRefusalThrowingResponder<E: Error>: HTTPResponder {
    typealias Context = BasicRequestContext
    let error: E
    func respond(to request: Request, context: Context) async throws -> Response { throw error }
}

private final class PartRefusalCollectedBody: ResponseBodyWriter, @unchecked Sendable {
    var bytes = ByteBuffer()
    func write(_ buffer: ByteBuffer) async throws {
        var buffer = buffer
        bytes.writeBuffer(&buffer)
    }
    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}
