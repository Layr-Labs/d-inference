import Foundation
import Hummingbird
import HummingbirdTesting
import Logging
import MLXLMCommon
import MLXNN
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

// The standalone server delegates routing / decoding / SSE formatting
// to the upstream `MLXLMServer` library. These tests verify the Darkbloom
// policy layer — lazy-load wiring, error mapping, LRU reservation
// accounting, and (v0.7.5 one-engine) the v2 slot construction: the
// supported-set catalog gate, the KV re-slice across slots, the
// engineV2-populated `AcquiredModel` entries, and the 32 MiB chat-route
// body ceiling — plus a smoke test that the upstream router is reachable.

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
    // pins the restored behaviour. (v0.7.5: the fixture must be a
    // CBv2-supported family or the catalog gate drops it — that gate
    // has its own test below.)
    let model = ModelInfo(
        id: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
        modelType: "gemma4",
        quantization: "4bit",
        sizeBytes: 15_000_000_000,
        estimatedMemoryGb: 16.0
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
            #expect(body.contains(#""id":"mlx-community\/gemma-4-26B-A4B-it-qat-4bit""#)
                || body.contains(#""id":"mlx-community/gemma-4-26B-A4B-it-qat-4bit""#),
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

@Test func standaloneServerWaitTracksServiceLifetime() async throws {
    let server = StandaloneServer(config: StandaloneServerConfig(port: 0))
    try await server.start()
    // The full Swift suite runs more than a thousand tests concurrently on CI;
    // allow scheduler contention without weakening the lifetime assertion.
    #expect(await server.waitUntilBound(timeoutSeconds: 10))

    let completion = StandaloneServerCompletion()
    let waiter = Task {
        await server.waitUntilStopped()
        await completion.markComplete()
    }
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(!(await completion.isComplete))

    await server.stop()
    await waiter.value
    #expect(await completion.isComplete)
}

private actor StandaloneServerCompletion {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
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
    // Regression: the coordinator WebSocket path maps MediaIngest.MediaError
    // to a 400 (ProviderLoop.mapInferenceErrorToStatus), but the local HTTP path's
    // CORSResponder previously caught only MultiModelBatchSchedulerEngineError /
    // MLXOpenAIServiceError, so a MediaError from the VLM media-cap escaped as the
    // framework's generic 500. CORSResponder now catches it too. Drive the
    // responder directly with a stub that throws the oversize-media error.
    let mediaErr = MediaIngest.MediaError.mediaTooLarge(
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
        inner: ThrowingResponder(error: MediaIngest.MediaError.videoWriteFailed("disk full")))
    let writeResp = try await writeFail.respond(to: request, context: context)
    #expect(writeResp.status == .internalServerError,
        "provider-side videoWriteFailed must stay a 500")
}

private func standaloneTestServer(models: [ModelInfo] = []) -> StandaloneServer {
    StandaloneServer(
        models: models
    )
}

// MARK: - v0.7.5 one-engine: supported-set catalog gate (fail loud)

@Test func standaloneServerDropsModelsWithoutCBv2AdapterFromCatalog() async throws {
    // A qwen2 checkpoint has no CBv2 adapter: it must be dropped from the
    // served catalog at construction (WARN'd server-side; the CLI
    // additionally prints a per-model error and refuses to start when
    // nothing remains). A request for the dropped id then gets a clear
    // 404 — never a silent legacy serve (there is no legacy engine).
    let unsupported = ModelInfo(
        id: "mlx-community/Qwen2.5-7B-4bit",
        modelType: "qwen2",
        quantization: "4bit",
        sizeBytes: 4_000_000_000,
        estimatedMemoryGb: 4.5
    )
    let supported = ModelInfo(
        id: "gemma-4-26b-qat-4bit",
        modelType: "gemma4",
        quantization: "4bit",
        sizeBytes: 15_000_000_000,
        estimatedMemoryGb: 16.0
    )
    let server = StandaloneServer(models: [unsupported, supported])
    #expect(await server.advertisedModelIds() == ["gemma-4-26b-qat-4bit"])

    // setModels applies the same filter (rescan path).
    await server.setModels([unsupported])
    #expect(await server.advertisedModelIds() == [])

    // Request-time: the dropped id surfaces as a clear 404 envelope.
    await server.setModels([unsupported, supported])
    let app = server.makeApplication()
    try await app.test(.router) { client in
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"model":"mlx-community/Qwen2.5-7B-4bit","messages":[{"role":"user","content":"hi"}],"stream":false}"#)
        ) { response in
            #expect(response.status == .notFound,
                "a model without a CBv2 adapter must 404, got \(response.status)")
            let body = String(buffer: response.body)
            #expect(body.contains(#""error""#))
        }
    }
    _ = server
}

