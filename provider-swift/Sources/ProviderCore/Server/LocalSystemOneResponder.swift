import Foundation
import Hummingbird
import MLXDecisions
import NIOCore
import NIOFoundationCompat

/// Native JSON decisions use the same auth, disconnect and CORS boundaries as chat.
public struct LocalSystemOneResponder<Inner: HTTPResponder>: HTTPResponder
where Inner.Context == BasicRequestContext {
    public typealias Context = BasicRequestContext
    let inner: Inner
    let predict: (@Sendable (Data) async throws -> Data)?

    public func respond(to request: Request, context: Context) async throws -> Response {
        guard request.method == .post, request.uri.path == "/v1/systemone", let predict else {
            return try await inner.respond(to: request, context: context)
        }
        do {
            var request = request
            let body = try await request.collectBody(upTo: 1024 * 1024)
            let response = try await predict(Data(buffer: body))
            return Response(status: .ok, headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(bytes: response)))
        } catch is NIOTooManyBytesError {
            return CORSResponder<Inner>.openAIErrorResponse(status: .contentTooLarge, message: "Decision request exceeds 1 MiB")
        } catch LayaError.invalidJSON {
            return CORSResponder<Inner>.openAIErrorResponse(status: .badRequest, message: "Invalid JSON")
        } catch LayaError.invalidRequest {
            return CORSResponder<Inner>.openAIErrorResponse(status: .unprocessableContent, message: "Invalid System One decision request")
        }
    }
}
