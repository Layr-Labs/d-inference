// HTTP wiring for ``StandaloneServer``. Split out of the main file
// so the actor (model registry + LRU + reservations + lazy load) and
// the HTTP layer (Hummingbird application builder + CORS middleware +
// engine-error → OpenAI envelope mapping) can be navigated
// independently.
//
// The wrapped responder pattern is unavoidable here: the upstream
// `MLXServerApplication.buildRouter(service:)` returns a router with
// every route already registered, and Hummingbird's
// `Router.add(middleware:)` only applies to routes added *after* the
// call. So instead of installing middleware, we wrap the built
// responder.

import Foundation
import Hummingbird
import MLXLMServer
import NIOCore

extension StandaloneServer {

    /// Build a Hummingbird application backed by `MLXLMServer`'s router.
    /// The `MLXOpenAIService` instance reaches back into this actor
    /// through the registry/reservation/ensure-loaded closures so all
    /// Darkbloom-specific policy (LRU, memory headroom, reservations,
    /// lazy loading) still applies even though the HTTP routes
    /// themselves are owned upstream.
    ///
    /// P2 #7: the upstream router does not emit CORS headers, so the
    /// returned application is wrapped in ``CORSResponder`` which:
    ///   - Answers `OPTIONS` preflights with 204 + permissive
    ///     `Access-Control-Allow-*` headers.
    ///   - Adds `Access-Control-Allow-Origin: *` to every
    ///     non-preflight response.
    /// This mirrors the headers the pre-MLXLMServer ``ServerRoutes``
    /// implementation pinned on every response (see git history for
    /// `ServerRoutes.swift::StandaloneHeadersMiddleware`). Hummingbird's
    /// `Router.add(middleware:)` only applies to routes registered
    /// *after* the middleware is added, so we cannot retro-fit
    /// middleware onto a router returned by
    /// `MLXServerApplication.buildRouter`; wrapping the built
    /// responder is the supported alternative.
    nonisolated func makeApplication() -> LocalInferenceApplication {
        // Delegates to the shared builder (see LocalInferenceHTTP.swift) so the
        // standalone (`--local`) and unified (`--local-endpoint`) endpoints serve
        // byte-identical HTTP behaviour. Only the registry-backing closures
        // differ — here they reach into this actor's own scheduler cache.
        //
        // I1: route through the single atomic-acquire entry point so a concurrent
        // eviction cannot pick the just-loaded model between `ensureModelLoaded`
        // and the reservation bump.
        //
        // P2 #3: `availableModels` returns the ADVERTISED catalog (not the
        // currently-loaded subset) — discovery clients call `/v1/models` before
        // their first request to pick a valid id; an empty list at cold start
        // would make them give up.
        makeLocalInferenceApplication(
            config: LocalInferenceHTTPConfig(host: config.host, port: config.port, authToken: config.authToken,
                                             router: config.router),
            defaultMaxTokens: Self.slotDefaultMaxTokens,
            acquire: { [weak self] modelId in
                guard let self else {
                    throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
                }
                return try await self.acquireModel(modelId)
            },
            tokenizerProvider: { [weak self] modelId in
                guard let self else {
                    throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
                }
                return try await self.resolveTokenizer(modelId)
            },
            availableModels: { [weak self] in
                guard let self else { return [] }
                return await self.advertisedModelIds()
            },
            mtpSlots: { [weak self] in
                guard let self else { return [] }
                return await self.mtpSlotMetricsSamples()
            },
            responseTracker: responseTracker,
            onServerRunning: { [weak self] _ in
                await self?.markBound()
            },
            modelTypeProvider: { [weak self] modelId in
                await self?.localModelTypeForAudioAdmission(modelId)
            },
            modelLimits: { [weak self] modelId in
                await self?.localModelLimits(modelId)
            }
        )
    }

    /// Metadata only: cold native audio still uses normal strict acquisition.
    func localModelTypeForAudioAdmission(_ modelId: String) -> String? {
        slots[modelId]?.modelType ?? models.first(where: { $0.id == modelId })?.modelType
    }

