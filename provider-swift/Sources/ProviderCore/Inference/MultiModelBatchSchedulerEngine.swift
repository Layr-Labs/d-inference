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

    public init(
        registryProvider: @escaping @Sendable () async -> Registry,
        ensureLoaded: @escaping @Sendable (String) async throws -> Void = { _ in },
        reserveModel: @escaping @Sendable (String) async -> Void = { _ in },
        releaseModel: @escaping @Sendable (String) async -> Void = { _ in },
        defaultMaxTokens: Int = 4096
    ) {
        self.registryProvider = registryProvider
        self.ensureLoaded = ensureLoaded
        self.reserveModel = reserveModel
        self.releaseModel = releaseModel
        self.defaultMaxTokens = defaultMaxTokens
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
        defaultMaxTokens: Int = 4096
    ) {
        self.acquire = acquire
        self.tokenizerProvider = tokenizerProvider
        self.availableModelsOverride = availableModels
        self.registryProvider = nil
        self.ensureLoaded = { _ in }
        self.reserveModel = { _ in }
        self.releaseModel = { _ in }
        self.defaultMaxTokens = defaultMaxTokens
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
        let releaseBox: OneShotRelease
        let modelId = request.model
        if let acquire {
            let acquired = try await acquire(modelId)
            scheduler = acquired.scheduler
            releaseBox = acquired.releaseToken
        } else {
            try await ensureLoaded(modelId)
            let registry = await (registryProvider?() ?? [:])
            guard let entry = registry[modelId] else {
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
            }
            scheduler = entry.scheduler
            await reserveModel(modelId)
            releaseBox = OneShotRelease(release: releaseModel, modelId: modelId)
        }
        let ourRequest = Self.translate(
            openAIRequest: request,
            defaultMaxTokens: defaultMaxTokens
        )
        let requestId = "req-\(UUID().uuidString.prefix(12))"
        let upstream = await scheduler.submit(
            request: ourRequest,
            requestId: requestId
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                var promptTokens = 0
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
                            continuation.yield(.content(text))
                        }
                    case .info(let p, let c, _):
                        promptTokens = p
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

                let now = Date()
                let promptTime = (firstTokenAt ?? now).timeIntervalSince(startedAt)
                let generateTime = (lastTokenAt ?? now)
                    .timeIntervalSince(firstTokenAt ?? startedAt)
                continuation.yield(
                    .info(
                        ServerGenerationInfo(
                            promptTokens: promptTokens,
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
        let tokens = try tokenizer.inner.applyChatTemplate(
            messages: messages,
            tools: tools,
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
