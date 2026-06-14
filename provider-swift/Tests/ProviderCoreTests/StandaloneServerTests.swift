import Hummingbird
import HummingbirdTesting
import Logging
import NIOEmbedded
import Testing
@testable import ProviderCore

// The standalone server now delegates routing / decoding / SSE formatting
// to the upstream `MLXLMServer` library. These tests verify the Darkbloom
// policy layer (lazy load wiring, scheduler error mapping, LRU
// reservation accounting) still behaves correctly, plus a smoke test
// that the upstream router is reachable.

@Test func standaloneServerHealthEndpointUsesUpstreamRouter() async throws {
    let app = standaloneTestServer().makeApplication()

    try await app.test(.router) { client in
        try await client.execute(uri: "/health", method: .get) { response in
            #expect(response.status == .ok)
            let body = String(buffer: response.body)
            #expect(body.contains(#""status":"ok""#))
            // Upstream sets the server name to "mlx-server".
            #expect(body.contains(#""server":"mlx-server""#))
        }
    }
}

@Test func standaloneServerV1HealthAliasIsServed() async throws {
    let app = standaloneTestServer().makeApplication()

    try await app.test(.router) { client in
        try await client.execute(uri: "/v1/health", method: .get) { response in
            #expect(response.status == .ok)
        }
    }
}

@Test func standaloneServerModelsEndpointReturnsAdvertisedCatalog() async throws {
    // P2 #3: `/v1/models` is a discovery endpoint — clients call it
    // before their first request to pick a valid model id. The
    // engine's `availableModels` is wired through the
    // `advertisedModelIds()` closure in `StandaloneServer+HTTP.swift`,
    // so the response reflects the configured catalog regardless of
    // whether any model is currently resident. The pre-MLXLMServer
    // implementation reported the catalog here; the rewrite briefly
    // regressed to "currently-loaded" semantics and this test
    // pins the restored behaviour.
    let model = ModelInfo(
        id: "mlx-community/Qwen2.5-7B-4bit",
        modelType: "qwen2",
        quantization: "4bit",
        sizeBytes: 4_000_000_000,
        estimatedMemoryGb: 4.5
    )
    // Bind the server to a local so its lifetime extends across the
    // `app.test(...)` call — the engine's `availableModels` closure
    // captures `[weak self]` against this actor, so if the StandaloneServer
    // temporary is dropped between `makeApplication()` and the request
    // the closure would return `[]` and we'd be testing the wrong thing.
    let server = standaloneTestServer(models: [model])
    let app = server.makeApplication()

    try await app.test(.router) { client in
        try await client.execute(uri: "/v1/models", method: .get) { response in
            #expect(response.status == .ok)
            let body = String(buffer: response.body)
            #expect(body.contains(#""object":"list""#))
            // P2 #3: the advertised catalog must be returned even
            // though no model is resident at startup.
            #expect(body.contains(#""id":"mlx-community\/Qwen2.5-7B-4bit""#)
                || body.contains(#""id":"mlx-community/Qwen2.5-7B-4bit""#),
                "advertised model id must appear in /v1/models response (P2 #3), got: \(body)")
        }
    }
    _ = server // hold the reference until after the request body runs
}

@Test func standaloneServerReportsModelNotFoundForUnknownModel() async throws {
    let app = standaloneTestServer().makeApplication()

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"model":"mlx-test","messages":[{"role":"user","content":"hello"}],"stream":false}"#)
        ) { response in
            // P2 #4: the standalone server's lazy loader rejects an
            // unknown model id with
            // `StandaloneServerError.modelNotFound` -> translated to
            // `MultiModelBatchSchedulerEngineError.modelNotLoaded`
            // by `acquireModel`. `CORSResponder` then maps that to
            // 404 via `ProviderLoop.mapInferenceErrorToStatus` and
            // emits an OpenAI-shaped error envelope.
            #expect(response.status == .notFound,
                "unknown model id must surface as 404 (P2 #4), got \(response.status)")
            let body = String(buffer: response.body)
            #expect(body.contains(#""error""#),
                "404 body must be the OpenAI error envelope, got \(body)")
            #expect(body.contains("mlx-test"),
                "error envelope must include the offending model id, got \(body)")
            #expect(response.headers[.accessControlAllowOrigin] == "*",
                "CORS allow-origin header must be present on engine-error responses (P2 #7)")
        }
    }
}

// P2 #7: CORS-related coverage for the wrapped responder.

@Test func standaloneServerOptionsPreflightReturns204WithCORSHeaders() async throws {
    let app = standaloneTestServer().makeApplication()

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .options
        ) { response in
            #expect(response.status == .noContent,
                "OPTIONS preflight must return 204 No Content")
            #expect(response.headers[.accessControlAllowOrigin] == "*")
            #expect(response.headers[.accessControlAllowMethods]?.contains("POST") == true)
            #expect(response.headers[.accessControlAllowHeaders]?.contains("content-type") == true)
        }
    }
}

@Test func standaloneServerSetsCORSHeaderOnNormalResponses() async throws {
    let app = standaloneTestServer().makeApplication()

    try await app.test(.router) { client in
        try await client.execute(uri: "/health", method: .get) { response in
            #expect(response.status == .ok)
            #expect(response.headers[.accessControlAllowOrigin] == "*",
                "CORS allow-origin must be added on every response (P2 #7)")
        }
    }
}