    /// What the router's `/v1/models` says of a model this Mac serves: the input it takes (`LocalInputModalities`), and
    /// once it is loaded its window as its engine admits it, the most a prompt or its output may be.
    func localModelLimits(_ modelId: String) -> LocalModelLimits? {
        let input = models.first(where: { $0.id == modelId }).map { LocalInputModalities.of($0) }
        guard let slot = slots[modelId] else { return input.map { LocalModelLimits(inputModalities: $0) } }
        return LocalModelLimits(window: slot.bridge.advertisedContextTokens ?? slot.sizing.maxContextLength,
                                inputModalities: input)
    }
}

// MARK: - CORS wrapper (P2 #4 + P2 #7)

/// HTTP responder that wraps the upstream router with two concerns:
///
///   1. **CORS** (P2 #7): adds permissive
///      `Access-Control-Allow-*` headers to every response and answers
///      `OPTIONS` preflights with 204. Mirrors the headers the
///      pre-MLXLMServer ``ServerRoutes/StandaloneHeadersMiddleware``
///      pinned on every response.
///   2. **Engine error → HTTP status mapping** (P2 #4 + P2 #6):
///      catches ``MultiModelBatchSchedulerEngineError`` raised by
///      `MLXOpenAIService` (which Hummingbird would otherwise render
///      as a body-less 500) and converts it to a proper status code
///      via ``ProviderLoop/mapInferenceErrorToStatus(_:)`` plus an
///      OpenAI-shaped JSON error envelope. Without this an unknown
///      model id surfaces as 500 instead of 404, and an admission
///      rejection surfaces as 500 instead of 429/503.
///
/// We wrap the responder rather than installing a Hummingbird
/// middleware because ``Router/add(middleware:)`` only applies to
/// routes registered *after* the call, and the upstream
/// ``MLXServerApplication/buildRouter(service:)`` returns a router
/// whose routes are already registered.
public struct CORSResponder<Inner: HTTPResponder>: HTTPResponder {
    public typealias Context = Inner.Context

    public let inner: Inner

    public init(inner: Inner) {
        self.inner = inner
    }

    public func respond(to request: Request, context: Context) async throws -> Response {
        if request.method == .options {
            return Response(
                status: .noContent,
                headers: Self.preflightHeaders()
            )
        }
        // Each request's own record of reaching its overall deadline, which the engine marks
        // (`LocalDeadlineOutcome`): the answer is then busy, here or in its stream. The local router's, when it
        // answers the request here (it never passes such a request on).
        let deadline = LocalDeadlineOutcome.current ?? LocalDeadlineOutcome()
        return try await LocalDeadlineOutcome.$current.withValue(deadline) {
            try await respondRecording(to: request, context: context, deadline: deadline)
        }
    }

