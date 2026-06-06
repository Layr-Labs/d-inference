// Shared builder for the local OpenAI-compatible HTTP endpoint.
//
// Both serve modes expose the SAME Hummingbird application — the only
// difference is WHERE the loaded models come from:
//   * `darkbloom start --local`            → StandaloneServer's own scheduler cache
//   * `darkbloom start --local-endpoint`   → the live ProviderLoop's modelSlots
//     (unified mode: serve the public fleet AND a local endpoint off ONE shared
//     set of loaded models, so weights load once and local + coordinator
//     requests feed the same continuous-batching engine).
//
// The HTTP layer is fully decoupled from the model registry via three closures,
// so this builder is the single source of truth for routing, CORS, auth, and
// engine-error → OpenAI-envelope mapping; the caller supplies how to acquire a
// model, resolve a tokenizer, and list the advertised catalog.

import Foundation
import Hummingbird
import MLXLMServer
import NIOCore

/// Network + auth configuration for the local inference HTTP endpoint.
public struct LocalInferenceHTTPConfig: Sendable {
    public let host: String
    public let port: UInt16
    /// Bearer token required on every inference route (nil = open / `--no-auth`).
    public let authToken: String?

    public init(host: String = "127.0.0.1", port: UInt16 = 8000, authToken: String? = nil) {
        self.host = host
        self.port = port
        self.authToken = authToken
    }
}

/// The concrete responder stack the local endpoint always uses:
/// auth (outermost) → CORS → upstream MLXLMServer router.
public typealias LocalInferenceApplication =
    Application<LocalAuthResponder<CORSResponder<RouterResponder<BasicRequestContext>>>>

/// Builds the local OpenAI-compatible Hummingbird application from a model
/// registry expressed as three closures. Shared by `StandaloneServer` and the
/// unified `ProviderLoop` local endpoint so the wire behaviour can never drift.
///
/// - Parameters:
///   - config: bind host/port and the optional bearer token.
///   - defaultMaxTokens: completion cap applied when a request omits `max_tokens`.
///   - acquire: ensure the model is loaded and return a reservation-held handle
///     (the release token is dropped by the engine when the request finishes).
///   - tokenizerProvider: resolve a tokenizer for the token-utility endpoints.
///   - availableModels: the advertised `/v1/models` catalog (not just the
///     currently-resident subset — discovery clients call it before loading).
/// - Parameter onServerRunning: invoked by Hummingbird ONCE the socket is
///   actually bound and listening. This is the authoritative "we bound the port"
///   signal — used to write the discovery record only after a confirmed bind
///   (so a port collision never advertises a foreign process). If the bind
///   fails, `runService` throws instead and this never fires.
func makeLocalInferenceApplication(
    config: LocalInferenceHTTPConfig,
    defaultMaxTokens: Int,
    acquire: @escaping @Sendable (String) async throws -> MultiModelBatchSchedulerEngine.AcquiredModel,
    tokenizerProvider: @escaping @Sendable (String?) async throws -> TokenizerHandle,
    availableModels: @escaping @Sendable () async -> [String],
    onServerRunning: @escaping @Sendable (any Channel) async -> Void = { _ in }
) -> LocalInferenceApplication {
    let engine = MultiModelBatchSchedulerEngine(
        acquire: acquire,
        tokenizerProvider: tokenizerProvider,
        availableModels: availableModels,
        defaultMaxTokens: defaultMaxTokens
    )
    let service = MLXOpenAIService(engine: engine)
    let router = MLXServerApplication.buildRouter(service: service)
    let corsResponder = CORSResponder(inner: router.buildResponder())
    // Auth is the outermost layer so an unauthenticated request is rejected
    // before reaching the engine. Pass-through when no token is configured.
    let authedResponder = LocalAuthResponder(inner: corsResponder, token: config.authToken)

    return Application(
        responder: authedResponder,
        configuration: .init(
            address: .hostname(config.host, port: Int(config.port)),
            serverName: "darkbloom-provider"
        ),
        onServerRunning: onServerRunning
    )
}