// MARK: - v0.7.5 one-engine: 32 MiB chat-route body ceiling

@Test func standaloneServerAcceptsChatBodiesPastTheOldTwoMiBLimit() async throws {
    // Regression for the known 413 backlog item: the upstream router's
    // BasicRequestContext pins Hummingbird's 2 MiB decode default, which
    // 413'd inline media at ~1.5 MB of source bytes. The chat routes are
    // now served by LocalChatUploadResponder with a 32 MiB ceiling: a
    // 3 MiB request must get PAST the body limit and reach the engine —
    // observable as the engine's 404 for an unknown model id, not a 413.
    let app = standaloneTestServer().makeApplication()
    let padding = String(repeating: "a", count: 3 * 1024 * 1024)
    let body = #"{"model":"mlx-test","messages":[{"role":"user","content":""# + padding
        + #""}],"stream":false}"#

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .notFound,
                "a 3 MiB chat body must clear the raised upload ceiling and reach the engine (404 unknown model), got \(response.status)")
        }
        // The streaming variant takes the SSE branch of the interception
        // responder; its pre-stream throw must surface identically.
        let streamingBody = body.replacingOccurrences(
            of: #""stream":false"#, with: #""stream":true"#)
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: streamingBody)
        ) { response in
            #expect(response.status == .notFound)
        }
    }
}

@Test func standaloneServerRejectsChatBodiesOverThirtyTwoMiB() async throws {
    let app = standaloneTestServer().makeApplication()
    // One byte over the ceiling: collected under the 32 MiB limit → 413
    // with an OpenAI-shaped envelope naming the real limit.
    let oversized = ByteBuffer(repeating: UInt8(ascii: "x"),
                               count: localInferenceMaxUploadBytes + 1)

    try await app.test(.router) { client in
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .post,
            headers: [.contentType: "application/json"],
            body: oversized
        ) { response in
            #expect(response.status == .contentTooLarge,
                "a body over 32 MiB must 413, got \(response.status)")
            let body = String(buffer: response.body)
            #expect(body.contains(#""error""#))
            #expect(body.contains("32 MiB"))
        }
    }
}

@Test func standaloneMalformedChatBodyStillMapsTo400() async throws {
    // Regression (independent review P2): the interception responder
    // decodes the body itself, and a raw DecodingError would escape the
    // CORS/error layers as a body-less 500 — the stock Hummingbird decode
    // converts every DecodingError into a 400. Pin the 400.
    let app = standaloneTestServer().makeApplication()
    try await app.test(.router) { client in
        // Type mismatch: "model" must be a string.
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"model":42,"messages":[]}"#)
        ) { response in
            #expect(response.status == .badRequest,
                "malformed chat JSON must map to 400 like the stock decode path, got \(response.status)")
        }
        // Truncated / non-JSON body.
        try await client.execute(
            uri: "/v1/chat/completions",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"model":"m","mess"#)
        ) { response in
            #expect(response.status == .badRequest)
        }
    }
}

@Test func standaloneBatchChatRouteGetsTheRaisedCeilingToo() async throws {
    // The batch route decodes [OpenAIChatCompletionRequest] — the same
    // media-capable payload type — so it rides the same 32 MiB ceiling.
    let app = standaloneTestServer().makeApplication()
    let padding = String(repeating: "b", count: 3 * 1024 * 1024)
    let body = #"[{"model":"mlx-test","messages":[{"role":"user","content":""# + padding
        + #""}],"stream":false}]"#
    try await app.test(.router) { client in
        try await client.execute(
            uri: "/v1/chat/completions/batch",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: body)
        ) { response in
            // Past the old 2 MiB limit and into the engine: the unknown
            // model id 404s (a 413 would mean the ceiling never applied).
            #expect(response.status == .notFound,
                "a 3 MiB batch body must clear the raised ceiling, got \(response.status)")
        }
    }
}

