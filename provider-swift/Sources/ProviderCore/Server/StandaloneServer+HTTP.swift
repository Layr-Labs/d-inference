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
            config: LocalInferenceHTTPConfig(host: config.host, port: config.port, authToken: config.authToken),
            defaultMaxTokens: Self.schedulerDefaultMaxTokens,
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
            // The --local path can't carry a per-request prompt_cache_key, so
            // allow a fixed per-server scope via DARKBLOOM_PREFIX_CACHE_SCOPE.
            // "" ⇒ unscoped (default). Used to validate cross-tenant isolation
            // on a single box (two servers, two scopes, one cache dir).
            cacheScope: ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_CACHE_SCOPE"] ?? "",
            onServerRunning: { [weak self] _ in
                await self?.markBound()
            }
        )
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

        do {
            var response = try await inner.respond(to: request, context: context)
            response.headers[.accessControlAllowOrigin] = "*"
            return response
        } catch let error as MultiModelBatchSchedulerEngineError {
            // P2 #4 + P2 #6: render engine errors with the same
            // status mapping the ProviderLoop path uses. The upstream
            // router does NOT know about
            // `MultiModelBatchSchedulerEngineError`, so without this
            // catch the error escapes as an opaque 500.
            return Self.openAIErrorResponse(
                status: HTTPResponse.Status(
                    code: Int(ProviderLoop.mapInferenceErrorToStatus(error))
                ),
                message: error.localizedDescription
            )
        } catch let error as MLXOpenAIServiceError {
            return Self.openAIErrorResponse(
                status: HTTPResponse.Status(
                    code: Int(ProviderLoop.mapInferenceErrorToStatus(error))
                ),
                message: error.localizedDescription
            )
        }
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
    /// body even on a cross-origin request.
    static func openAIErrorResponse(
        status: HTTPResponse.Status,
        message: String
    ) -> Response {
        let body = OpenAIErrorEnvelope(
            error: .init(message: message, type: "invalid_request_error")
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

/// OpenAI-style `{"error": {...}}` envelope used by ``CORSResponder``
/// when it has to render an engine error directly. Pulled out of the
/// generic method body because Swift does not allow nesting a struct
/// inside a generic function.
private struct OpenAIErrorEnvelope: Encodable {
    struct ErrorObject: Encodable {
        let message: String
        let type: String
    }
    let error: ErrorObject
}
