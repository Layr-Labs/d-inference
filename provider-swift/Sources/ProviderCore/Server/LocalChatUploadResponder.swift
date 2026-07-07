// Copyright © 2026 Eigen Labs.
//
// 32 MiB request-body ceiling for the local chat-completions routes.
//
// WHY THIS EXISTS (the known 413 backlog item): the upstream
// `MLXServerApplication.buildRouter` handlers decode bodies via
// `request.decode(as:context:)`, which collects the body with
// `context.maxUploadSize`. `maxUploadSize` is a `RequestContext` protocol
// requirement whose default witness — 2 MiB — is baked into
// `BasicRequestContext` at Hummingbird compile time, and the upstream
// router's signature pins `BasicRequestContext`, so there is NO config
// knob to raise it from outside and a retroactive extension cannot
// replace the witness. Inline media (`data:` image/video URLs) blows the
// 2 MiB ceiling at ~1.5 MB of source media, 413-ing exactly the requests
// the vision models exist for — while the coordinator WebSocket path
// allows 32 MiB.
//
// The fix: intercept the media-bearing chat-completions POSTs *before*
// the upstream router, collect the body under OUR 32 MiB limit (matching
// the coordinator WS frame cap), decode with the same JSON configuration
// Hummingbird's default `requestDecoder` uses, and call the same public
// `MLXOpenAIService` entry points the upstream handler calls. Response
// framing (SSE headers/JSON encoder) mirrors the upstream helpers
// byte-for-byte; error throws propagate to `CORSResponder`'s catch, the
// same status-mapping layer upstream-raised errors hit.
//
// Scope: `/v1/chat/completions` + `/chat/completions` POSTs only — the
// routes that carry inline media. Every other route keeps the upstream
// 2 MiB decode ceiling (completions/responses/tokenize bodies are text
// and sit far below it).

import Foundation
import Hummingbird
import MLXLMServer
import NIOCore
import NIOFoundationCompat

/// Body-size ceiling for the local inference endpoint's chat routes —
/// matches the coordinator WebSocket path's 32 MiB frame allowance.
public let localInferenceMaxUploadBytes = 32 * 1024 * 1024

/// Responder that serves the chat-completions POSTs itself (with the
/// raised body ceiling) and forwards everything else to the wrapped
/// upstream router. Sits INSIDE `CORSResponder` so its responses get the
/// CORS header and its thrown errors get the OpenAI error-envelope
/// mapping, exactly like upstream-raised ones.
public struct LocalChatUploadResponder<Inner: HTTPResponder>: HTTPResponder
where Inner.Context == BasicRequestContext {
    public typealias Context = BasicRequestContext

    public let inner: Inner
    let service: MLXOpenAIService
    let maxUploadBytes: Int

    init(inner: Inner, service: MLXOpenAIService, maxUploadBytes: Int = localInferenceMaxUploadBytes) {
        self.inner = inner
        self.service = service
        self.maxUploadBytes = maxUploadBytes
    }

    /// The POST paths that carry inline media and need the raised ceiling.
    static func isChatCompletionsPath(_ path: String) -> Bool {
        path == "/v1/chat/completions" || path == "/chat/completions"
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        guard request.method == .post, Self.isChatCompletionsPath(request.uri.path) else {
            return try await inner.respond(to: request, context: context)
        }

        var request = request
        let buffer: ByteBuffer
        do {
            buffer = try await request.collectBody(upTo: maxUploadBytes)
        } catch is NIOTooManyBytesError {
            // Same 413 status the stock path produces, but with an
            // OpenAI-shaped envelope that names the REAL limit.
            return CORSResponder<Inner>.openAIErrorResponse(
                status: .contentTooLarge,
                message: "request body exceeds the \(maxUploadBytes / (1024 * 1024)) MiB local endpoint limit"
            )
        }

        // Mirror Hummingbird's default `requestDecoder` configuration
        // (RequestContext extension: JSONDecoder + .iso8601 dates) so a
        // request that decoded on the stock path decodes identically here.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A DecodingError propagates exactly as it would from the upstream
        // handler's `request.decode` — same nesting level, same catch
        // layers above us — so malformed-body behavior is unchanged.
        let chatRequest = try decoder.decode(
            OpenAIChatCompletionRequest.self, from: Data(buffer: buffer))

        // Same service entry points as the upstream handler; pre-stream
        // throws (unknown model, admission refusal) travel to
        // `CORSResponder`'s status mapping unchanged.
        if chatRequest.stream == true {
            let frames = try await service.streamChatCompletionFrames(request: chatRequest)
            return Self.sseResponse(frames)
        }
        return try Self.jsonResponse(try await service.createChatCompletion(request: chatRequest))
    }

    // MARK: - Response framing (byte-for-byte mirrors of the upstream
    // MLXServerApplication private helpers)

    static func jsonResponse<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status = .ok
    ) throws -> Response {
        let data = try JSONEncoder.openAIServer.encode(value)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    static func sseResponse(_ frames: AsyncThrowingStream<String, Error>) -> Response {
        let body = AsyncThrowingStream<ByteBuffer, Error> { continuation in
            let task = Task {
                do {
                    for try await frame in frames {
                        continuation.yield(ByteBuffer(string: frame))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return Response(
            status: .ok,
            headers: [
                .contentType: "text/event-stream; charset=utf-8",
                .cacheControl: "no-cache",
            ],
            body: .init(asyncSequence: body)
        )
    }
}