@Test func standaloneNonChatRoutesKeepTheUpstreamDecodePath() async throws {
    // The interception is scoped to the chat-completions POSTs; other
    // routes still decode inside the upstream router (2 MiB default).
    // /tokenize with a small body proves the pass-through still routes.
    let app = standaloneTestServer().makeApplication()
    try await app.test(.router) { client in
        try await client.execute(
            uri: "/tokenize",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: #"{"prompt":"hello"}"#)
        ) { response in
            // No model loaded → the engine's tokenizer resolution fails —
            // what matters here is that the route was SERVED by the
            // upstream router (any mapped engine error, never a 413/route
            // miss).
            #expect(response.status != .notImplemented)
            #expect(response.status != .contentTooLarge)
        }
    }
}

// MARK: - v0.7.5 one-engine: v2 slot construction + KV re-slice

private final class StandaloneStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct StandaloneStubProcessorError: Error {}

private struct StandaloneStubProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw StandaloneStubProcessorError()
    }
}

private func makeStandaloneStubContainer() -> ModelContainer {
    ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "test/standalone-stub-model"),
            model: StandaloneStubLanguageModel(),
            processor: StandaloneStubProcessor(),
            tokenizer: StubBridgeTokenizer()
        ))
}

private let standaloneGiB: UInt64 = 1024 * 1024 * 1024
private let standalonePhysicalBytes: UInt64 = 64 * standaloneGiB

private func standaloneSizing(
    weightsGiB: UInt64, kvRate: Int = 20_480, maxContext: Int = 131_072
) -> SlotSizingSnapshot {
    SlotSizingSnapshot(
        weightsBytes: Int(weightsGiB * standaloneGiB),
        fp16KVBytesPerToken: kvRate,
        maxContextLength: maxContext,
        defaultMaxTokens: StandaloneServer.slotDefaultMaxTokens)
}

/// Thread-safe recorder of the grants the scripted engine builder saw.
private final class StandaloneGrantRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(modelId: String, grant: Int, engine: InertStubEngine)] = []
    var entries: [(modelId: String, grant: Int, engine: InertStubEngine)] {
        lock.withLock { _entries }
    }
    func record(modelId: String, grant: Int, engine: InertStubEngine) {
        lock.withLock { _entries.append((modelId, grant, engine)) }
    }
}

private struct StandalonePendingLoadObservation: Error {
    let reservedBytes: UInt64
}

private func makeStandaloneFakeHFSnapshot(modelId: String) throws -> URL {
    let cacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    let modelDir = cacheDir.appendingPathComponent(
        "models--\(modelId.replacingOccurrences(of: "/", with: "--"))", isDirectory: true)
    let snapshot = modelDir
        .appendingPathComponent("snapshots", isDirectory: true)
        .appendingPathComponent("main", isDirectory: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
    return modelDir
}

@Test func standalonePendingLoadReservesWeightsBeforeAwaitingContainer() async throws {
    let modelId = "darkbloom-tests/standalone-pending-\(UUID().uuidString.prefix(8))"
    let fakeDir = try makeStandaloneFakeHFSnapshot(modelId: modelId)
    defer { try? FileManager.default.removeItem(at: fakeDir) }

    let estimatedMemoryGb = 0.25
    let expectedBytes = UInt64(estimatedMemoryGb * 1_073_741_824)
    let server = standaloneTestServer(models: [
        ModelInfo(
            id: modelId,
            modelType: "gemma4",
            quantization: "4bit",
            sizeBytes: 1,
            estimatedMemoryGb: estimatedMemoryGb)
    ])
    await server.setV2TestHooksForTesting(
        StandaloneServer.V2TestHooks(
            beforeWeightLoad: { _ in
                throw StandalonePendingLoadObservation(
                    reservedBytes: await server.debugOutstandingKVReservationBytes())
            },
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))

    do {
        try await server.ensureModelLoaded(modelId)
        Issue.record("expected the pre-weight-load observation to stop the fake load")
    } catch let observation as StandalonePendingLoadObservation {
        #expect(observation.reservedBytes == expectedBytes)
    }
    #expect(await server.debugOutstandingKVReservationBytes() == 0)
}

@Test func standaloneAcquireReturnsV2Entry() async throws {
    let server = standaloneTestServer(models: [
        ModelInfo(
            id: "gemma-4-26b-qat-4bit", modelType: "gemma4", quantization: "4bit",
            sizeBytes: 1, estimatedMemoryGb: 1)
    ])
    let recorder = StandaloneGrantRecorder()
    await server.setV2TestHooksForTesting(
        StandaloneServer.V2TestHooks(
            physicalMemoryBytes: standalonePhysicalBytes,
            makeEngine: { modelId, grant in
                let engine = InertStubEngine(kvBytesCapacity: grant)
                recorder.record(modelId: modelId, grant: grant, engine: engine)
                return engine
            }))

    let bridge = try await server.buildSlotForTesting(
        modelId: "gemma-4-26b-qat-4bit",
        modelType: "gemma4",
        container: makeStandaloneStubContainer(),
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        sizing: standaloneSizing(weightsGiB: 15))

    // acquireModel returns the v2-shaped entry: bridge populated (the
    // legacy scheduler is gone from the AcquiredModel type entirely —
    // the bridge is the only serving engine).
    let acquired = try await server.acquireModel("gemma-4-26b-qat-4bit")
    #expect(acquired.engineV2Bridge === bridge)
    #expect(acquired.modelType == "gemma4")
    #expect(acquired.visionGate != nil)
    #expect(await server.debugSlotReservationCount(modelId: "gemma-4-26b-qat-4bit") == 1)
    await acquired.releaseToken.fire()
    #expect(await server.debugSlotReservationCount(modelId: "gemma-4-26b-qat-4bit") == 0)

    // A single-model box got the FULL fleet budget (never a static split).
    let expected = UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: standalonePhysicalBytes,
        residentWeightBytes: UInt64(standaloneSizing(weightsGiB: 15).weightsBytes),
        configReserveBytes: 0)
    #expect(recorder.entries.map(\.grant) == [Int(expected)])
}

