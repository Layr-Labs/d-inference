// Copyright © 2026 Eigen Labs.
//
// Local chat routes need a 32 MiB body ceiling for inline media. The upstream
// router fixes BasicRequestContext's 2 MiB limit, so these routes collect and
// decode here, then use the same MLXOpenAIService and response framing.

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
    let serviceForTemplateControls: @Sendable (ChatTemplateControls) -> MLXOpenAIService
    let maxUploadBytes: Int

    init(
        inner: Inner,
        service: MLXOpenAIService,
        maxUploadBytes: Int = localInferenceMaxUploadBytes,
        serviceForTemplateControls: (@Sendable (ChatTemplateControls) -> MLXOpenAIService)? = nil
    ) {
        self.inner = inner
        self.serviceForTemplateControls = serviceForTemplateControls ?? { _ in service }
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
            let requests: [LocalChatRequest]
            switch decodeBody([LocalChatRequest].self, from: buffer) {
            case .success(let decoded): requests = decoded
            case .failure(let badRequest): return badRequest
            }
            // Mirror of the upstream batch handler: sequential
            // createChatCompletion calls, one JSON array response.
            var responses: [OpenAIChatCompletionResponse] = []
            responses.reserveCapacity(requests.count)
            for item in requests {
                responses.append(
                    try await serviceForTemplateControls(item.templateControls)
                        .createChatCompletion(request: item.request))
            }
            return try Self.jsonResponse(responses)
        }

        let item: LocalChatRequest
        switch decodeBody(LocalChatRequest.self, from: buffer) {
        case .success(let decoded): item = decoded
        case .failure(let badRequest): return badRequest
        }
        let requestService = serviceForTemplateControls(item.templateControls)
        // Same service entry points as the upstream handler; pre-stream
        // throws (unknown model, admission refusal) travel to
        // `CORSResponder`'s status mapping unchanged.
        if item.request.stream == true {
            let frames = try await requestService.streamChatCompletionFrames(request: item.request)
            return Self.sseResponse(frames)
        }
        return try Self.jsonResponse(
            try await requestService.createChatCompletion(request: item.request))
    }

    /// This responder sits outside the router that normally maps decode errors
    /// to HTTP 400. Return the same error envelope explicitly to avoid a 500.
    enum DecodeOutcome<T> {
        case success(T)
        case failure(Response)
    }

    private func decodeBody<T: Decodable>(
        _ type: T.Type, from buffer: ByteBuffer
    ) -> DecodeOutcome<T> {
        let decoder = JSONDecoder()
        // Match Hummingbird's default request decoder.
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
