// Copyright © 2026 Eigen Labs.
//
// Bridge between `MLXLMServer.MLXServerEngine` (a single-engine contract)
// and Darkbloom's multi-model `BatchScheduler` registry. The provider
// loads N models concurrently, one `BatchScheduler` per model, and
// dispatches each incoming OpenAI request by `request.model` to the
// matching scheduler.
//
// The upstream library ships with `MLXBatchedEngineServerEngine`, but
// that type owns exactly one `BatchedEngine` and is intended for the
// single-model `mlx-server` executable. Our provider needs the LRU /
// idle / reservation policy that lives in `StandaloneServer` and
// `ProviderLoop`, so we keep the registry on this side and only expose
// the `MLXServerEngine` shape upstream wants.
//
// Concurrency model: the engine is a value-type `struct` that holds an
// immutable closure (`registryProvider`). All mutable state lives in
// the actor-isolated schedulers themselves, so `Sendable` is trivially
// satisfied.
//
// Companion files:
//   - `MultiModelBatchSchedulerEngine+Registry.swift`
//     defines the nested `ModelRegistryEntry` / `AcquiredModel` types
//     and the top-level `OneShotRelease` actor.
//   - `MultiModelBatchSchedulerEngine+Translation.swift`
//     houses `translate(openAIRequest:)` and the `templateMessageDict`
//     helper used by `applyTemplate`.
//   - `MultiModelBatchSchedulerEngineError.swift`
//     owns the typed error surface and the scheduler-message parser.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Bridges `MLXServerEngine` to Darkbloom's multi-model `BatchScheduler`
/// registry. One instance per process; dispatches each request to the
/// scheduler that owns the requested model.
///
/// The constructor takes a `registryProvider` closure rather than a
/// snapshot dictionary because the LRU may load/evict models between
/// requests. The closure is invoked at every routing decision.
public struct MultiModelBatchSchedulerEngine: MLXServerEngine, Sendable {
    /// Atomic acquire closure. When set, `streamChatCompletion` calls
    /// this single closure instead of the three-closure
    /// (`ensureLoaded`/`registryProvider`/`reserveModel`) dance. The
    /// closure must guarantee that, on return, the model is loaded and
    /// pinned by a non-zero reservation count.
    private let acquire: (@Sendable (String) async throws -> AcquiredModel)?
    /// Tokenizer lookup for `/tokenize`, `/detokenize`,
    /// `/apply-template`. When `acquire` is in use, this is the only
    /// way to find a tokenizer for the utility endpoints (since
    /// `registryProvider` is nil in that mode).
    private let tokenizerProvider: (@Sendable (String?) async throws -> TokenizerHandle)?
    /// Listing closure used by `availableModels()` when the engine was
    /// constructed via the atomic-`acquire` init. Returns the set of
    /// model IDs that should appear in `/v1/models`.
    ///
    /// P2 #3: this closure is expected to return the ADVERTISED model
    /// catalog (the set the operator configured the provider to serve),
    /// not the currently-loaded subset. `/v1/models` is a discovery
    /// endpoint — clients call it before their first request to pick
    /// valid model IDs, so an empty list at startup (when nothing is
    /// resident yet) would confuse them. Capacity / "which models are
    /// warm right now" is reported separately via the backend
    /// capacity payload.
    private let availableModelsOverride: (@Sendable () async -> [String])?

    private let registryProvider: (@Sendable () async -> Registry)?
    private let ensureLoaded: @Sendable (String) async throws -> Void
    private let reserveModel: @Sendable (String) async -> Void
    private let releaseModel: @Sendable (String) async -> Void
    private let defaultMaxTokens: Int