@Test func standaloneSecondLoadReslicesAndEvictionRegrows() async throws {
    let server = standaloneTestServer()
    let recorder = StandaloneGrantRecorder()
    await server.setV2TestHooksForTesting(
        StandaloneServer.V2TestHooks(
            physicalMemoryBytes: standalonePhysicalBytes,
            makeEngine: { modelId, grant in
                let engine = InertStubEngine(kvBytesCapacity: grant)
                recorder.record(modelId: modelId, grant: grant, engine: engine)
                return engine
            }))

    // Slot A alone: full budget.
    let sizingA = standaloneSizing(weightsGiB: 15, kvRate: 20_480)
    _ = try await server.buildSlotForTesting(
        modelId: "gemma-4-26b-qat-4bit", modelType: "gemma4",
        container: makeStandaloneStubContainer(),
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        sizing: sizingA)
    let grantA0 = try #require(await server.debugEngineKVGrant(modelId: "gemma-4-26b-qat-4bit"))

    // Slot B loads: A shrinks to its fair share, Σ ≤ the fleet budget,
    // exactly the shared pure policy's targets.
    let sizingB = standaloneSizing(weightsGiB: 12, kvRate: 24_576)
    _ = try await server.buildSlotForTesting(
        modelId: "gpt-oss-20b", modelType: "gpt_oss",
        container: makeStandaloneStubContainer(),
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        sizing: sizingB)

    let fleetBudget = UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: standalonePhysicalBytes,
        residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
        configReserveBytes: 0)
    let targets = EngineV2KVSizing.resliceGrants(
        existing: [
            .init(
                modelId: "gemma-4-26b-qat-4bit",
                fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                maxContextLength: sizingA.maxContextLength)
        ],
        newcomer: .init(
            modelId: "gpt-oss-20b",
            fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
            maxContextLength: sizingB.maxContextLength),
        fleetKVBudgetBytes: fleetBudget)
    let grantA1 = try #require(await server.debugEngineKVGrant(modelId: "gemma-4-26b-qat-4bit"))
    let grantB = try #require(await server.debugEngineKVGrant(modelId: "gpt-oss-20b"))
    #expect(grantA1 == targets["gemma-4-26b-qat-4bit"])
    #expect(grantB == targets["gpt-oss-20b"])
    #expect(grantA1 < grantA0)
    #expect(UInt64(grantA1 + grantB) <= fleetBudget)

    // Evict the LRU idle slot (A — loaded first): B regrows to the FULL
    // budget under its own weights, and A's engine was drained.
    let evicted = await server.evictLRUIdleSlotForTesting()
    #expect(evicted)
    #expect(await server.debugEngineKVGrant(modelId: "gemma-4-26b-qat-4bit") == nil)
    #expect(recorder.entries[0].engine.shutdownCalls == 1)
    let fullB = UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: standalonePhysicalBytes,
        residentWeightBytes: UInt64(sizingB.weightsBytes),
        configReserveBytes: 0)
    #expect(await server.debugEngineKVGrant(modelId: "gpt-oss-20b") == Int(fullB))
}

