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
// Scope: the chat-completions POSTs (`/v1/chat/completions`,
// `/chat/completions`, `/v1/chat/completions/batch`) — the routes whose
// payload type carries inline media. Every other route keeps the
// upstream 2 MiB decode ceiling (completions/responses/tokenize bodies
// are text and sit far below it).

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

    static func isChatCompletionsBatchPath(_ path: String) -> Bool {
        path == "/v1/chat/completions/batch"
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        guard request.method == .post else {
            return try await inner.respond(to: request, context: context)
        }
        let path = request.uri.path
        let isBatch = Self.isChatCompletionsBatchPath(path)
        guard isBatch || Self.isChatCompletionsPath(path) else {
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

        if isBatch {
            let requests: [OpenAIChatCompletionRequest]
            switch decodeBody([OpenAIChatCompletionRequest].self, from: buffer) {
            case .success(let decoded): requests = decoded
            case .failure(let badRequest): return badRequest
            }
            // Mirror of the upstream batch handler: sequential
            // createChatCompletion calls, one JSON array response.
            // Batch items share the outer body probe only for the array
            // envelope; per-item thinking flags aren't re-extracted from
            // each element (batch path is text-oriented). Prefer nested
            // `reasoning.enabled` on each element when needed.
            var responses: [OpenAIChatCompletionResponse] = []
            for chatRequest in requests {
                responses.append(try await service.createChatCompletion(request: chatRequest))
            }
            return try Self.jsonResponse(responses)
        }

        let chatRequest: OpenAIChatCompletionRequest
        switch decodeBody(OpenAIChatCompletionRequest.self, from: buffer) {
        case .success(let decoded): chatRequest = decoded
        case .failure(let badRequest): return badRequest
        }
        // Recover thinking controls dropped by the upstream OpenAI request
        // shape (same sealed-body probes as the coordinator path — #639).
        let bodyData = Data(buffer: buffer)
        let thinkingControls = ThinkingRequestControls(
            reasoningEffort: ProviderLoop.extractReasoningEffort(from: bodyData),
            enableThinkingOverride: ProviderLoop.extractEnableThinking(from: bodyData)
        )
        return try await ThinkingRequestControls.$current.withValue(thinkingControls) {
            // Same service entry points as the upstream handler; pre-stream
            // throws (unknown model, admission refusal) travel to
            // `CORSResponder`'s status mapping unchanged.
            if chatRequest.stream == true {
                let frames = try await service.streamChatCompletionFrames(request: chatRequest)
                return Self.sseResponse(frames)
            }
            return try Self.jsonResponse(try await service.createChatCompletion(request: chatRequest))
        }
    }

    /// Decode with Hummingbird's default `requestDecoder` configuration
    /// (RequestContext extension: JSONDecoder + .iso8601 dates) so a request
    /// that decoded on the stock path decodes identically here — and mirror
    /// the stock path's ERROR mapping too: Hummingbird's
    /// `request.decode(as:context:)` converts every `DecodingError` into a
    /// 400 Bad Request via an `HTTPError` the ROUTER responder renders.
    /// This responder sits OUTSIDE the router, so a thrown error would
    /// escape the CORS/error layers as a body-less 500 — a decode failure
    /// is therefore RENDERED here (OpenAI-shaped 400 envelope), never
    /// thrown.
    /// A decode either yields the value or the already-rendered 400.
    enum DecodeOutcome<T> {
        case success(T)
        case failure(Response)
    }

    private func decodeBody<T: Decodable>(
        _ type: T.Type, from buffer: ByteBuffer
    ) -> DecodeOutcome<T> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .success(try decoder.decode(T.self, from: Data(buffer: buffer)))
        } catch let error as DecodingError {
            return .failure(
                CORSResponder<Inner>.openAIErrorResponse(
                    status: .badRequest,
                    message: Self.badRequestMessage(for: error)))
        } catch {
            return .failure(
                CORSResponder<Inner>.openAIErrorResponse(
                    status: .badRequest,
                    message: "request body failed to decode: \(error)"))
        }
    }

    /// Human-readable 400 detail for a JSON decode failure — the same
    /// classification Hummingbird's stock decode produces.
    static func badRequestMessage(for error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            return "The given data was not valid input: \(context.debugDescription)"
        case .keyNotFound(let key, _):
            return "Coding key `\(key.stringValue)` not found."
        case .typeMismatch(_, let context):
            return "Type mismatch: \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "Value not found: \(context.debugDescription)"
        @unknown default:
            return "Request body failed to decode."
        }
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
