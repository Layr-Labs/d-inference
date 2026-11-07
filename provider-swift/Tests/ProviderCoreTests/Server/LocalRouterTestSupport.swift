import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MLXLMServer
import NIOCore
import Testing
@testable import ProviderCore

/// A coordinator stand-in for the router: records every request and answers from a script. Nothing leaves the process.
final class RouterStubUpstream: LocalRouterTransport, @unchecked Sendable {
    struct Answer: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var chunks: [String] = []
        /// Waits before each chunk after the first.
        var gap: Duration?
        /// Never answers: the request waits until it is cancelled.
        var hang = false

        static func json(_ status: Int, _ body: String, retryAfter: String? = nil) -> Answer {
            var headers = ["content-type": "application/json"]
            if let retryAfter { headers["retry-after"] = retryAfter }
            return Answer(status: status, headers: headers, chunks: [body])
        }
    }

    struct Unreachable: Error {}

    private let lock = NSLock()
    private var recorded: [LocalRouterUpstreamRequest] = []
    private let script: @Sendable (LocalRouterUpstreamRequest) throws -> Answer

    init(_ script: @escaping @Sendable (LocalRouterUpstreamRequest) throws -> Answer) { self.script = script }

    var requests: [LocalRouterUpstreamRequest] { lock.withLock { recorded } }
    /// The inference requests (POST), without the model-list reads.
    var posts: [LocalRouterUpstreamRequest] { requests.filter { $0.method == "POST" } }

    func send(_ request: LocalRouterUpstreamRequest) async throws -> LocalRouterUpstreamResponse {
        lock.withLock { recorded.append(request) }
        let answer = try script(request)
        if answer.hang {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        let (body, continuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
        let producer = Task {
            for (index, chunk) in answer.chunks.enumerated() {
                if index > 0, let gap = answer.gap { try? await Task.sleep(for: gap) }
                continuation.yield(ByteBuffer(string: chunk))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in producer.cancel() }
        return LocalRouterUpstreamResponse(status: answer.status, headers: answer.headers, body: body, cancel: {
            producer.cancel()
            continuation.finish(throwing: CancellationError())
        })
    }
}

/// Counts how often the router makes its upstream client.
final class RouterTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    let transport: any LocalRouterTransport

    init(_ transport: any LocalRouterTransport) { self.transport = transport }

    var count: Int { lock.withLock { made } }

    func make() -> any LocalRouterTransport {
        lock.withLock { made += 1 }
        return transport
    }
}

/// An in-memory key store that counts its reads (this Mac's path reads none), and can fail them as a Keychain that
/// won't hand the key over does.
final class CountingAccountKeyStore: LocalRouterAccountKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?
    private var reads = 0
    private var failure: OSStatus?
    init(_ key: String?) { self.key = key }
    var loads: Int { lock.withLock { reads } }
    /// Every read from now on fails with `status`; nil: reads succeed again.
    func failReads(with status: OSStatus?) { lock.withLock { failure = status } }
    func load() throws -> String? {
        try lock.withLock {
            reads += 1
            if let failure { throw LocalRouterAccountKeyError.keychain(operation: "read", status: failure) }
            return key
        }
    }
    func save(_ key: String) throws { lock.withLock { self.key = key } }
    func remove() throws { lock.withLock { key = nil } }
}

/// Every line the router logs.
final class RouterLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }
}

/// This Mac's engine for router tests: the model name says what it does. Records what it was asked.
///
/// - `here`: answers "hi" three times (streamed or whole). `cut`: streams once, then fails mid-stream.
/// - `busy`: queue full (429). `draining`: refuses new work (503).
/// - `bad`: a client error (400). `boom`: an engine failure (500). Any other model is not served here (404).
final class RouterStubEngine: MLXServerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [OpenAIChatCompletionRequest] = []
    var requests: [OpenAIChatCompletionRequest] { lock.withLock { seen } }
    /// Other ids this Mac answers like `here`, and other ids it refuses like `busy`.
    let serves: Set<String>
    let busy: Set<String>

    init(serves: Set<String> = [], busy: Set<String> = []) {
        self.serves = serves
        self.busy = busy
    }

    static let servedModels = ["busy", "cut", "draining", "here"]

    func availableModels() async throws -> [MLXServerModel] { Self.servedModels.map { MLXServerModel(id: $0) } }

    func streamChatCompletion(request: OpenAIChatCompletionRequest)
        async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        lock.withLock { seen.append(request) }
        switch request.model {
        case "here", "cut": break
        case let model where serves.contains(model): break
        case let model where busy.contains(model): throw MultiModelBatchSchedulerEngineError.queueFull("queue full")
        case "busy": throw MultiModelBatchSchedulerEngineError.queueFull("queue full")
        case "draining": throw MultiModelBatchSchedulerEngineError.requestRejected("provider draining")
        case "bad": throw MultiModelBatchSchedulerEngineError.invalidRole("fixture")
        case "boom": throw MultiModelBatchSchedulerEngineError.generationFailed("fixture")
        default: throw MultiModelBatchSchedulerEngineError.modelNotLoaded(request.model)
        }
        let failsMidStream = request.model == "cut"
        return AsyncThrowingStream { continuation in
            continuation.yield(.content("hi"))
            if failsMidStream {
                continuation.finish(throwing: MultiModelBatchSchedulerEngineError.generationFailed("fixture"))
                return
            }
            continuation.yield(.content(" hi"))
            continuation.yield(.content(" hi"))
            continuation.yield(.info(ServerGenerationInfo(promptTokens: 3, completionTokens: 3, promptTime: 0,
                                                          generationTime: 0, stopReason: "stop")))
            continuation.finish()
        }
    }

    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse {
        throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
    }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse {
        throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
    }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse {
        throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
    }
}