@Test func standaloneEngineV2MaxConcurrentReachesTheBridge() async throws {
    // §1.9: engine_v2_max_concurrent (+ per-model override) must govern
    // standalone engines exactly as it does ProviderLoop ones — clamped
    // to [1, 8] and visible on the bridge's capacity snapshot.
    let server = StandaloneServer(
        config: StandaloneServerConfig(
            engineV2MaxConcurrent: 6,
            engineV2MaxConcurrentByModel: ["gpt-oss-20b": 2]))
    await server.setV2TestHooksForTesting(
        StandaloneServer.V2TestHooks(
            physicalMemoryBytes: standalonePhysicalBytes,
            makeEngine: { _, grant in InertStubEngine(kvBytesCapacity: grant) }))

    let gptoss = try await server.buildSlotForTesting(
        modelId: "gpt-oss-20b", modelType: "gpt_oss",
        container: makeStandaloneStubContainer(),
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        sizing: standaloneSizing(weightsGiB: 12, kvRate: 24_576))
    #expect(await gptoss.backendSlotCapacity().maxConcurrency == 2,
        "per-model engine_v2_max_concurrent_by_model override must win")

    let gemma = try await server.buildSlotForTesting(
        modelId: "gemma-4-26b-qat-4bit", modelType: "gemma4",
        container: makeStandaloneStubContainer(),
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        sizing: standaloneSizing(weightsGiB: 15))
    #expect(await gemma.backendSlotCapacity().maxConcurrency == 6,
        "the box-wide engine_v2_max_concurrent must cover everything else")
}

@Test func standaloneConstructionFailureRestoresGrantsAndMapsTo503Shape() async throws {
    struct BuildFailure: Error {}
    let server = standaloneTestServer()
    let recorder = StandaloneGrantRecorder()
    await server.setV2TestHooksForTesting(
        StandaloneServer.V2TestHooks(
            physicalMemoryBytes: standalonePhysicalBytes,
            makeEngine: { modelId, grant in
                let engine = InertStubEngine(kvBytesCapacity: grant)
                recorder.record(modelId: modelId, grant: grant, engine: engine)
                return engine
            }))
    let sizingA = standaloneSizing(weightsGiB: 15)
    _ = try await server.buildSlotForTesting(
        modelId: "gemma-4-26b-qat-4bit", modelType: "gemma4",
        container: makeStandaloneStubContainer(),
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        sizing: sizingA)
    let grantA0 = try #require(await server.debugEngineKVGrant(modelId: "gemma-4-26b-qat-4bit"))

    // B's engine construction fails: A must be restored to its EXACT
    // prior grant (shrink → restore trail on the engine).
    await server.setV2TestHooksForTesting(
        StandaloneServer.V2TestHooks(
            physicalMemoryBytes: standalonePhysicalBytes,
            makeEngine: { _, _ in throw BuildFailure() }))
    await #expect(throws: BuildFailure.self) {
        _ = try await server.buildSlotForTesting(
            modelId: "gpt-oss-20b", modelType: "gpt_oss",
            container: makeStandaloneStubContainer(),
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            sizing: standaloneSizing(weightsGiB: 12, kvRate: 24_576))
    }
    #expect(await server.debugEngineKVGrant(modelId: "gemma-4-26b-qat-4bit") == grantA0)
    let updates = recorder.entries[0].engine.capacityUpdates
    #expect(updates.count == 2)
    #expect((updates.first ?? 0) < grantA0)
    #expect(updates.last == grantA0)
    #expect(await server.debugEngineKVGrant(modelId: "gpt-oss-20b") == nil)
}

/// Lock-guarded weak holder so @Sendable probes can ask "is B's container
/// still alive?" at grant-update time.
private final class StandaloneWeakContainerRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: AnyObject?
    init(_ value: AnyObject) { self._value = value }
    var isAlive: Bool { lock.withLock { _value != nil } }
}

/// Thread-safe trail of (grantBytes, newcomerAliveAtThatInstant).
private final class StandaloneAlivenessTrail: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(bytes: Int, newcomerAlive: Bool)] = []
    func record(bytes: Int, alive: Bool) { lock.withLock { _entries.append((bytes, alive)) }
    }
    var entries: [(bytes: Int, newcomerAlive: Bool)] { lock.withLock { _entries } }
}

