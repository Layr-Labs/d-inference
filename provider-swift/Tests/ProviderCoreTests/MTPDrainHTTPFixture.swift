import Hummingbird
import Logging
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

/// Render an actual draining acquisition through the production local HTTP
/// error boundary. Checking only its Swift error type misses 429/503 regressions.
func expectMTPDrainHTTP503(
    acquire: @escaping @Sendable () async throws -> Void
) async throws {
    let responder = CORSResponder(inner: MTPDrainAdmissionResponder(acquire: acquire))
    let request = Request(
        head: .init(method: .post, scheme: "http", authority: "localhost", path: "/v1/chat/completions"),
        body: .init(buffer: ByteBuffer()))
    let context = BasicRequestContext(
        source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(), logger: Logger(label: "mtp-drain-http")))
    let response = try await responder.respond(to: request, context: context)
    #expect(response.status == .serviceUnavailable)
    #expect(response.headers[.accessControlAllowOrigin] == "*")
}

private struct MTPDrainAdmissionResponder: HTTPResponder {
    typealias Context = BasicRequestContext
    let acquire: @Sendable () async throws -> Void

    func respond(to request: Request, context: Context) async throws -> Response {
        try await acquire()
        return Response(status: .ok)
    }
}