    private func respondRecording(to request: Request, context: Context,
                                  deadline: LocalDeadlineOutcome) async throws -> Response {
        do {
            var response = try await inner.respond(to: request, context: context)
            response.headers[.accessControlAllowOrigin] = "*"
            if response.headers[.contentType]?.hasPrefix("text/event-stream") == true {
                response.body = LocalDeadlineOutcome.answeringBusy(response.body, outcome: deadline)
            }
            return response
        } catch where deadline.reached {
            // The request reached its overall deadline, whatever ended it: busy, as a request the memory couldn't
            // take now.
            return Self.deadlineResponse()
        } catch let error as OpenAIRequestValidationError {
            // Chat upload interception lives outside the upstream router's
            // HTTPResponseError mapping. Preserve this fixed, content-free
            // validation error without exposing arbitrary upstream messages.
            return Self.openAIErrorResponse(
                status: error.status, message: error.localizedDescription)
        } catch let error as MLXOpenAIServiceError {
            // Keep the upstream service's generic message policy distinct from
            // provider engine/media failures, which have bounded public codes.
            // A response_format answer cut off by max_tokens says so: its text
            // is fixed and names no request content.
            return Self.openAIErrorResponse(
                status: HTTPResponse.Status(
                    code: Int(ProviderLoop.mapInferenceErrorToStatus(error))),
                message: error == .responseFormatCutOffByMaxTokens
                    ? error.localizedDescription : InferenceFailureCode.internalFailure.message)
        } catch let error as PreContentDeadlineFailure {
            // A distributed first-token budget that is already spent refuses
            // before any SSE header or content, with the existing mapping.
            let failure = ProviderLoop.sanitizedInferenceFailure(
                from: error, phase: .generation)
            return Self.openAIErrorResponse(
                status: HTTPResponse.Status(code: Int(failure.statusCode)),
                message: failure.message)
        } catch MultiModelBatchSchedulerEngineError.promptExceedsContext(let message) {
            // The model window this Mac holds requests to, in plain words.
            return Self.openAIErrorResponse(status: .badRequest, message: message, code: "context_length_exceeded")
        } catch MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(let field) {
            // The field and the names a model that reasons takes (fixed text, never the value sent).
            return Self.openAIErrorResponse(status: .badRequest, message: field.refusalMessage,
                code: "invalid_reasoning_effort", param: field.rawValue)
        } catch MultiModelBatchSchedulerEngineError.conflictingReasoningEfforts {
            // Both fields and the names, as for an unknown name (fixed text, never the values sent).
            return Self.openAIErrorResponse(status: .badRequest, message: ReasoningEffortField.conflictMessage,
                code: "invalid_reasoning_effort", param: ReasoningEffortField.conflictParam)
        } catch MultiModelBatchSchedulerEngineError.distributedRequestRefused(let refusal, let message) {
            // A cluster pair's refusal names its rule and the model's limits
            // (a closed template, never request content): the client sees why.
            return Self.openAIErrorResponse(status: .badRequest, message: message, code: refusal.rawValue)
        } catch MultiModelBatchSchedulerEngineError.requestRejected(DistributedRequestQueue.unavailableMessage) {
            // A pair's API whose pair stopped serving once the request was in
            // (queued for a lane when a rank is lost or a stop begins, or
            // `cluster local`'s session starting or stopping): its typed 503,
            // as at its gate.
            return ClusterPairAPIRefusal.response()
        } catch let error where error is MultiModelBatchSchedulerEngineError
            || error is MediaIngest.MediaError
        {
            let failure = ProviderLoop.sanitizedInferenceFailure(
                from: error, phase: .generation)
            failure.writeLocalDiagnostic(to: .standardError,
                debug: ProcessInfo.processInfo.environment["DARKBLOOM_DEBUG_LOCAL_ERRORS"] == "1")
            let status = HTTPResponse.Status(code: Int(failure.statusCode))
            // A request beyond what this Mac's memory holds now, or one an
            // advertised context's own guard refuses (with the output cut to
            // the window, only an invalid output reaches it), is answered in
            // words that name the bound and what to change (fixed text, never
            // request content).
            switch error as? MultiModelBatchSchedulerEngineError {
            case .advertisedContextExceeded?:
                return Self.openAIErrorResponse(status: status, message: Self.advertisedContextExceededMessage,
                    code: "context_length_exceeded")
            case .tokenBudgetExhausted(let refusal)? where OwnerMemoryRefusal(refusal: refusal) == .exceedsIdle:
                // Larger than this Mac's memory holds with nothing else
                // running: the only memory refusal that names what to change.
                return Self.openAIErrorResponse(status: status, message: LocalMemoryRefusal.exceedsIdle)
            case .tokenBudgetExhausted?, .platformTerminal(cause: .admissionTimeout, _, _)?:
                // Requests already running hold this Mac's memory: a refusal
                // after the owner's memory wait (or with it off), or a request
                // the engine queued and couldn't admit within its admission
                // lease (one not held: a held one, streamed or the owner's, is
                // refused at its head, `EngineV2Bridge.holdHeadUntilAdmitted`,
                // and the owner's first waits again). Busy, with nothing
                // about the request to change.
                var response = Self.openAIErrorResponse(status: status, message: LocalMemoryRefusal.busy)
                response.headers[.retryAfter] = String(LocalMemoryRefusal.retryAfterSeconds)
                return response
            case .mediaUnsupportedByModel?:
                // Media the model doesn't take as served here (a text-only
                // model, or a pair that serves a model text only): the typed
                // code this Mac gives the coordinator for it, on one Mac and
                // on a pair alike.
                return Self.openAIErrorResponse(status: status, message: failure.message, code: failure.code.rawValue)
            default:
                return Self.openAIErrorResponse(status: status, message: failure.message)
            }
        }
    }

    /// This Mac's answer to a prompt and `max_tokens` that together pass an
    /// advertised context.
    static var advertisedContextExceededMessage: String {
        "The prompt and max_tokens together don't fit in this model's context window "
            + "(its context_length in /v1/models). Shorten the prompt or lower max_tokens."
    }

