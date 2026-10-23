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
    /// The reasoning parser a request that names none is served with, by its model's type (see
    /// `makeLocalInferenceApplication`); nil: the request's own. Without it the local API returned Gemma's thought
    /// channel and GPT-OSS's Harmony markers in `content`, on a single Mac and on a cluster alike.
    let reasoningParserFor: (@Sendable (String) async -> ReasoningParserFormat?)?
    /// What `previous_response_id` continues; the fork's typed Responses request does not carry the field.
    let responseConversations: LocalResponseConversationStore
    /// A raw-body owner's service (Super). Its `logprobs` requests return
    /// entries on the channel this responder passes and splices.
    let serviceForRawChat: (@Sendable (Data, OpenAIChatCompletionRequest, EngineV2LogprobsChannel?)
        -> MLXOpenAIService?)?

    init(
        inner: Inner,
        service: MLXOpenAIService,
        maxUploadBytes: Int = localInferenceMaxUploadBytes,
        serviceForTemplateControls: (@Sendable (ChatTemplateControls) -> MLXOpenAIService)? = nil,
        reasoningParserFor: (@Sendable (String) async -> ReasoningParserFormat?)? = nil,
        responseConversations: LocalResponseConversationStore = LocalResponseConversationStore(),
        serviceForRawChat: (@Sendable (Data, OpenAIChatCompletionRequest, EngineV2LogprobsChannel?)
            -> MLXOpenAIService?)? = nil
    ) {
        self.reasoningParserFor = reasoningParserFor
        self.responseConversations = responseConversations
        self.inner = inner
        self.serviceForTemplateControls = serviceForTemplateControls ?? { _ in service }
        self.maxUploadBytes = maxUploadBytes
        self.serviceForRawChat = serviceForRawChat
    }

    /// The POST paths that carry inline media and need the raised ceiling.
    static func isChatCompletionsPath(_ path: String) -> Bool {
        path == "/v1/chat/completions" || path == "/chat/completions"
    }

    static func isChatCompletionsBatchPath(_ path: String) -> Bool {
        path == "/v1/chat/completions/batch"
    }

    static func isResponsesCreationPath(_ path: String) -> Bool {
        path == "/v1/responses" || path == "/responses"
    }

    func resolveReasoningParser(_ item: inout LocalChatRequest) async {
        guard item.request.reasoningParser == nil, let reasoningParserFor else { return }
        item.request.reasoningParser = await reasoningParserFor(item.request.model)
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        guard request.method == .post else {
            return try await inner.respond(to: request, context: context)
        }
        let path = request.uri.path
        let isBatch = Self.isChatCompletionsBatchPath(path)
        let isResponses = Self.isResponsesCreationPath(path)
        guard isBatch || Self.isChatCompletionsPath(path) || isResponses else {
            return try await inner.respond(to: request, context: context)
        }

        var request = request
        // Responses previously used BasicRequestContext's 2 MiB ceiling.
        let bodyLimit = isResponses ? min(maxUploadBytes, 2 * 1024 * 1024) : maxUploadBytes
        let buffer: ByteBuffer
        do {
            buffer = try await request.collectBody(upTo: bodyLimit)
        } catch is NIOTooManyBytesError {
            // Same 413 status the stock path produces, but with an
            // OpenAI-shaped envelope that names the REAL limit.
            return CORSResponder<Inner>.openAIErrorResponse(
                status: .contentTooLarge,
                message: "request body exceeds the \(bodyLimit / (1024 * 1024)) MiB local endpoint limit"
            )
        }

        if isResponses {
            var body = buffer
            var inputItems: Data?
            switch LocalResponseConversation.prepare(
                body: Data(buffer: buffer), conversation: responseConversations.conversation(for:)) {
            case .opaque:
                break
            case .prepared(let rewritten, let items):
                if let rewritten { body = ByteBuffer(data: rewritten) }
                inputItems = items
            case .previousResponseNotFound:
                return CORSResponder<Inner>.openAIErrorResponse(
                    status: .badRequest, message: "previous_response_id not found",
                    code: "previous_response_not_found")
            }
            var item: LocalResponseRequest
            switch decodeBody(LocalResponseRequest.self, from: body) {
            case .success(let decoded): item = decoded
            case .failure(let badRequest): return badRequest
            }
            // The same opt-out the service's own response store honours.
            if item.request.store == false { inputItems = nil }
            if item.request.reasoning?.parser == nil, let reasoningParserFor,
               let parser = await reasoningParserFor(item.request.model) {
                var reasoning = item.request.reasoning ?? OpenAIResponseReasoningOptions()
                reasoning.parser = parser
                item.request.reasoning = reasoning
            }
            let responseService = serviceForTemplateControls(item.templateControls)
            if item.request.stream == true {
                let frames = try await responseService.streamResponseFrames(request: item.request)
                guard let inputItems else { return Self.sseResponse(frames) }
                return Self.sseResponse(responseConversations.recording(frames, inputItems: inputItems))
            }
            let response = try await responseService.createResponse(request: item.request)
            if let inputItems {
                responseConversations.record(responseID: response.id, output: response.output, inputItems: inputItems)
            }
            return try Self.jsonResponse(response)
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
            for var item in requests {
                await resolveReasoningParser(&item)
                responses.append(
                    try await serviceForTemplateControls(item.templateControls)
                        .createChatCompletion(request: item.request))
            }
            return try Self.jsonResponse(responses)
        }

        var item: LocalChatRequest
        switch decodeBody(LocalChatRequest.self, from: buffer) {
        case .success(let decoded): item = decoded
        case .failure(let badRequest): return badRequest
        }
        // Optional unpublished-owner hook is reached only after outer auth,
        // body-limit collection and ordinary request decoding. Exact raw bytes
        // retain controls that the upstream request type deliberately omits.
        // Its owner splits its own reasoning channel and refuses a request
        // parser, so the inferred parser applies only to the generic service
        // (the coordinator path likewise sets none for a Super owner).
        // Only a raw-body owner returns logprobs; the generic service ignores them.
        let requestService: MLXOpenAIService
        let logprobs: EngineV2LogprobsChannel?
        let raw = Data(buffer: buffer), channel = EngineV2LogprobsChannel()
        if let rawService = serviceForRawChat?(raw, item.request, channel) {
            requestService = rawService
            logprobs = ProviderLoop.extractLogprobsSpec(from: raw) != nil ? channel : nil
        } else {
            await resolveReasoningParser(&item)
            requestService = serviceForTemplateControls(item.templateControls)
            logprobs = nil
        }
        // Same service entry points as the upstream handler; pre-stream
        // throws (unknown model, admission refusal) travel to
        // `CORSResponder`'s status mapping unchanged.
        if item.request.stream == true {
            let frames = try await requestService.streamChatCompletionFrames(
                request: item.request, frameGenerationErrors: true)
            return Self.sseResponse(logprobs.map { Self.splicingLogprobs(frames, from: $0) } ?? frames)
        }
        let response = try await requestService.createChatCompletion(request: item.request)
        guard let logprobs else { return try Self.jsonResponse(response) }
        return try Self.jsonResponse(response, logprobs: logprobs.drain())
    }

    /// A raw-body owner's frames with its logprob entries spliced into
    /// content-bearing chunks, as the coordinator relay splices them
    /// (`ProviderLoop.injectLogprobs`): entries wait for the next content
    /// frame, and those no content frame follows end with the stream.
    static func splicingLogprobs(_ frames: AsyncThrowingStream<String, Error>,
                                 from channel: EngineV2LogprobsChannel) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var pending: [SSETokenLogprob] = []
                do {
                    for try await frame in frames {
                        pending += channel.drain()
                        _ = EngineV2LogprobsChannel.capPending(&pending)
                        if !pending.isEmpty, let spliced = ProviderLoop.injectLogprobs(into: frame, entries: pending) {
                            pending = []
                            continuation.yield(spliced)
                        } else {
                            continuation.yield(frame)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `response` with a raw-body owner's entries as `choices[0].logprobs.content`,
    /// attached as the stream attaches them: only to a message with content,
    /// and without the token a `stop` finish ends on (a stop token or
    /// sequence, never content). The upstream response has no logprobs field,
    /// so the encoded JSON is edited.
    static func jsonResponse(_ response: OpenAIChatCompletionResponse,
                             logprobs entries: [SSETokenLogprob]) throws -> Response {
        let data = try JSONEncoder.openAIServer.encode(response)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var choices = object["choices"] as? [[String: Any]], var choice = choices.first,
            let content = (choice["message"] as? [String: Any])?["content"] as? String, !content.isEmpty
        else { return try jsonResponse(response) }
        let attached = choice["finish_reason"] as? String == "stop" ? entries.dropLast() : entries[...]
        guard !attached.isEmpty else { return try jsonResponse(response) }
        choice["logprobs"] = ["content": attached.map(\.jsonObject)]
        choices[0] = choice
        object["choices"] = choices
        let spliced = try JSONSerialization.data(withJSONObject: object,
                                                 options: [.sortedKeys, .withoutEscapingSlashes])
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: spliced)))
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
