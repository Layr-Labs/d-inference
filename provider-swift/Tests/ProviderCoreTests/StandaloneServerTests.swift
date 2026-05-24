import Hummingbird
import HummingbirdTesting
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

private func standaloneTestServer(models: [ModelInfo] = []) -> StandaloneServer {
    StandaloneServer(
        models: models
    )
}
