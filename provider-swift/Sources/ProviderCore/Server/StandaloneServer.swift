/// Standalone HTTP server for local/standalone mode.
///
/// Serves OpenAI-compatible inference requests directly without a coordinator.
/// The HTTP transport is handled by Hummingbird; inference still flows through
/// `BatchScheduler`.
///
/// Endpoints:
///   - GET  /health              -> {"status":"ok","version":"..."}
///   - GET  /v1/models           -> OpenAI models list
///   - POST /v1/chat/completions -> streaming SSE or JSON response

import Foundation
import Hummingbird
import MLXLLM
import MLXLMCommon
import os

private enum StandaloneServerError: Error, LocalizedError {
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let id): return "Model '\(id)' not found locally"
        }
    }
}

// MARK: - Public API

/// Configuration for the standalone server.
public struct StandaloneServerConfig: Sendable {
    public let port: UInt16
    public let host: String

    public init(port: UInt16 = 8000, host: String = "127.0.0.1") {
        self.port = port
        self.host = host
    }
}

private let standaloneLogger = Logger(
    subsystem: "dev.darkbloom.provider",
    category: "StandaloneServer"
)

public actor StandaloneServer {

    /// Tracks a loaded model scheduler and when it was last used for LRU eviction.
    private struct CachedScheduler {
        let scheduler: BatchScheduler
        var lastUsedAt: ContinuousClock.Instant
    }

    private let config: StandaloneServerConfig
    private var schedulers: [String: CachedScheduler] = [:]
    private var modelsLoading: Set<String> = []
    private var loadingWaiters: [String: [CheckedContinuation<Void, any Error>]] = [:]
    private var models: [ModelInfo]
    private var serverTask: Task<Void, Never>?

    /// Maximum number of models kept warm in standalone mode. Oldest models
    /// are evicted (LRU) when this limit is reached.
    private static let maxCachedModels = 3

    public init(
        config: StandaloneServerConfig = StandaloneServerConfig(),
        models: [ModelInfo] = []
    ) {
        self.config = config
        self.models = models
    }

    private static let schedulerMaxConcurrent = 4
    private static let schedulerPendingTimeout: Duration = .seconds(120)
    private static let schedulerDefaultMaxTokens = 4096

    public func loadModel(_ modelId: String, container: MLXLMCommon.ModelContainer) async {
        // Evict least-recently-used model if at capacity
        if schedulers.count >= Self.maxCachedModels {
            if let lru = schedulers.min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt }) {
                await lru.value.scheduler.unloadModel()
                schedulers.removeValue(forKey: lru.key)
                standaloneLogger.info("Evicted LRU model: \(lru.key)")
            }
        }

        let scheduler = BatchScheduler(
            maxConcurrentRequests: Self.schedulerMaxConcurrent,
            pendingTimeout: Self.schedulerPendingTimeout,
            defaultMaxTokens: Self.schedulerDefaultMaxTokens
        )
        await scheduler.loadModel(container: container, modelId: modelId)
        schedulers[modelId] = CachedScheduler(scheduler: scheduler, lastUsedAt: .now)
    }

    /// Touch the cached scheduler's last-used timestamp on access.
    private func touchScheduler(_ modelId: String) {
        schedulers[modelId]?.lastUsedAt = .now
    }

    private func ensureModelLoaded(_ modelId: String) async throws {
        if schedulers[modelId] != nil {
            touchScheduler(modelId)
            return
        }

        if modelsLoading.contains(modelId) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                loadingWaiters[modelId, default: []].append(cont)
            }
            return
        }

        guard models.contains(where: { $0.id == modelId }) else {
            throw StandaloneServerError.modelNotFound(modelId)
        }

        guard let modelPath = ModelScanner.resolveLocalPath(modelID: modelId) else {
            throw StandaloneServerError.modelNotFound(modelId)
        }

        modelsLoading.insert(modelId)
        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: modelPath,
                using: LocalTokenizerLoader()
            )
            await loadModel(modelId, container: container)
            standaloneLogger.info("Lazy-loaded model: \(modelId)")

            modelsLoading.remove(modelId)
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume()
            }
        } catch {
            modelsLoading.remove(modelId)
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume(throwing: error)
            }
            throw error
        }
    }

    /// Update the advertised model list (e.g. after a rescan).
    public func setModels(_ newModels: [ModelInfo]) {
        self.models = newModels
    }

    /// Start listening for HTTP connections. The server runs in a child task.
    public func start() throws {
        guard serverTask == nil else { return }

        let app = makeApplication()
        serverTask = Task {
            do {
                standaloneLogger.info("Standalone server listening on \(self.config.host):\(self.config.port)")
                try await app.runService(gracefulShutdownSignals: [])
            } catch is CancellationError {
                standaloneLogger.info("Standalone server cancelled")
            } catch {
                standaloneLogger.error("Standalone server failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stop the server.
    public func stop() {
        serverTask?.cancel()
        serverTask = nil
    }

    /// Returns the port the server is configured on.
    public var port: UInt16 {
        config.port
    }

    /// Build a Hummingbird application for this server. This is internal so
    /// endpoint tests can exercise the router without opening a socket.
    nonisolated func makeApplication() -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router()
        router.add(middleware: StandaloneHeadersMiddleware())

        router.get("/health") { _, _ async -> Response in
            self.healthResponse()
        }

        router.get("/v1/models") { _, _ async -> Response in
            await self.modelsResponse()
        }

        router.post("/v1/chat/completions") { request, context async -> Response in
            await self.chatCompletionsResponse(request: request, context: context)
        }

        return Application(
            router: router,
            configuration: .init(
                address: .hostname(config.host, port: Int(config.port)),
                serverName: "darkbloom-provider"
            )
        )
    }

    // MARK: - Endpoint Handlers

    private nonisolated func healthResponse() -> Response {
        jsonResponse(HealthResponse(status: "ok", version: ProviderCore.version))
    }

    private func modelsResponse() -> Response {
        let modelObjects = models.map { model in
            OpenAIModel(
                id: model.id,
                object: "model",
                created: 0,
                owned_by: "local"
            )
        }
        let response = OpenAIModelsResponse(object: "list", data: modelObjects)
        return jsonResponse(response)
    }

    private func chatCompletionsResponse(
        request: Request,
        context: BasicRequestContext
    ) async -> Response {
        if let contentType = request.headers[.contentType],
           !contentType.lowercased().hasPrefix("application/json")
        {
            return openAIErrorResponse(
                status: .unsupportedMediaType,
                message: "Content-Type must be application/json"
            )
        }

        let chatRequest: ChatCompletionRequest
        do {
            chatRequest = try await request.decode(as: ChatCompletionRequest.self, context: context)
        } catch {
            return openAIErrorResponse(status: .badRequest, message: "Invalid request body")
        }

        do {
            try await ensureModelLoaded(chatRequest.model)
        } catch let error as StandaloneServerError {
            return openAIErrorResponse(
                status: .notFound,
                message: error.localizedDescription
            )
        } catch {
            return openAIErrorResponse(
                status: .internalServerError,
                message: "Failed to load model '\(chatRequest.model)': \(error.localizedDescription)"
            )
        }

        guard let cached = schedulers[chatRequest.model] else {
            return openAIErrorResponse(
                status: .internalServerError,
                message: "Model load succeeded but scheduler unavailable"
            )
        }
        touchScheduler(chatRequest.model)

        if chatRequest.stream ?? false {
            let stream = await cached.scheduler.submit(request: chatRequest)
            return streamingCompletionResponse(stream: stream, model: chatRequest.model)
        }

        return await nonStreamingCompletion(chatRequest, scheduler: cached.scheduler)
    }

    private nonisolated func streamingCompletionResponse(
        stream: AsyncStream<GenerationEvent>,
        model: String
    ) -> Response {
        var headers = defaultHeaders(contentType: "text/event-stream")
        headers[.cacheControl] = "no-cache"
        headers[.connection] = "keep-alive"

        let body = ResponseBody { writer in
            let formatter = OpenAIFormatter()
            let completionID = formatter.makeCompletionID()
            let created = Int(Date().timeIntervalSince1970)

            try await writer.write(ByteBuffer(string: formatter.roleChunk(
                id: completionID,
                model: model,
                created: created
            ).formatted))

            var promptTokens = 0
            var completionTokens = 0

            for await event in stream {
                switch event {
                case .chunk(let text):
                    completionTokens += 1
                    let chunk = formatter.contentChunk(
                        id: completionID,
                        model: model,
                        created: created,
                        text: text
                    )
                    try await writer.write(ByteBuffer(string: chunk.formatted))

                case .info(let prompt, let completion, _):
                    promptTokens = prompt
                    completionTokens = completion

                case .error(let message):
                    standaloneLogger.error("Generation error during streaming: \(message)")
                }
            }

            let usage = ChunkUsage(prompt_tokens: promptTokens, completion_tokens: completionTokens)
            let stopChunk = formatter.stopChunk(
                id: completionID,
                model: model,
                created: created,
                finishReason: "stop",
                usage: usage
            )
            try await writer.write(ByteBuffer(string: stopChunk.formatted))
            try await writer.write(ByteBuffer(string: SSEChunk.done.formatted))
            try await writer.finish(nil)
        }

        return Response(status: .ok, headers: headers, body: body)
    }

    private func nonStreamingCompletion(_ chatRequest: ChatCompletionRequest, scheduler: BatchScheduler) async -> Response {
        let stream = await scheduler.submit(request: chatRequest)
        let formatter = OpenAIFormatter()
        let completionID = formatter.makeCompletionID()
        let created = Int(Date().timeIntervalSince1970)

        var fullContent = ""
        var promptTokens = 0
        var completionTokens = 0

        for await event in stream {
            switch event {
            case .chunk(let text):
                fullContent += text

            case .info(let prompt, let completion, _):
                promptTokens = prompt
                completionTokens = completion

            case .error(let message):
                return openAIErrorResponse(status: .internalServerError, message: message)
            }
        }

        let usage = ChunkUsage(prompt_tokens: promptTokens, completion_tokens: completionTokens)
        let response = formatter.nonStreamingResponse(
            id: completionID,
            model: chatRequest.model,
            created: created,
            content: fullContent,
            finishReason: "stop",
            usage: usage
        )

        return jsonResponse(response)
    }
}