@Test func standaloneConstructionFailureReleasesWeightsBeforeRestoringGrants() async throws {
    // Regression (Codex, v0.7.5 review — StandaloneServer unwind ordering):
    // when `darkbloom start --local` shrinks co-resident slots and the v2
    // bridge construction then throws, the failed newcomer's weights must
    // stop being resident BEFORE the survivors' grants are restored — the
    // same ordering ProviderLoop enforces via EngineV2NewcomerBox. Pre-fix,
    // the standalone catch restored grants while the newcomer container was
    // still strongly held by the load path, so a request re-entering the
    // actor for an already-loaded model could be admitted against capacity
    // that assumed the failed weights were gone.
    struct BuildFailure: Error {}
    let server = standaloneTestServer()

    let sizingA = standaloneSizing(weightsGiB: 15, kvRate: 20_480)
    let sizingB = standaloneSizing(weightsGiB: 12, kvRate: 24_576)
    let grantA0 = Int(UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: standalonePhysicalBytes,
        residentWeightBytes: UInt64(sizingA.weightsBytes),
        configReserveBytes: 0))

    // B's container: the ONLY strong reference lives in the box; the test
    // keeps a weak observer (the scoped `do` drops the local strong ref).
    let weakB: StandaloneWeakContainerRef
    let box: EngineV2NewcomerBox
    do {
        let containerB = makeStandaloneStubContainer()
        weakB = StandaloneWeakContainerRef(containerB)
        box = EngineV2NewcomerBox(containerB)
    }
    #expect(weakB.isAlive)

    // Install survivor A holding the full single-model budget, with a probe
    // engine that records B's aliveness at each grant mutation.
    let trail = StandaloneAlivenessTrail()
    let engineA = InertStubEngine(
        kvBytesCapacity: grantA0,
        onUpdate: { bytes in trail.record(bytes: bytes, alive: weakB.isAlive) })
    let bridgeA = EngineV2Bridge(
        engine: engineA,
        modelId: "gemma-4-26b-qat-4bit",
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        eosTokenIds: [])
    await server.installSlotForTesting(
        modelId: "gemma-4-26b-qat-4bit",
        bridge: bridgeA,
        container: makeStandaloneStubContainer(),
        tokenizer: TokenizerHandle(StubBridgeTokenizer()),
        sizing: sizingA,
        modelType: "gemma4")

    // The newcomer's engine build fails AFTER A was shrunk.
    await server.setV2TestHooksForTesting(
        StandaloneServer.V2TestHooks(
            physicalMemoryBytes: standalonePhysicalBytes,
            makeEngine: { _, _ in throw BuildFailure() }))

    await #expect(throws: BuildFailure.self) {
        _ = try await server.resliceAndBuildSlotForTesting(
            modelId: "gpt-oss-20b",
            modelType: "gpt_oss",
            newcomer: box,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()),
            sizing: sizingB)
    }

    // Expected two-model shrink target (same pure policy).
    let bothBudget = UnifiedMemoryCap.kvBudgetBytes(
        physicalBytes: standalonePhysicalBytes,
        residentWeightBytes: UInt64(sizingA.weightsBytes + sizingB.weightsBytes),
        configReserveBytes: 0)
    let targets = EngineV2KVSizing.resliceGrants(
        existing: [
            .init(
                modelId: "gemma-4-26b-qat-4bit",
                fp16KVBytesPerToken: sizingA.fp16KVBytesPerToken,
                maxContextLength: sizingA.maxContextLength)
        ],
        newcomer: .init(
            modelId: "gpt-oss-20b",
            fp16KVBytesPerToken: sizingB.fp16KVBytesPerToken,
            maxContextLength: sizingB.maxContextLength),
        fleetKVBudgetBytes: bothBudget)
    let shrinkTarget = try #require(targets["gemma-4-26b-qat-4bit"])

    // Trail: [shrink (B resident — inherent to loading), restore].
    let entries = trail.entries
    #expect(entries.count == 2)
    #expect(entries.first?.bytes == shrinkTarget)
    #expect(entries.first?.newcomerAlive == true)
    // THE ORDERING UNDER TEST: at the instant A's grant is restored, B's
    // weights are no longer resident.
    #expect(entries.last?.bytes == grantA0)
    #expect(
        entries.last?.newcomerAlive == false,
        "survivor grants must be restored only AFTER the failed newcomer's weights are released")

    // End state: box drained, A exactly restored, B never installed.
    #expect(box.container == nil)
    #expect(!weakB.isAlive)
    #expect(await server.debugEngineKVGrant(modelId: "gemma-4-26b-qat-4bit") == grantA0)
    #expect(await server.debugEngineKVGrant(modelId: "gpt-oss-20b") == nil)
}