    /// OpenAI `reasoning_effort` for this request (`low`/`medium`/`high`
    /// for gpt-oss; model-specific otherwise). Injected verbatim into the
    /// chat template's render context under the `reasoning_effort` key so
    /// templates that read it (gpt-oss / Harmony) emit the matching
    /// `Reasoning: <effort>` system directive. `nil` leaves the template
    /// at its built-in default. We do not validate the value here — the
    /// allowed set is model-specific and lives in each model's Jinja
    /// template, so passing through is the format-agnostic choice.
    private let reasoningEffort: String?
    /// Per-tenant prefix-cache scope (`SHA256(prompt_cache_key)`/`user`, ""
    /// ⇒ unscoped). Threaded into `submitTokenized` so the checkpoint cache is
    /// partitioned per consumer (closes the TB-007 cross-tenant channel).
    private let cacheScope: String

    public init(
        registryProvider: @escaping @Sendable () async -> Registry,
        ensureLoaded: @escaping @Sendable (String) async throws -> Void = { _ in },
        reserveModel: @escaping @Sendable (String) async -> Void = { _ in },
        releaseModel: @escaping @Sendable (String) async -> Void = { _ in },
        defaultMaxTokens: Int = 4096,
        reasoningEffort: String? = nil,
        cacheScope: String = ""
    ) {
        self.registryProvider = registryProvider
        self.ensureLoaded = ensureLoaded
        self.reserveModel = reserveModel
        self.releaseModel = releaseModel
        self.defaultMaxTokens = defaultMaxTokens
        self.reasoningEffort = reasoningEffort
        self.cacheScope = cacheScope
        self.acquire = nil
        self.tokenizerProvider = nil
        self.availableModelsOverride = nil
    }

    /// I1: atomic-acquire init. Use this when the backing store can
    /// guarantee that `ensureLoaded` + `lookup` + `reserve` run inside
    /// a single critical section so a concurrent eviction cannot pick
    /// the just-loaded model in between the three calls.
    ///
    /// `acquire(modelId:)` MUST return with the model loaded AND
    /// pinned (release is via the returned `OneShotRelease`).
    /// `tokenizerProvider(modelId:)` is used for the token-utility
    /// endpoints; pass `nil` for `modelId` when the request did not
    /// name one and let the implementation pick any resident model.
    /// `availableModels()` MUST return the advertised catalog so the
    /// `/v1/models` discovery endpoint sees the full set (P2 #3).
    public init(
        acquire: @escaping @Sendable (String) async throws -> AcquiredModel,
        tokenizerProvider: @escaping @Sendable (String?) async throws -> TokenizerHandle,
        availableModels: @escaping @Sendable () async -> [String],
        defaultMaxTokens: Int = 4096,
        cacheScope: String = ""
    ) {
        self.acquire = acquire
        self.tokenizerProvider = tokenizerProvider
        self.availableModelsOverride = availableModels
        self.registryProvider = nil
        self.ensureLoaded = { _ in }
        self.reserveModel = { _ in }
        self.releaseModel = { _ in }
        self.defaultMaxTokens = defaultMaxTokens
        self.reasoningEffort = nil
        // Fixed per-server scope for the standalone (--local) path, which can't
        // carry a per-request prompt_cache_key through the upstream router. ""
        // ⇒ unscoped (default). Set via DARKBLOOM_PREFIX_CACHE_SCOPE; used to
        // exercise/validate cross-tenant isolation on a single box.
        self.cacheScope = cacheScope
    }

    // MARK: - MLXServerEngine

    public func availableModels() async throws -> [MLXServerModel] {
        if let override = availableModelsOverride {
            return await override().sorted().map { MLXServerModel(id: $0) }
        }
        let registry = await (registryProvider?() ?? [:])
        return registry.keys.sorted().map { MLXServerModel(id: $0) }
    }