@Test func standaloneServerClassifiesSchedulerAdmissionErrors() {
    #expect(StandaloneServer.schedulerErrorStatus(for: "token_budget_exhausted: request exceeds active token budget") == .serviceUnavailable)
    #expect(StandaloneServer.schedulerErrorStatus(for: "token_budget_exhausted: request queue full") == .tooManyRequests)
    #expect(StandaloneServer.schedulerErrorStatus(for: "token_budget_exhausted: invalid token count") == .badRequest)
    #expect(StandaloneServer.schedulerErrorStatus(for: "token_budget_exhausted: duplicate request ID") == .badRequest)
    #expect(StandaloneServer.schedulerErrorStatus(for: "token_budget_exhausted: request exceeds batch token budget") == .badRequest)
    #expect(StandaloneServer.schedulerErrorStatus(for: "unexpected backend failure") == .internalServerError)
}

@Test func standaloneServerStartsAndStops() async throws {
    let server = standaloneTestServer()
    try await server.start()
    await server.stopAndWait()
}

// MARK: - Direct/local mode: bearer-token auth

@Test func standaloneServerEnforcesBearerTokenOnInferenceRoutes() async throws {
    let model = ModelInfo(
        id: "mlx-community/Qwen2.5-7B-4bit",
        modelType: "qwen2",
        quantization: "4bit",
        sizeBytes: 4_000_000_000,
        estimatedMemoryGb: 4.5
    )
    let token = "dk-local-integration-token"
    let server = StandaloneServer(
        config: StandaloneServerConfig(authToken: token),
        models: [model]
    )
    let app = server.makeApplication()

    try await app.test(.router) { client in
        // Health is exempt — liveness probes need no secret.
        try await client.execute(uri: "/health", method: .get) { response in
            #expect(response.status == .ok)
        }
        // /v1/models without a token → 401, with a CORS header so a browser
        // client can still read the error body.
        try await client.execute(uri: "/v1/models", method: .get) { response in
            #expect(response.status == .unauthorized)
            #expect(response.headers[.accessControlAllowOrigin] == "*")
        }
        // Wrong token → 401.
        try await client.execute(
            uri: "/v1/models",
            method: .get,
            headers: [.authorization: "Bearer not-the-token"]
        ) { response in
            #expect(response.status == .unauthorized)
        }
        // Correct token → 200 (advertised catalog).
        try await client.execute(
            uri: "/v1/models",
            method: .get,
            headers: [.authorization: "Bearer \(token)"]
        ) { response in
            #expect(response.status == .ok)
        }
        // OPTIONS preflight stays exempt (CORS).
        try await client.execute(uri: "/v1/chat/completions", method: .options) { response in
            #expect(response.status == .noContent)
        }
    }
}

@Test func standaloneServerWithoutTokenStaysOpen() async throws {
    // Backward-compat / explicit --no-auth: nil token => no enforcement.
    let model = ModelInfo(id: "m", quantization: "4bit", sizeBytes: 1, estimatedMemoryGb: 1)
    let server = standaloneTestServer(models: [model])
    let app = server.makeApplication()
    try await app.test(.router) { client in
        try await client.execute(uri: "/v1/models", method: .get) { response in
            #expect(response.status == .ok)
        }
    }
}

// MARK: - CORSResponder: VLM media-error mapping (local HTTP path)

/// Inner responder stub that always throws a fixed error, so we can drive
/// `CORSResponder.respond` directly and assert how it renders that error —
/// without standing up the whole engine/model stack.
private struct ThrowingResponder<E: Error>: HTTPResponder {
    typealias Context = BasicRequestContext
    let error: E
    func respond(to request: Request, context: Context) async throws -> Response {
        throw error
    }
}

@Test func corsResponderMapsVLMMediaErrorTo400OnLocalPath() async throws {
    // Regression: the coordinator WebSocket path maps VLMRequestInference.MediaError
    // to a 400 (ProviderLoop.mapInferenceErrorToStatus), but the local HTTP path's
    // CORSResponder previously caught only MultiModelBatchSchedulerEngineError /
    // MLXOpenAIServiceError, so a MediaError from the VLM media-cap escaped as the
    // framework's generic 500. CORSResponder now catches it too. Drive the
    // responder directly with a stub that throws the oversize-media error.
    let mediaErr = VLMRequestInference.MediaError.mediaTooLarge(
        "image is 1600000000 px; per-image cap is 100000000 px")
    let responder = CORSResponder(inner: ThrowingResponder(error: mediaErr))

    let request = Request(
        head: .init(method: .post, scheme: "http", authority: "localhost", path: "/v1/chat/completions"),
        body: .init(buffer: ByteBuffer()))
    let context = BasicRequestContext(
        source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(),
            logger: Logger(label: #function)))

    let response = try await responder.respond(to: request, context: context)

    #expect(response.status == .badRequest,
        "oversized inline media on the local path must map to 400, not a generic 500")
    #expect(response.headers[.accessControlAllowOrigin] == "*",
        "CORS allow-origin must be set on the rendered error response")
    // Client-fault video write IO failure stays a 500.
    let writeFail = CORSResponder(
        inner: ThrowingResponder(error: VLMRequestInference.MediaError.videoWriteFailed("disk full")))
    let writeResp = try await writeFail.respond(to: request, context: context)
    #expect(writeResp.status == .internalServerError,
        "provider-side videoWriteFailed must stay a 500")
}

private func standaloneTestServer(models: [ModelInfo] = []) -> StandaloneServer {
    StandaloneServer(
        models: models
    )
}
