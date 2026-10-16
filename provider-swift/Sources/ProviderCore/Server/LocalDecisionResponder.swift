// Copyright © 2026 Eigen Labs.
//
// `POST /v1/decisions` on the local endpoint. The upstream router has no
// decision route, so this responder collects the body (same ceiling as the
// media-bearing chat routes), runs `DecisionLocalServing` and answers with
// the decision JSON. It sits INSIDE `CORSResponder`, whose error mapping turns
// a thrown `DecisionRequestError` (400), engine or media error into an
// OpenAI-shaped envelope. Everything else forwards unchanged.

import Foundation
import Hummingbird
import NIOCore
import NIOFoundationCompat

public struct LocalDecisionResponder<Inner: HTTPResponder>: HTTPResponder
where Inner.Context == BasicRequestContext {
    public typealias Context = BasicRequestContext

    public let inner: Inner
    let serve: @Sendable (DecisionRequest) async throws -> DecisionRunner.Outcome
    let maxUploadBytes: Int

    init(
        inner: Inner,
        maxUploadBytes: Int = localInferenceMaxUploadBytes,
        serve: @escaping @Sendable (DecisionRequest) async throws -> DecisionRunner.Outcome
    ) {
        self.inner = inner
        self.maxUploadBytes = maxUploadBytes
        self.serve = serve
    }

    static func isDecisionsPath(_ path: String) -> Bool {
        path == "/v1/decisions" || path == "/decisions"
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        guard request.method == .post, Self.isDecisionsPath(request.uri.path) else {
            return try await inner.respond(to: request, context: context)
        }
        var request = request
        let buffer: ByteBuffer
        do {
            buffer = try await request.collectBody(upTo: maxUploadBytes)
        } catch is NIOTooManyBytesError {
            return CORSResponder<Inner>.openAIErrorResponse(
                status: .contentTooLarge,
                message: "request body exceeds the \(maxUploadBytes / (1024 * 1024)) MiB local endpoint limit")
        }
        let outcome = try await serve(try DecisionRequest.parse(Data(buffer: buffer)))
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: outcome.response.compactJSON)))
    }
}