    public func streamChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        // I1: prefer the atomic-`acquire` path. The legacy three-closure
        // path is racy across actor hops (ensureLoaded → lookup →
        // reserve) and is retained only for ProviderLoop where
        // `requestToModel[id] = modelId` pins the slot before load and
        // closes the same race at the caller side.
        let scheduler: BatchScheduler
        let tokenizer: TokenizerHandle
        let modelType: String?
        let releaseBox: OneShotRelease
        let container: ModelContainer?
        let isVLM: Bool
        let modelId = request.model
        if let acquire {
            let acquired = try await acquire(modelId)
            scheduler = acquired.scheduler
            tokenizer = acquired.tokenizer
            modelType = acquired.modelType
            releaseBox = acquired.releaseToken
            container = acquired.container
            isVLM = acquired.isVLM
        } else {
            try await ensureLoaded(modelId)
            let registry = await (registryProvider?() ?? [:])
            guard let entry = registry[modelId] else {
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
            }
            scheduler = entry.scheduler
            tokenizer = entry.tokenizer
            modelType = entry.modelType
            await reserveModel(modelId)
            releaseBox = OneShotRelease(release: releaseModel, modelId: modelId)
            container = entry.container
            isVLM = entry.isVLM
        }

        // Multimodal (image/video) requests can't flow through the token-only
        // batched engine. For VLM models, serve them via the container's
        // non-batched prepare/generate vision path.
        if isVLM, let container, VLMRequestInference.hasMedia(request) {
            // Decode + validate inline media SYNCHRONOUSLY, before returning the
            // stream. A MediaError (oversized/malformed/non-`data:` payload) thrown
            // here propagates through this `async throws` to the caller — so both
            // the buffered (non-streaming) and the SSE (streaming) HTTP paths, and
            // the coordinator WebSocket path, surface the correct 4xx instead of a
            // 200 with a truncated/error stream body. (Deferring the decode into
            // the generation task would let the HTTP layer commit a 200 first.)
            // Reserve this vision request's unified memory against the 90% cap
            // BEFORE rasterizing. The vision path bypasses the batched
            // `submitTokenized` reservation, so it commits two kinds of memory the
            // cap would otherwise track only reactively: (1) the media-decode RAM
            // — CIImage rasters + Swift Data pixel buffers, which are NOT MLX
            // arrays and so are invisible to the cap's live MLX counters; (2) the
            // generation KV cache (kvBytesPerToken × maxOutputTokens), which IS
            // MLXArray-backed but grows in a detached decode task with no
            // per-request reservation, so N concurrent media requests can
            // over-commit it against unreserved headroom. Reserving both up front
            // gives the vision path the same preemptive gate the batched path has;
            // if it won't fit we reject with a retryable error instead of OOMing.
            // Released on every exit.
            let mediaReqId = "vlm-\(UUID().uuidString.prefix(12))"
            let projectedBytes = VLMRequestInference.projectedDecodeBytes(request)
            // Full KV-token span the vision cache will hold: prompt text + image/
            // video soft tokens + generated output (clamped to the context). The
            // vision path bypasses the batched KV reservation, so charging only the
            // output tokens would under-count the prompt + vision tokens that also
            // occupy KV.
            let kvTokens = VLMRequestInference.projectedKVTokens(
                request, defaultMaxTokens: defaultMaxTokens,
                contextLength: await scheduler.contextLength())
            let mediaReserved = await scheduler.reserveVisionRequest(
                requestId: mediaReqId, mediaDecodeBytes: projectedBytes,
                kvTokens: kvTokens)
            if !mediaReserved {
                await releaseBox.fire()
                let mib = projectedBytes / (1024 * 1024)
                throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(
                    "insufficient global kv cache headroom for vision request "
                    + "(media decode ~\(mib) MiB + generation KV) — retry after capacity frees")
            }
            do {
                try await VLMRequestInference.validateMedia(request)
            } catch {
                await scheduler.releaseVisionRequest(requestId: mediaReqId)
                await releaseBox.fire()
                throw error
            }
            let vlmStream = VLMRequestInference.stream(
                container: container, request: request, defaultMaxTokens: defaultMaxTokens)
            // Capture the scheduler so the stream task can release the media
            // reservation; `scheduler` is Sendable (an actor reference).
            let mediaReleaseScheduler = scheduler
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await event in vlmStream {
                            if Task.isCancelled { break }
                            continuation.yield(event)
                        }
                        await mediaReleaseScheduler.releaseVisionRequest(requestId: mediaReqId)
                        await releaseBox.fire()
                        continuation.finish()
                    } catch {
                        await mediaReleaseScheduler.releaseVisionRequest(requestId: mediaReqId)
                        await releaseBox.fire()
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                    Task {
                        await mediaReleaseScheduler.releaseVisionRequest(requestId: mediaReqId)
                        await releaseBox.fire()
                    }
                }
            }
        }

        // If we reach here with media still present, the resolved model is NOT
        // a usable VLM (either `!isVLM`, or it is flagged VLM but no container
        // was handed to us, so the vision prepare/generate path is unavailable).
        // The batched text path below silently discards image/video parts, so
        // letting media fall through would answer a vision question from text
        // alone — a wrong, confusing result. Fail closed with a 4xx instead.
        if VLMRequestInference.hasMedia(request) {
            await releaseBox.fire()
            throw MultiModelBatchSchedulerEngineError.mediaUnsupportedByModel(modelId)
        }

        // Tokenize the full OpenAI request (including tools, tool_call_id,
        // reasoning_content, etc.) ourselves rather than going through the
        // lossy `translate()` → `ChatMessage` path that drops tool fields.
        let messages = request.messages.map { $0.templateMessageDict() }
        let toolSpecs = request.tools?.map { $0.toolSpec() }
        // Surface `reasoning_effort` to the Jinja render context. Templates
        // that don't reference the key (most models) ignore the extra
        // variable; gpt-oss / Harmony reads it to emit `Reasoning: <effort>`.
        let additionalContext: [String: any Sendable]?
        if let reasoningEffort {
            additionalContext = ["reasoning_effort": reasoningEffort]
        } else {
            additionalContext = nil
        }
        let promptTokens: [Int]
        do {
            // Strip JSON `null` / `Optional` leaves (NSNull, the
            // private JSONNull from tool-parameter schemas, boxed Optionals)
            // that `Jinja.Value(any:)` cannot represent. Sanitize the copies
            // handed to the template only — `toolSpecs` keeps its raw shape
            // for the tool-call output parser below.
            promptTokens = try tokenizer.inner.applyChatTemplate(
                messages: sanitizeJinjaMessages(messages),
                tools: sanitizeJinjaTools(toolSpecs),
                additionalContext: additionalContext
            )
        } catch {
            await releaseBox.fire()
            throw error
        }

        let maxTokens = request.maxTokens ?? defaultMaxTokens
        let temperature = request.temperature ?? 0.0

        // Resolve tool call format before submitting so a bad
        // `tool_call_parser` value does not leave an orphaned request.
        let toolHandler: BatchedToolStreamHandler?
        if let requestTools = request.tools, !requestTools.isEmpty {
            let format: ToolCallFormat
            do {
                format = try ServerToolParser.resolve(
                    requested: request.toolCallParser,
                    modelType: modelType
                )
            } catch {
                await releaseBox.fire()
                throw error
            }
            toolHandler = BatchedToolStreamHandler(
                format: format,
                tools: toolSpecs
            )
        } else {
            toolHandler = nil
        }

        let requestId = "req-\(UUID().uuidString.prefix(12))"
        let upstream = await scheduler.submitTokenized(
            promptTokens: promptTokens,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: request.topP,
            topK: request.topK,
            requestId: requestId,
            cacheScope: cacheScope
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                var promptTokenCount = 0
                var completionTokens = 0
                var startedAt = Date()
                var firstTokenAt: Date?
                var lastTokenAt: Date?
                var stopReason: String = "stop"
                var failed: String?
                startedAt = Date()

                for await event in upstream {
                    if Task.isCancelled {
                        await scheduler.cancel(requestId: requestId)
                        await releaseBox.fire()
                        continuation.finish()
                        return
                    }
                    switch event {
                    case .chunk(let text):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        lastTokenAt = Date()
                        if !text.isEmpty {
                            if let handler = toolHandler {
                                if let visible = handler.processChunk(text),
                                    !visible.isEmpty
                                {
                                    continuation.yield(.content(visible))
                                }
                            } else {
                                continuation.yield(.content(text))
                            }
                        }
                    case .info(let p, let c, _):
                        promptTokenCount = p
                        completionTokens = c
                    case .error(let message):
                        failed = message
                    }
                }

                if let failed {
                    await releaseBox.fire()
                    // P2 #6: parse the scheduler's structured error
                    // prefix (`token_budget_exhausted: ...`, `... queue
                    // full`, `timed out waiting for capacity`, etc.)
                    // into a typed error so the status mapper can
                    // return 429/503 instead of collapsing every
                    // admission failure into 500.
                    continuation.finish(
                        throwing: MultiModelBatchSchedulerEngineError
                            .fromSchedulerMessage(failed)
                    )
                    return
                }

                // Flush remaining tool calls on successful completion.
                if let handler = toolHandler {
                    for toolCall in handler.finish() {
                        continuation.yield(.toolCall(toolCall))
                    }
                }

                let now = Date()
                let promptTime = (firstTokenAt ?? now).timeIntervalSince(startedAt)
                let generateTime = (lastTokenAt ?? now)
                    .timeIntervalSince(firstTokenAt ?? startedAt)
                continuation.yield(
                    .info(
                        ServerGenerationInfo(
                            promptTokens: promptTokenCount,
                            completionTokens: completionTokens,
                            promptTime: max(0, promptTime),
                            generationTime: max(0, generateTime),
                            stopReason: stopReason
                        )
                    )
                )
                await releaseBox.fire()
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task {
                    await scheduler.cancel(requestId: requestId)
                    await releaseBox.fire()
                }
            }
        }
    }

    public func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse {
        let tokenizer = try await resolveTokenizer(modelId: request.model)
        let tokens = tokenizer.inner.encode(
            text: request.prompt,
            addSpecialTokens: request.addSpecialTokens ?? true
        )
        return TokenizeResponse(tokens: tokens)
    }

    public func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse {
        let tokenizer = try await resolveTokenizer(modelId: request.model)
        let text = tokenizer.inner.decode(
            tokenIds: request.tokens,
            skipSpecialTokens: request.skipSpecialTokens ?? false
        )
        return DetokenizeResponse(text: text)
    }

    public func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse {
        let tokenizer = try await resolveTokenizer(modelId: request.model)
        let messages = request.messages.map { $0.templateMessageDict() }
        let tools = request.tools?.map { $0.toolSpec() }
        // Drop JSON `null` / `Optional` leaves the Jinja bridge
        // can't convert before rendering (mirrors `streamChatCompletion`).
        let tokens = try tokenizer.inner.applyChatTemplate(
            messages: sanitizeJinjaMessages(messages),
            tools: sanitizeJinjaTools(tools),
            additionalContext: nil
        )
        return TokenizeResponse(tokens: tokens)
    }

    // MARK: - Tokenizer resolution

    /// Resolve the tokenizer for a request. If the request specifies a
    /// `model`, prefer that. Otherwise fall back to any resident model
    /// (sorted for determinism). Throws when no model is loaded.
    private func resolveTokenizer(modelId: String?) async throws -> TokenizerHandle {
        if let tokenizerProvider {
            return try await tokenizerProvider(modelId)
        }
        let registry = await (registryProvider?() ?? [:])
        if let modelId, let entry = registry[modelId] {
            return entry.tokenizer
        }
        if let modelId, registry[modelId] == nil {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        if let firstKey = registry.keys.sorted().first,
            let entry = registry[firstKey]
        {
            return entry.tokenizer
        }
        throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
    }
}