/// The local API with a router over the stub engine and the stub coordinator.
struct RouterFixture {
    static let localKey = "dk-local-SyntheticRouterFixtureKeyAAAAAAAAAAAAAAAAAAAAAAAA"
    static let accountKey = "sk-synthetic-account-key-7f3a9c1e5b2d4086"
    static let upstreamBase = URL(string: "http://coordinator.invalid:8080")!

    let engine: RouterStubEngine
    let upstream: RouterStubUpstream
    let factory: RouterTransportFactory
    let log = RouterLogLines()
    let keys: CountingAccountKeyStore
    /// nil: the endpoint without a router (today's endpoint).
    let routerConfig: LocalRouterConfig?
    let localModels: [String]
    let localLimits: [String: LocalModelLimits]
    /// The local API's key; nil is `--no-auth`.
    let localKey: String?
    var app: LocalInferenceApplication { makeApp() }

    /// - Parameters:
    ///   - route: `[local] route`; nil = absent.
    ///   - key: the saved account key; nil = none.
    ///   - router: false builds the endpoint without a router (today's endpoint).
    init(route: LocalSettings.Route? = .myMacs, key: String? = RouterFixture.accountKey, router: Bool = true,
         takesCoordinatorWork: Bool = false, localModels: [String] = RouterStubEngine.servedModels,
         localLimits: [String: LocalModelLimits] = [:], timing: LocalRouter.Timing = .init(),
         engineServes: Set<String> = [], engineBusy: Set<String> = [], localKey: String? = RouterFixture.localKey,
         upstream script: @escaping @Sendable (LocalRouterUpstreamRequest) throws -> RouterStubUpstream.Answer = { _ in
             .json(200, #"{"id":"chatcmpl-up","object":"chat.completion","choices":[]}"#)
         }) {
        engine = RouterStubEngine(serves: engineServes, busy: engineBusy)
        self.localKey = localKey
        upstream = RouterStubUpstream(script)
        factory = RouterTransportFactory(upstream)
        keys = CountingAccountKeyStore(key)
        self.localModels = localModels
        self.localLimits = localLimits
        let factory = factory, log = log
        routerConfig = router ? LocalRouterConfig(
            settings: LocalSettings(route: route), upstreamBaseURL: Self.upstreamBase,
            takesCoordinatorWork: takesCoordinatorWork, accountKeys: keys,
            makeTransport: { factory.make() }, log: { log.append($0) }, timing: timing) : nil
    }

    /// One endpoint over this fixture's engine, router and coordinator; each call makes a new application.
    func makeApp(onServerRunning: @escaping @Sendable (any Channel) async -> Void = { _ in }) -> LocalInferenceApplication {
        Self.makeApp(router: routerConfig, engine: engine, localModels: localModels, localLimits: localLimits,
                     localKey: localKey, onServerRunning: onServerRunning)
    }

    /// The local API with `router` (nil: the endpoint without a router) over `engine`, which plays this Mac.
    static func makeApp(router: LocalRouterConfig?, engine: RouterStubEngine, localModels: [String],
                        localLimits: [String: LocalModelLimits] = [:], localKey: String? = RouterFixture.localKey,
                        onServerRunning: @escaping @Sendable (any Channel) async -> Void = { _ in })
        -> LocalInferenceApplication {
        makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: localKey, router: router),
            defaultMaxTokens: 32,
            acquire: { throw MultiModelBatchSchedulerEngineError.modelNotLoaded($0) },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { localModels }, mtpSlots: { [] },
            onServerRunning: onServerRunning,
            managedSuperEngine: { _, _, _ in engine },
            modelLimits: { localLimits[$0] })
    }

    static func chat(_ model: String, stream: Bool = false, extra: String = "") -> String {
        #"{"model":"\#(model)","messages":[{"role":"user","content":"hello"}],"stream":\#(stream)\#(extra)}"#
    }

    static let authorized: HTTPFields = [.contentType: "application/json", .authorization: "Bearer \(localKey)"]
}

/// The route an upstream request used (`X-Darkbloom-Route`).
extension LocalRouterUpstreamRequest {
    var route: String? { headers[LocalRouterPolicy.routeHeader.rawName] }
    var bodyText: String { body.map { String(buffer: $0) } ?? "" }
}

/// Collects a response body written by the router or the engine, noting when the first byte came.
final class RouterRecordingWriter: ResponseBodyWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [ByteBuffer] = []
    private var firstByteAt: ContinuousClock.Instant?
    let onChunk: (@Sendable (Int) -> Void)?

    init(onChunk: (@Sendable (Int) -> Void)? = nil) { self.onChunk = onChunk }

    var text: String { lock.withLock { chunks.map { String(buffer: $0) }.joined() } }
    var chunkCount: Int { lock.withLock { chunks.count } }
    var firstByte: ContinuousClock.Instant? { lock.withLock { firstByteAt } }

    func write(_ buffer: ByteBuffer) async throws {
        let count: Int = lock.withLock {
            if firstByteAt == nil, buffer.readableBytes > 0 { firstByteAt = .now }
            chunks.append(buffer)
            return chunks.count
        }
        onChunk?(count)
    }

    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}
