import Foundation
import Hummingbird
import Logging
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

private struct SpentBudgetResponder: HTTPResponder {
    typealias Context = BasicRequestContext
    func respond(to request: Request, context: Context) async throws -> Response {
        throw PreContentDeadlineFailure.deadlineUnreachable
    }
}

/// A distributed first-token budget that is spent before admission refuses
/// before any response header. The local error mapper must render it; uncaught,
/// it would reach the client as a body-less 500.
@Test func localHTTPRendersASpentFirstTokenBudgetAsServiceUnavailable() async throws {
    let responder = CORSResponder(inner: SpentBudgetResponder())
    let request = Request(
        head: .init(method: .post, scheme: "http", authority: "localhost", path: "/v1/chat/completions"),
        body: .init(buffer: ByteBuffer()))
    let context = BasicRequestContext(source: ApplicationRequestContextSource(
        channel: EmbeddedChannel(), logger: Logger(label: "pre-content-refusal")))
    let response = try await responder.respond(to: request, context: context)
    #expect(response.status == .serviceUnavailable)
    #expect(response.headers[.contentType] == "application/json")
    #expect(response.headers[.accessControlAllowOrigin] == "*")
    let capture = HTTPOriginCapture()
    try await response.body.write(HTTPOriginWriter(capture: capture))
    #expect(capture.output.contains("\"error\""))
}
