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

import Darwin
import Foundation
import Hummingbird
import MLX
import MLXLLM
import MLXLMCommon
import NIOCore
import os

private enum StandaloneServerError: Error, LocalizedError {
    case modelNotFound(String)
    case capacityUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let id): return "Model '\(id)' not found locally"
        case .capacityUnavailable(let message): return message
        }
    }
}

// MARK: - Public API

/// Configuration for the standalone server.
public struct StandaloneServerConfig: Sendable {
    public let port: UInt16
    public let host: String
    public let maxCachedModels: Int

    public init(port: UInt16 = 8000, host: String = "127.0.0.1", maxCachedModels: Int = 3) {
        self.port = port
        self.host = host
        self.maxCachedModels = max(1, maxCachedModels)
    }
}

private let standaloneLogger = Logger(
    subsystem: "dev.darkbloom.provider",
    category: "StandaloneServer"
)

struct StandaloneRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    let channelCloseFuture: EventLoopFuture<Void>

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.channelCloseFuture = source.channel.closeFuture
    }
}

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
    private var isLoadingAny: Bool = false
    private var loadGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var schedulerReservations: [String: Int] = [:]
    private var evictingModels: Set<String> = []
    private var models: [ModelInfo]
    private var serverTask: Task<Void, Never>?
    private let kvBudget: GlobalKVCacheBudget

    public init(
        config: StandaloneServerConfig = StandaloneServerConfig(),
        models: [ModelInfo] = []
    ) {
        self.config = config
        self.models = models
        self.kvBudget = GlobalKVCacheBudget()
    }

    private static let schedulerMaxConcurrent = 24
    private static let schedulerPendingTimeout: Duration = .seconds(120)
    private static let schedulerDefaultMaxTokens = 4096
    private static let modelLoadMemoryMultiplier = 3.0

    static func schedulerErrorStatus(for message: String) -> HTTPResponse.Status {
        let lowercased = message.lowercased()
        if lowercased.contains("invalid token")
            || lowercased.contains("duplicate request")
            || lowercased.contains("batch token budget")
        {
            return .badRequest
        }
        if lowercased.contains("queue full") {
            return .tooManyRequests
        }
        if lowercased.contains("token_budget_exhausted")
            || lowercased.contains("timed out waiting for capacity")
            || lowercased.contains("insufficient global kv cache headroom")
        {
            return .serviceUnavailable
        }
        return .internalServerError
    }

    private func loadModel(_ modelId: String, container: MLXLMCommon.ModelContainer) async {
        let scheduler = BatchScheduler(
            maxConcurrentRequests: Self.schedulerMaxConcurrent,
            pendingTimeout: Self.schedulerPendingTimeout,
            defaultMaxTokens: Self.schedulerDefaultMaxTokens,
            kvBudget: kvBudget
        )
        await scheduler.loadModel(container: container, modelId: modelId)
        schedulers[modelId] = CachedScheduler(scheduler: scheduler, lastUsedAt: .now)
    }

    private func evictLRUIdleScheduler() async -> Bool {
        let snapshot = schedulers.map { (key: $0.key, cached: $0.value) }
        var lruKey: String?
        var lruTime: ContinuousClock.Instant?

        for entry in snapshot {
            guard schedulers[entry.key] != nil,
                  !evictingModels.contains(entry.key),
                  (schedulerReservations[entry.key] ?? 0) == 0 else { continue }

            let cap = await entry.cached.scheduler.capacity()
            guard schedulers[entry.key] != nil,
                  !evictingModels.contains(entry.key),
                  (schedulerReservations[entry.key] ?? 0) == 0,
                  cap.activeRequests == 0,
                  cap.pendingRequests == 0 else { continue }

            if lruTime == nil || entry.cached.lastUsedAt < lruTime! {
                lruKey = entry.key
                lruTime = entry.cached.lastUsedAt
            }
        }

        guard let evictKey = lruKey,
              let evicted = schedulers[evictKey],
              !evictingModels.contains(evictKey),
              (schedulerReservations[evictKey] ?? 0) == 0 else {
            return false
        }

        let cap = await evicted.scheduler.capacity()
        guard schedulers[evictKey] != nil,
              !evictingModels.contains(evictKey),
              (schedulerReservations[evictKey] ?? 0) == 0,
              cap.activeRequests == 0,
              cap.pendingRequests == 0 else {
            return false
        }

        evictingModels.insert(evictKey)
        defer { evictingModels.remove(evictKey) }
        await evicted.scheduler.unloadModel()
        if schedulers[evictKey]?.scheduler === evicted.scheduler {
            schedulers.removeValue(forKey: evictKey)
        }
        standaloneLogger.info("Evicted LRU model: \(evictKey)")
        return true
    }

    private func evictIfNeededForLoad() async throws {
        guard schedulers.count >= config.maxCachedModels else { return }

        guard await evictLRUIdleScheduler() else {
            throw StandaloneServerError.capacityUnavailable(
                "All \(config.maxCachedModels) cached model slot(s) are active; try again when a request finishes"
            )
        }
    }

    private func ensureMemoryHeadroomForLoad(requiredGb: Double) async throws {
        guard requiredGb.isFinite, requiredGb > 0 else { return }

        while availableMemoryGb() < requiredGb {
            guard await evictLRUIdleScheduler() else {
                throw StandaloneServerError.capacityUnavailable(
                    String(format: "Insufficient memory headroom to load model (needs %.1f GB available)", requiredGb)
                )
            }
        }
    }

    private nonisolated func availableMemoryGb() -> Double {
        let mlxUsedBytes = Self.saturatingAdd(UInt64(max(0, MLX.GPU.activeMemory)), UInt64(max(0, MLX.GPU.cacheMemory)))
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let mlxHeadroomBytes = totalBytes > mlxUsedBytes ? totalBytes - mlxUsedBytes : 0
        let availableBytes = min(Self.systemAvailableMemoryBytes() ?? mlxHeadroomBytes, mlxHeadroomBytes)
        return Double(availableBytes) / (1024.0 * 1024.0 * 1024.0)
    }

    private nonisolated static func systemAvailableMemoryBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let availablePages = Self.saturatingAdd(
            UInt64(stats.free_count),
            UInt64(stats.inactive_count),
            UInt64(stats.speculative_count)
        )
        let (bytes, overflow) = availablePages.multipliedReportingOverflow(by: UInt64(getpagesize()))
        return overflow ? UInt64.max : bytes
    }

    private nonisolated static func saturatingAdd(_ values: UInt64...) -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return UInt64.max }
            total = sum
        }
        return total
    }

    /// Touch the cached scheduler's last-used timestamp on access.
    private func touchScheduler(_ modelId: String) {
        schedulers[modelId]?.lastUsedAt = .now
    }

    private func reserveScheduler(_ modelId: String) {
        schedulerReservations[modelId, default: 0] += 1
        touchScheduler(modelId)
    }

    private func releaseScheduler(_ modelId: String) {
        guard let count = schedulerReservations[modelId] else { return }
        if count <= 1 {
            schedulerReservations.removeValue(forKey: modelId)
        } else {
            schedulerReservations[modelId] = count - 1
        }
        touchScheduler(modelId)
    }

    private func ensureModelLoaded(_ modelId: String) async throws {
        try Task.checkCancellation()
        if schedulers[modelId] != nil, !evictingModels.contains(modelId) {
            touchScheduler(modelId)
            return
        }

        if modelsLoading.contains(modelId) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                loadingWaiters[modelId, default: []].append(cont)
            }
            try Task.checkCancellation()
            if schedulers[modelId] != nil, !evictingModels.contains(modelId) {
                touchScheduler(modelId)
                return
            }
            try await ensureModelLoaded(modelId)
            return
        }

        guard let modelInfo = models.first(where: { $0.id == modelId }) else {
            throw StandaloneServerError.modelNotFound(modelId)
        }

        guard let modelPath = ModelScanner.resolveLocalPath(modelID: modelId) else {
            throw StandaloneServerError.modelNotFound(modelId)
        }

        // Serialize loads so concurrent requests for different models don't
        // interleave and overcommit unified memory.
        while isLoadingAny {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                loadGateWaiters.append(cont)
            }
            try Task.checkCancellation()
            // Re-check: another load may have loaded our model while we waited
            if schedulers[modelId] != nil, !evictingModels.contains(modelId) {
                touchScheduler(modelId)
                return
            }
        }
        isLoadingAny = true

        modelsLoading.insert(modelId)
        do {
            try Task.checkCancellation()
            try await evictIfNeededForLoad()
            try await ensureMemoryHeadroomForLoad(
                requiredGb: modelInfo.estimatedMemoryGb * Self.modelLoadMemoryMultiplier
            )
            try Task.checkCancellation()
            let container = try await LLMModelFactory.shared.loadContainer(
                from: modelPath,
                using: LocalTokenizerLoader()
            )
            try Task.checkCancellation()
            await loadModel(modelId, container: container)
            if Task.isCancelled, let cached = schedulers.removeValue(forKey: modelId) {
                await cached.scheduler.unloadModel()
                throw CancellationError()
            }
            standaloneLogger.info("Lazy-loaded model: \(modelId)")

            modelsLoading.remove(modelId)
            isLoadingAny = false
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume()
            }
            releaseLoadGateWaiters()
        } catch {
            modelsLoading.remove(modelId)
            isLoadingAny = false
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume(throwing: error)
            }
            releaseLoadGateWaiters()
            throw error
        }
    }

    private func releaseLoadGateWaiters() {
        let waiters = loadGateWaiters
        loadGateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
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

    /// Test helper that waits for the Hummingbird service task to finish after
    /// cancellation, so socket-level tests don't leak listeners across cases.
    func stopAndWait() async {
        let task = serverTask
        serverTask = nil
        task?.cancel()
        _ = await task?.value
        for cached in schedulers.values {
            await cached.scheduler.unloadModel()
        }
        schedulers.removeAll()
        schedulerReservations.removeAll()
    }

    func debugCapacity(modelId: String) async -> SchedulerCapacity? {
        guard let cached = schedulers[modelId] else { return nil }
        return await cached.scheduler.capacity()
    }

    func debugSchedulerReservationCount(modelId: String) -> Int {
        schedulerReservations[modelId] ?? 0
    }

    /// Returns the port the server is configured on.
    public var port: UInt16 {
        config.port
    }

    /// Build a Hummingbird application for this server. This is internal so
    /// endpoint tests can exercise the router without opening a socket.
    nonisolated func makeApplication() -> Application<RouterResponder<StandaloneRequestContext>> {
        let router = Router(context: StandaloneRequestContext.self)
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
        context: StandaloneRequestContext
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
        } catch StandaloneServerError.modelNotFound(let modelId) {
            return openAIErrorResponse(
                status: .notFound,
                message: StandaloneServerError.modelNotFound(modelId).localizedDescription
            )
        } catch StandaloneServerError.capacityUnavailable(let message) {
            return openAIErrorResponse(
                status: .serviceUnavailable,
                message: message
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
        reserveScheduler(chatRequest.model)

        if chatRequest.stream ?? false {
            let requestID = "standalone-\(UUID().uuidString.prefix(12))"
            let stream = await cached.scheduler.submit(request: chatRequest, requestId: requestID)
            return streamingCompletionResponse(
                stream: stream,
                model: chatRequest.model,
                onFinished: { [scheduler = cached.scheduler] in
                    await scheduler.cancel(requestId: requestID)
                    await self.releaseScheduler(chatRequest.model)
                }
            )
        }

        let requestID = "standalone-\(UUID().uuidString.prefix(12))"
        let stream = await cached.scheduler.submit(request: chatRequest, requestId: requestID)
        let disconnectTask = Task { [closeFuture = context.channelCloseFuture, scheduler = cached.scheduler] in
            do {
                try await closeFuture.get()
                await scheduler.cancel(requestId: requestID)
            } catch {
                // Normal completion cancels this watcher before the channel closes.
            }
        }
        defer { releaseScheduler(chatRequest.model) }
        defer { disconnectTask.cancel() }
        return await withTaskCancellationHandler {
            await nonStreamingCompletion(chatRequest, stream: stream)
        } onCancel: {
            Task { await cached.scheduler.cancel(requestId: requestID) }
        }
    }

    private nonisolated func streamingCompletionResponse(
        stream: AsyncStream<GenerationEvent>,
        model: String,
        onFinished: @escaping @Sendable () async -> Void
    ) -> Response {
        var headers = defaultHeaders(contentType: "text/event-stream")
        headers[.cacheControl] = "no-cache"
        headers[.connection] = "keep-alive"

        let body = ResponseBody { writer in
            do {
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
                        try await writer.write(ByteBuffer(string: Self.sseErrorEvent(message: message)))
                        try await writer.finish(nil)
                        await onFinished()
                        return
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
                await onFinished()
            } catch {
                await onFinished()
                throw error
            }
        }

        return Response(status: .ok, headers: headers, body: body)
    }

    static func sseErrorEvent(message: String) -> String {
        let response = OpenAIErrorResponse(error: .init(message: message, type: "server_error"))
        let data = (try? JSONEncoder().encode(response)) ?? Data(#"{"error":{"message":"Generation failed","type":"server_error"}}"#.utf8)
        let json = String(data: data, encoding: .utf8) ?? #"{"error":{"message":"Generation failed","type":"server_error"}}"#
        return "event: error\ndata: \(json)\n\n"
    }

    private func nonStreamingCompletion(_ chatRequest: ChatCompletionRequest, stream: AsyncStream<GenerationEvent>) async -> Response {
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
                return openAIErrorResponse(status: Self.schedulerErrorStatus(for: message), message: message)
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
