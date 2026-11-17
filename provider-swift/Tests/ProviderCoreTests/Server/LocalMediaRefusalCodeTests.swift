import Foundation
import Hummingbird
import Logging
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

private struct MediaRefusingResponder: HTTPResponder {
    typealias Context = BasicRequestContext
    func respond(to request: Request, context: Context) async throws -> Response {
        throw MultiModelBatchSchedulerEngineError.mediaUnsupportedByModel("gemma-4-26b-qat-4bit")
    }
}

/// Journey 3 on pair-2 (D5): an image sent to Gemma 4 on a pair, which serves it text only, was refused 400 "Media
/// input is not supported." with no `code`. Every local API (one Mac's and a pair's answer through this one responder)
/// gives that refusal the typed code this Mac's provider gives the coordinator for it
/// (`InferenceFailureCode.unsupportedMedia`), so a client can tell it from any other 400.
@Test func mediaTheModelDoesNotTakeIsA400WithTheTypedCode() async throws {
    let responder = CORSResponder(inner: MediaRefusingResponder())
    let request = Request(
        head: .init(method: .post, scheme: "http", authority: "localhost", path: "/v1/chat/completions"),
        body: .init(buffer: ByteBuffer()))
    let context = BasicRequestContext(source: ApplicationRequestContextSource(
        channel: EmbeddedChannel(), logger: Logger(label: "media-refusal-code")))
    let response = try await responder.respond(to: request, context: context)
    #expect(response.status == .badRequest)
    let capture = HTTPOriginCapture()
    try await response.body.write(HTTPOriginWriter(capture: capture))
    let object = try JSONSerialization.jsonObject(with: Data(capture.output.utf8)) as? [String: Any]
    let error = try #require(object?["error"] as? [String: Any])
    #expect(error["code"] as? String == InferenceFailureCode.unsupportedMedia.rawValue)
    #expect(error["code"] as? String == "unsupported_media")
    #expect(error["message"] as? String == "Media input is not supported.")
    #expect(error["type"] as? String == "invalid_request_error")
}
