// Copyright © 2026 Eigen Labs.
//
// Local chat routes need a 32 MiB body ceiling for inline media. The upstream
// router fixes BasicRequestContext's 2 MiB limit, so these routes collect and
// decode here, then use the same MLXOpenAIService and response framing.

import NIOCore
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
    let distributedResponses: (any DistributedHTTPResponseProviding)?
    /// The reasoning parser a request that names none is served with, by its model's type (see
    /// `makeLocalInferenceApplication`); nil: the request's own. Without it the local API returned Gemma's thought
    /// channel and GPT-OSS's Harmony markers in `content`, on a single Mac and on a cluster alike.
    let reasoningParserFor: (@Sendable (String) async -> ReasoningParserFormat?)?
    /// What `previous_response_id` continues; the fork's typed Responses request does not carry the field.
    let responseConversations: LocalResponseConversationStore
    let serviceForRawChat: (@Sendable (Data, OpenAIChatCompletionRequest) -> MLXOpenAIService?)?
    /// The cluster's API: the service for a chat request that asks for
    /// logprobs (OpenAI `logprobs`/`top_logprobs`, read from the raw body as
    /// the coordinator path reads them); nil serves none, as single-Mac.
    let serviceForLogprobs: (@Sendable (ChatTemplateControls, EngineV2LogprobsPlumbing) -> MLXOpenAIService)?
    /// The cluster's API: counts a model's tokens in returned reasoning text, for
    /// `usage.completion_tokens_details.reasoning_tokens`; nil reports none, as single-Mac.
    let reasoningTokenCounter: (@Sendable (String) async -> (@Sendable (String) -> Int)?)?

    init(
        inner: Inner,
        service: MLXOpenAIService,
        maxUploadBytes: Int = localInferenceMaxUploadBytes,
        serviceForTemplateControls: (@Sendable (ChatTemplateControls) -> MLXOpenAIService)? = nil,
        distributedResponses: (any DistributedHTTPResponseProviding)? = nil,
        reasoningParserFor: (@Sendable (String) async -> ReasoningParserFormat?)? = nil,
        responseConversations: LocalResponseConversationStore = LocalResponseConversationStore(),
        serviceForLogprobs: (@Sendable (ChatTemplateControls, EngineV2LogprobsPlumbing) -> MLXOpenAIService)? = nil,
        reasoningTokenCounter: (@Sendable (String) async -> (@Sendable (String) -> Int)?)? = nil,
        serviceForRawChat: (@Sendable (Data, OpenAIChatCompletionRequest) -> MLXOpenAIService?)? = nil
    ) {
        self.serviceForLogprobs = serviceForLogprobs
        self.reasoningTokenCounter = reasoningTokenCounter
        self.reasoningParserFor = reasoningParserFor
        self.responseConversations = responseConversations
        self.inner = inner
        self.serviceForTemplateControls = serviceForTemplateControls ?? { _ in service }
        self.maxUploadBytes = maxUploadBytes
        self.distributedResponses = distributedResponses
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
        case .failure(let badRequest):
            // The cluster's API repairs what the coordinator path repairs (a
            // scalar `stop`, the `developer` role, content-less messages,
            // hosted tools) and retries, as `ProviderLoop.decodeOpenAIRequest`
            // does; the original error stands when that cannot help.
            guard distributedResponses != nil,
                  let repaired = try? InboundChatNormalization.normalize(Data(buffer: buffer)),
                  case .success(let decoded) = decodeBody(LocalChatRequest.self, from: ByteBuffer(data: repaired))
            else { return badRequest }
            item = decoded
        }
        // Optional unpublished-owner hook is reached only after outer auth,
        // body-limit collection and ordinary request decoding. Exact raw bytes
        // retain controls that the upstream request type deliberately omits.
        // Its owner splits its own reasoning channel and refuses a request
        // parser, so the inferred parser applies only to the generic service
        // (the coordinator path likewise sets none for a Super owner).
        let requestService: MLXOpenAIService
        var logprobs: EngineV2LogprobsPlumbing?
        if let rawService = serviceForRawChat?(Data(buffer: buffer), item.request) {
            requestService = rawService
        } else if let serviceForLogprobs, let spec = ProviderLoop.extractLogprobsSpec(from: Data(buffer: buffer)) {
            await resolveReasoningParser(&item)
            let plumbing = EngineV2LogprobsPlumbing(topLogprobs: spec.topLogprobs, channel: EngineV2LogprobsChannel())
            logprobs = plumbing
            requestService = serviceForLogprobs(item.templateControls, plumbing)
        } else {
            await resolveReasoningParser(&item)
            requestService = serviceForTemplateControls(item.templateControls)
        }
        let countTokens = await reasoningTokenCounter?(item.request.model)
        // Same service entry points as the upstream handler; pre-stream
        // throws (unknown model, admission refusal) travel to
        // `CORSResponder`'s status mapping unchanged.
        if item.request.stream == true {
            if let distributedResponses {
                let response = try distributedResponses.begin()
                do {
                    guard let channel = LocalHTTPConnectionScope.current else {
                        throw MultiModelBatchSchedulerEngineError.requestRejected("Missing local connection observation")
                    }
                    // A full close is definitive. Input half-close alone is
                    // allowed; the serialized SSE writer probes for write loss.
                    channel.closeFuture.whenComplete { [weak response] _ in
                        guard let response else { return }
                        // Delivery is impossible after a full close. This ends
                        // only the HTTP hold; engine/lease retirement stays held.
                        response.disconnect(); response.finish()
                    }
                    if !channel.isActive { response.disconnect(); response.finish(); throw CancellationError() }
                    let frames = try await DistributedHTTPResponseScope.$current.withValue(response) {
                        try await requestService.streamChatCompletionFrames(
                            request: item.request, frameGenerationErrors: true)
                    }
                    return DistributedHTTPEventStream.response(
                        Self.decorating(frames, logprobs: logprobs, countTokens: countTokens), control: response)
                } catch {
                    response.disconnect(); response.finish(); throw error
                }
            }
            let frames = try await requestService.streamChatCompletionFrames(
                request: item.request, frameGenerationErrors: true)
            return Self.sseResponse(frames)
        }
        let completion = try await requestService.createChatCompletion(request: item.request)
        if logprobs != nil || countTokens != nil {
            return try Self.jsonResponse(completion, logprobs: logprobs, countTokens: countTokens)
        }
        return try Self.jsonResponse(completion)
    }

    /// The OpenAI entries a request asked for: `top_logprobs` alternatives
    /// (none for `logprobs: true` alone, though the engine gathers one).
    static func requested(_ entries: [SSETokenLogprob], top: Int?) -> [SSETokenLogprob] {
        entries.map { .init(token: $0.token, logprob: $0.logprob, bytes: $0.bytes,
                            topLogprobs: Array($0.topLogprobs.prefix(max(0, top ?? 0)))) }
    }

    /// The coordinator path's frame decorations on the cluster's own frames:
    /// each token's logprobs spliced into the next content-bearing frame
    /// (`ProviderLoop.injectLogprobs`), and the usage frame's reasoning tokens
    /// (`ProviderLoop.injectReasoningTokens`).
    static func decorating(_ frames: AsyncThrowingStream<String, Error>, logprobs: EngineV2LogprobsPlumbing?,
                           countTokens: (@Sendable (String) -> Int)?) -> AsyncThrowingStream<String, Error> {
        guard logprobs != nil || countTokens != nil else { return frames }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var pending: [SSETokenLogprob] = []
                var reasoning = ""
                do {
                    for try await frame in frames {
                        var frame = frame
                        if let countTokens, let parsed = ProviderLoop.parseStreamChunk(frame) {
                            reasoning += parsed.reasoningDelta ?? ""
                            if let usage = parsed.usage, !reasoning.isEmpty {
                                frame = ProviderLoop.injectReasoningTokens(into: frame,
                                    reasoningTokens: min(countTokens(reasoning), max(0, usage.completionTokens)))
                            }
                        }
                        if let logprobs { pending += requested(logprobs.channel.drain(), top: logprobs.topLogprobs) }
                        if !pending.isEmpty, let decorated = ProviderLoop.injectLogprobs(into: frame, entries: pending) {
                            pending = []
                            continuation.yield(decorated)
                        } else {
                            continuation.yield(frame)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A collected completion with every token's logprobs on its choice and
    /// its reasoning tokens in the usage.
    static func jsonResponse(_ completion: OpenAIChatCompletionResponse, logprobs: EngineV2LogprobsPlumbing?,
                             countTokens: (@Sendable (String) -> Int)?) throws -> Response {
        guard let bytes = try decoratedJSON(completion, logprobs: logprobs, countTokens: countTokens) else {
            return try jsonResponse(completion)
        }
        return Response(status: .ok, headers: [.contentType: "application/json"],
                        body: .init(byteBuffer: ByteBuffer(bytes: bytes)))
    }

    static func decoratedJSON(_ completion: OpenAIChatCompletionResponse, logprobs: EngineV2LogprobsPlumbing?,
                              countTokens: (@Sendable (String) -> Int)?) throws -> Data? {
        let data = try JSONEncoder.openAIServer.encode(completion)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var choices = object["choices"] as? [[String: Any]], !choices.isEmpty else { return nil }
        if let logprobs {
            let entries = requested(logprobs.channel.drain(), top: logprobs.topLogprobs)
            choices[0]["logprobs"] = ["content": entries.map(\.jsonObject)]
            object["choices"] = choices
        }
        if let countTokens, let reasoning = completion.choices.first?.message.reasoningContent, !reasoning.isEmpty,
           var usage = object["usage"] as? [String: Any] {
            usage["completion_tokens_details"] = ["reasoning_tokens":
                min(countTokens(reasoning), max(0, completion.usage.completionTokens))]
            object["usage"] = usage
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
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