    /// Headers returned on a `OPTIONS` preflight. Matches the
    /// `defaultHeaders()` helper from the deleted
    /// `ServerRoutes.swift::defaultHeaders` so the wire-level
    /// contract is unchanged.
    static func preflightHeaders() -> HTTPFields {
        var headers = HTTPFields()
        headers[.accessControlAllowOrigin] = "*"
        headers[.accessControlAllowHeaders] = "accept, authorization, content-type, origin"
        headers[.accessControlAllowMethods] = "GET, POST, HEAD, OPTIONS"
        return headers
    }

    /// OpenAI-shaped error envelope (matches the body the upstream
    /// `/v1/embeddings` route emits when the engine is missing). Sets
    /// the CORS allow-origin header so browser clients can read the
    /// body even on a cross-origin request. `code` is the optional OpenAI
    /// error code and `param` the request field it names; each is omitted
    /// from the body when nil.
    /// A request at its overall deadline (`LocalDeadlineOutcome`): busy, with `Retry-After`, before any SSE header.
    static func deadlineResponse() -> Response {
        var response = openAIErrorResponse(status: .serviceUnavailable, message: LocalMemoryRefusal.deadline,
            code: InferenceErrorReason.capacityBusy.rawValue)
        response.headers[.retryAfter] = String(LocalMemoryRefusal.retryAfterSeconds)
        return response
    }

    static func openAIErrorResponse(
        status: HTTPResponse.Status,
        message: String,
        code: String? = nil,
        param: String? = nil
    ) -> Response {
        let body = OpenAIErrorEnvelope(
            error: .init(message: message, type: "invalid_request_error", param: param, code: code)
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            data = Data(#"{"error":{"message":"encoding failed","type":"server_error"}}"#.utf8)
        }
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        headers[.accessControlAllowOrigin] = "*"
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}

/// The local API's words for a request this Mac's memory, or a pair's, doesn't
/// hold (`OwnerMemoryRefusal`): the memory 503's message, and a pair's typed
/// stream error's (`DistributedHTTPEventStream.memoryFailureFrame`). Only a
/// request larger than the memory holds with nothing else running is asked to
/// change: a client must never read a busy Mac as a request too large for its
/// model (Hermes Agent reported a 19K-token conversation "too large" for a 256K
/// window while another of its requests held a pair's memory, 2026-11-17).
enum LocalMemoryRefusal {
    /// The memory is held, by running requests or by another loaded model: retry later. With the GLM shared-grant
    /// wait off, 0.10.17's words, which name only running requests.
    static let busy = busy(waitsForSharedGrant: OwnerMemoryWait.waitsForSharedGrant())
    static func busy(waitsForSharedGrant: Bool) -> String {
        waitsForSharedGrant ? "This Mac is at capacity. Retry when more memory is available."
            : "This Mac is at capacity: requests already running are using the memory this request needs. "
                + "Retry in a moment, when they finish."
    }
    /// The request reached its overall deadline before it finished (`LocalDeadlineOutcome`): busy, retry later.
    static let deadline = "This Mac is busy: the request reached its time limit before it finished. "
        + "Retry in a moment."
    static let exceedsIdle = "This request needs more memory than this Mac can give it, even with nothing else "
        + "running. Lower max_tokens or shorten the prompt (or send less media)."
    /// The busy 503's `Retry-After`, in seconds.
    static let retryAfterSeconds = 10
}

/// OpenAI-style `{"error": {...}}` envelope used by ``CORSResponder``
/// when it has to render an engine error directly. Pulled out of the
/// generic method body because Swift does not allow nesting a struct
/// inside a generic function.
private struct OpenAIErrorEnvelope: Encodable {
    struct ErrorObject: Encodable {
        let message: String
        let type: String
        /// Both omitted when nil, so every existing envelope is unchanged.
        var param: String? = nil
        var code: String? = nil
    }
    let error: ErrorObject
}

// Taking only the sanitized failure keeps raw schema diagnostics out of stderr,
// including when the local debug switch is set.
extension InferenceFailure {
    func writeLocalDiagnostic(to sink: FileHandle, debug: Bool) {
        let reason = errorReason.map { ", \($0.rawValue)" } ?? ""
        let status = debug ? ", HTTP \(statusCode)" : ""
        sink.write(Data("local API: request failed: \(code.rawValue)\(reason)\(status)\n".utf8))
    }
}
