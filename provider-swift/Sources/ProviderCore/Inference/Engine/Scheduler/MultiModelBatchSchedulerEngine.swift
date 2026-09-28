// Copyright © 2026 Eigen Labs.
//
// Bridge between `MLXLMServer.MLXServerEngine` (a single-engine contract)
// and Darkbloom's multi-model EngineV2 slot registry. The provider loads N
// models concurrently, one `EngineV2Bridge` per model, and dispatches each
// incoming OpenAI request by `request.model` to the matching bridge.
//
// The upstream library ships with `MLXBatchedEngineServerEngine`, but
// that type owns exactly one `BatchedEngine` and is intended for the
// single-model `mlx-server` executable. Our provider needs the LRU /
// idle / reservation policy that lives in `StandaloneServer` and
// `ProviderLoop`, so we keep the registry on this side and only expose
// the `MLXServerEngine` shape upstream wants.
//
// Concurrency model: the engine is a value-type `struct` that holds an
// immutable closure (`registryProvider`). Mutable inference state lives in
// actor-isolated EngineV2 bridges, so `Sendable` is trivially satisfied.
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
import ProviderCoreFoundation
import MLXLMCommon
import MLXLMServer
import MLXVLM

/// Bridges `MLXServerEngine` to Darkbloom's multi-model EngineV2 registry.
/// Dispatches each request to the bridge that owns the requested model.
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
    private let tokenizerProvider: (@Sendable (String?) async throws -> TokenizerResolution)?
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
    /// Opt-in per-acquisition host-task ownership. The owner validates the
    /// resolved container/bridge and stores the SAME lease before returning.
    /// Nil preserves the existing non-native path; request spelling is not
    /// authority to choose a native transaction.
    /// Validation may throw BEFORE publication. Create/store/return must be a
    /// nonthrowing, nonsuspending actor segment; an error cannot hide a stored
    /// lease from Scheduler's existing no-work reservation unwind. A missing
    /// known-native owner must throw, never return nil into the legacy path.
    private let nativeConsumerLeaseProvider: (@Sendable (String, ModelRegistryEntry) async throws -> NativeLocalConsumerLease?)?
    private let defaultMaxTokens: Int

    /// OpenAI `reasoning_effort` and Qwen template controls for this request
    /// (`low`/`medium`/`high` for gpt-oss; model-specific otherwise).
    /// GPT-OSS currently maps `high` to `medium` before Harmony rendering to
    /// keep generation inside the upstream request deadline.
    /// Controls are injected into the chat template's render context so
    /// templates that read it (gpt-oss / Harmony) emit the matching
    /// `Reasoning: <effort>` system directive. `nil` leaves the template
    /// at its built-in default. We do not validate the value here — the
    /// allowed set is model-specific and lives in each model's Jinja
    /// template, so passing through is the format-agnostic choice.
    private let templateControls: ChatTemplateControls
    /// Authenticated remote or configured local prefix-cache scope. Maps to
    /// `CBv2Request.cacheSalt` for both cache tiers.
    private let cacheScope: String
    /// Trusted single-key local-application namespace, used only by native
    /// diffusion. Remote requests never fall back to this scope.
    private let nativeLocalCacheScope: String?
    /// False only for remote requests from a legacy/malformed coordinator
    /// that did not provide an authenticated outer cache scope.
    private let cacheEnabled: Bool
    /// Per-request usage-detail signal: the bridge
    /// records the engine's terminal matched/saved token detail here so the
    /// caller's frames loop can splice OpenAI-standard
    /// `prompt_tokens_details.cached_tokens` into the trailing SSE usage
    /// chunk. Same out-of-band pattern as `engineV2Logprobs`.
    private let engineV2Usage: EngineV2RequestUsageSignal?
    /// Per-request logprobs plumbing. Non-nil means the sealed request asked for
    /// logprobs: the v2 translation flips `logprobs`/`top_logprobs` on so
    /// the engine captures them, and the bridge publishes OpenAI-shaped
    /// entries to `engineV2Logprobs.channel` for the caller's SSE frame decorator.
    private let engineV2Logprobs: EngineV2LogprobsPlumbing?
    /// OpenAI `logit_bias`/`seed` decoded out-of-band from the sealed body
    /// (the upstream `OpenAIChatCompletionRequest` models neither — same
    /// pattern as `engineV2Logprobs`/`reasoningEffort`/`cacheScope`).
    /// Overlaid onto the EngineV2 translation so
    /// `EngineV2Translation.samplingParams` sees the real values.
    private let engineV2Sampling: EngineV2SamplingOverrides?
    /// v0.7.5 media-through-v2 seam: the preparer that turns an image/video
    /// request into a `CBv2MultimodalInput` submission plus the sink for the
    /// fallback WARN. nil ⇒ `.production` (the real `EngineV2VisionPrefill`
    /// + `TelemetryClient.shared`); unit tests inject a scripted preparer so
    /// the routing is exercisable without model weights.
    private let engineV2Vision: EngineV2VisionPlumbing?
    /// Coordinator-bound requests may carry schema metadata inserted only
    /// after the coordinator rejects client-forged copies. Direct local HTTP
    /// requests have no such trusted boundary and must reject that metadata.
    private let allowInternalToolSchemaMetadata: Bool
    /// Absolute provider-local deadline derived once when the coordinator frame
    /// was received. Nil for local HTTP and legacy coordinator requests.
    private let firstContentDeadline: FirstContentDeadline?
    /// Profiler accumulator for the coordinator request this engine view
    /// serves (prompt-prep / tool-constraint / vision-prep stamps; handed on
    /// to the bridge). Nil for local HTTP and tests.
    private let profile: RequestProfileBuilder?

    #if DEBUG
    enum NativeForwardingTestPoint: Sendable {
        case beforeForward
        case receivedEvent(GenerationEvent)
    }
    /// Host hold only, inside the actual owned forwarder. Never supplies an
    /// event/result or native completion. Nil adds no suspension point.
    var _testNativeForwardingHold: (@Sendable (NativeForwardingTestPoint) async -> Void)? = nil
    #endif

    public init(
        registryProvider: @escaping @Sendable () async -> Registry,
        ensureLoaded: @escaping @Sendable (String) async throws -> Void = { _ in },
        reserveModel: @escaping @Sendable (String) async -> Void = { _ in },
        releaseModel: @escaping @Sendable (String) async -> Void = { _ in },
        defaultMaxTokens: Int = 4096,
        templateControls: ChatTemplateControls = .init(),
        cacheScope: String = "",
        cacheEnabled: Bool = true,
        engineV2Logprobs: EngineV2LogprobsPlumbing? = nil,
        engineV2Sampling: EngineV2SamplingOverrides? = nil,
        engineV2Vision: EngineV2VisionPlumbing? = nil,
        engineV2Usage: EngineV2RequestUsageSignal? = nil,
        firstContentDeadline: FirstContentDeadline? = nil,
        profile: RequestProfileBuilder? = nil,
        nativeConsumerLeaseProvider: (@Sendable (String, ModelRegistryEntry) async throws -> NativeLocalConsumerLease?)? = nil
    ) {
        self.profile = profile
        self.registryProvider = registryProvider
        self.ensureLoaded = ensureLoaded
        self.reserveModel = reserveModel
        self.releaseModel = releaseModel
        self.nativeConsumerLeaseProvider = nativeConsumerLeaseProvider
        self.defaultMaxTokens = defaultMaxTokens
        self.templateControls = templateControls
        self.cacheScope = cacheScope
        self.nativeLocalCacheScope = nil
        self.cacheEnabled = cacheEnabled
        self.engineV2Logprobs = engineV2Logprobs
        self.engineV2Sampling = engineV2Sampling
        self.engineV2Vision = engineV2Vision
        self.engineV2Usage = engineV2Usage
        self.allowInternalToolSchemaMetadata = true
        self.firstContentDeadline = firstContentDeadline
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
        tokenizerProvider: @escaping @Sendable (String?) async throws -> TokenizerResolution,
        availableModels: @escaping @Sendable () async -> [String],
        defaultMaxTokens: Int = 4096,
        templateControls: ChatTemplateControls = .init(),
        nativeLocalCacheScope: String? = nil
    ) {
        self.acquire = acquire
        self.tokenizerProvider = tokenizerProvider
        self.availableModelsOverride = availableModels
        self.registryProvider = nil
        self.ensureLoaded = { _ in }
        self.reserveModel = { _ in }
        self.releaseModel = { _ in }
        self.nativeConsumerLeaseProvider = nil
        self.defaultMaxTokens = defaultMaxTokens
        self.templateControls = templateControls
        self.cacheScope = ""
        self.nativeLocalCacheScope = nativeLocalCacheScope
        self.cacheEnabled = true
        // The --local path serves SSE frames inside the upstream router, so
        // there is no provider seam to decorate frames with logprobs on this
        // init (same visible behavior as the legacy engine: none emitted).
        self.engineV2Logprobs = nil
        // Same reason: the --local path decodes the raw body inside the
        // upstream router, so `logit_bias`/`seed` cannot be recovered here
        // (the upstream request shape omits them — see the KNOWN DEVIATION on
        // `translate(...)`).
        self.engineV2Sampling = nil
        // nil ⇒ `.production` at the routing site — the --local path gets
        // the same vision-through-v2 behavior as the coordinator path.
        self.engineV2Vision = nil
        // The --local path serves SSE frames inside the upstream router
        // (no provider frame decorator), so there is nowhere to splice
        // cached_tokens — same scoping as `engineV2Logprobs`.
        self.engineV2Usage = nil
        self.allowInternalToolSchemaMetadata = false
        self.firstContentDeadline = nil
        self.profile = nil
    }

    // MARK: - MLXServerEngine

    public func availableModels() async throws -> [MLXServerModel] {
        if let override = availableModelsOverride {
            return await override().sorted().map { id in
                MLXServerModel(
                    id: id, contextLength: Qwen4SupportPolicy.contextLimit(modelID: id))
            }
        }
        let registry = await (registryProvider?() ?? [:])
        return registry.keys.sorted().map { id in
            let entry = registry[id]
            return MLXServerModel(
                id: id,
                contextLength: entry?.engineV2Bridge?.advertisedContextTokens
                    ?? Qwen4SupportPolicy.contextLimit(
                        modelID: id, modelType: entry?.modelType))
        }
    }

    public func streamChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        let templateControls = self.templateControls.resolvingPromptDate()
        // A local HTTP engine may be shared by concurrent Chat/Responses calls.
        // The fallback usage channel belongs to this request, never to the engine.
        let requestUsage = engineV2Usage ?? EngineV2RequestUsageSignal()
        try checkFirstContentDeadline()
        // Only invalid native-control evidence warrants this extra read-only
        // resident lookup. It must never load/provision, infer type from the
        // requested name, or convert cancellation into a cold-model fallback.
        if templateControls.rawMiMoControls.invalid {
            let knownType: String?
            if let tokenizerProvider {
                do { knownType = try await tokenizerProvider(request.model).modelType }
                catch MultiModelBatchSchedulerEngineError.modelNotLoaded(_) { knownType = nil }
                catch MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization { knownType = nil }
            } else {
                let resident = await (registryProvider?() ?? [:])
                knownType = resident[request.model]?.modelType
            }
            try checkFirstContentDeadline()
            try ProviderPromptContractPipeline.validateNativeControls(templateControls, modelType: knownType)
        }

        // I1: prefer the atomic-`acquire` path. The legacy three-closure
        // path is racy across actor hops (ensureLoaded → lookup →
        // reserve) and is retained only for ProviderLoop where
        // `requestToModel[id] = modelId` pins the slot before load and
        // closes the same race at the caller side.
        return try await prepareAcquiredCompletion(
            request: request, templateControls: templateControls, requestUsage: requestUsage,
            acquired: try await acquireForCompletion(modelId: request.model))
    }

    /// Keep registry/acquisition snapshots out of the parent preparation frame.
    /// A native lease starts with an armed handoff even across the async owner
    /// factory. Bind it before observing cancellation, so stop cannot mistake
    /// the factory-return/bind interval for completed host work.
    private func acquireForCompletion(modelId: String) async throws -> AcquiredModel {
        if let acquire { return try await acquire(modelId) }
        try await ensureLoaded(modelId)
        try checkFirstContentDeadline()
        let registry = await (registryProvider?() ?? [:])
        try checkFirstContentDeadline()
        guard let entry = registry[modelId] else {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        await reserveModel(modelId)
        let lease: NativeLocalConsumerLease?
        do {
            lease = try await nativeConsumerLeaseProvider?(modelId, entry)
        } catch {
            // No release token exists yet. The provider must cold-dispose any
            // stored unreturned lease; this is the original no-work reserve
            // unwind, not a second lease or native completion authority.
            await releaseModel(modelId)
            throw error
        }
        return AcquiredModel(tokenizer: entry.tokenizer,
            releaseToken: OneShotRelease(release: releaseModel, modelId: modelId,
                                         nativeConsumerLease: lease),
            modelType: entry.modelType, container: entry.container,
            diffusionContainer: entry.diffusionContainer, isVLM: entry.isVLM,
            engineV2Bridge: entry.engineV2Bridge, visionGate: entry.visionGate)
    }

    private func prepareAcquiredCompletion(
        request: OpenAIChatCompletionRequest, templateControls: ChatTemplateControls,
        requestUsage: EngineV2RequestUsageSignal, acquired: consuming AcquiredModel
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        guard let lease = acquired.nativeConsumerLease else {
            return try await prepareCompletion(request: request, templateControls: templateControls,
                requestUsage: requestUsage, acquired: consume acquired)
        }
        let releaseBox = acquired.releaseToken
        // A second token cannot adopt, abandon, fire or cancel a first token's
        // live lease. Fail before any preparation or model consumer starts.
        guard releaseBox.nativeBindingAccepted else { throw NativeLocalConsumerOwnershipError.invalidBinding }
        let payload = NativeLocalAcquisitionPayload(consume acquired)
        return try await withTaskCancellationHandler {
            let task: Task<AsyncThrowingStream<MLXServerGenerationEvent, Error>, Error>
            do {
                task = try lease.startPreparation {
                    guard let acquired = payload.take() else { throw NativeLocalConsumerOwnershipError.invalidBinding }
                    do {
                        return try await prepareCompletion(request: request, templateControls: templateControls,
                            requestUsage: requestUsage, acquired: consume acquired)
                    } catch {
                        await releaseBox.fire()
                        throw error
                    }
                }
            } catch {
                // Registration lost to close; no task has acquired the payload.
                // Dispose aliases BEFORE resolving the original armed handoff.
                payload.discard()
                if let refusal = error as? NativeLocalConsumerOwnershipError, refusal == .closed {
                    try lease.discardUnstartedPreparation()
                    await releaseBox.fire()
                }
                try Task.checkCancellation()
                throw error
            }
            return try await task.value
        } onCancel: {
            lease.closeAndCancel()
        }
    }

    private func prepareCompletion(
        request: OpenAIChatCompletionRequest, templateControls: ChatTemplateControls,
        requestUsage: EngineV2RequestUsageSignal, acquired: consuming AcquiredModel
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        let tokenizer = acquired.tokenizer
        let modelType = acquired.modelType
        let releaseBox = acquired.releaseToken
        let container = acquired.container
        let diffusionContainer = acquired.diffusionContainer
        let isVLM = acquired.isVLM
        let engineV2Bridge = acquired.engineV2Bridge
        let visionGate = acquired.visionGate
        let modelId = request.model
        try await checkFirstContentDeadline(releasing: releaseBox)

        let requestCacheScope = diffusionContainer != nil && cacheScope.isEmpty
            ? (nativeLocalCacheScope ?? cacheScope) : cacheScope
        let prepared: ToolChoicePromptPolicy.Prepared
        let nativeMiMoThinkingEnabled: Bool
        do {
            try checkFirstContentDeadline()
            try ProviderPromptContractPipeline.validateNativeControls(templateControls, modelType: modelType)
            guard !MediaIngest.hasAudio(request) || modelType == "mimo_v2" else {
                throw MultiModelBatchSchedulerEngineError.multimodalRejected("encoded audio requires a native audio profile")
            }
            if modelType == "mimo_v2" {
                try MiMoV26TemplateFix.validateRequest(request)
                nativeMiMoThinkingEnabled = try MiMoV26TemplateFix.effectiveThinkingEnabled(
                    request: request, controls: templateControls)
            } else { nativeMiMoThinkingEnabled = true }
            try DiffusionGemmaReasoningControl.validate(
                request: request, controls: templateControls, modelType: modelType)
            prepared = try ToolChoicePromptPolicy.prepare(
                request,
                modelType: modelType,
                allowInternalSchemaMetadata: allowInternalToolSchemaMetadata)
            try checkFirstContentDeadline()
        } catch {
            await releaseBox.fire()
            throw error
        }
        emitToolConstraintTelemetry(
            operation: "tool_constraint_mode",
            reason: prepared.mode.telemetryValue)

        let toolHandler: BatchedToolStreamHandler?
        var nativeMediaTools = false
        do {
            try checkFirstContentDeadline()
            if let diffusionContainer, MediaIngest.hasMedia(request) {
                nativeMediaTools = await diffusionContainer.perform { $0.processor != nil }
            } else if isVLM, let container, MediaIngest.hasMedia(request) {
                nativeMediaTools = await container.perform { ctx in
                    ctx.model is MLXVLM.Qwen4Exp || ctx.model is MLXVLM.PrismHadamardQwen35
                }
            }
            if !MediaIngest.hasMedia(request) || nativeMediaTools || modelType == "mimo_v2" {
                toolHandler = try ToolStreamPreparation.makeHandler(
                    request: request, prepared: prepared, modelType: modelType)
            } else {
                toolHandler = nil
            }
            try checkFirstContentDeadline()
        } catch {
            await releaseBox.fire()
            throw error
        }

        // Multimodal (image/video) requests can't flow through the token-only
        // batched TEXT paths. For VLM models they are handled here: on a
        // EngineV2 with precomputed vision-tower embeddings (v0.7.5, below).
        // Production slots always have a bridge; the bridge-less branch is
        // retained only for injected/test registry entries.
        //
        // ORDERING CONTRACT: this media check MUST stay above the text bridge.
        // A VLM slot's bridge owns the exact same text tower used by direct VLM
        // forwards, but media must first run the wrapper's vision tower and
        // splice its embeddings; token-only preparation would discard media.
        if modelType == "mimo_v2", MediaIngest.hasMedia(request) {
            do {
                return try await prepareNativeMiMoMedia(request:request,templateControls:templateControls,
                    requestUsage:requestUsage,prepared:prepared,toolHandler:toolHandler,
                    thinkingEnabled:nativeMiMoThinkingEnabled,acquired:consume acquired)
            } catch {
                await releaseBox.fire()
                throw MiMoV26EncodedMediaIngress.outwardFailure(error)
            }
        }
        if MediaIngest.hasMedia(request), (isVLM && container != nil) || diffusionContainer != nil {
            try await checkFirstContentDeadline(releasing: releaseBox)
            var visionRequest = request
            visionRequest.tools = prepared.tools
            visionRequest.messages = ChatTemplateFixes.normalizeMessages(
                prepared.messages,
                context: ChatTemplateFixContext(
                    modelId: request.model, modelType: modelType))
            try await checkFirstContentDeadline(releasing: releaseBox)
            // `.auto` constrains nothing and `.none` hides the tools outright
            // (post-generation validation rejects any emitted call), so both
            // ride the media path unchanged. Bonsai's native parser withholds
            // and validates required/named frames exactly as on its text path;
            // other families retain their existing grammar-dependent refusal.
            guard prepared.mode == .auto || prepared.mode == .none
                || ToolChoiceEnforcementPolicy.supportsForcedMedia(
                    context: .init(modelId: modelId, modelType: modelType),
                    nativeWrapperLoaded: nativeMediaTools)
            else {
                await releaseBox.fire()
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "inference-enforced tool_choice is not supported for multimodal requests")
            }
            // Media is decoded exactly once by EngineV2VisionPrefill.prepare
            // below, still synchronously inside this async-throws call before
            // any stream is returned. Its MediaError therefore keeps the same
            // clean pre-header 4xx contract without paying a second AVFoundation
            // decode on the first-content critical path.
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
            let projectedBytes = MediaIngest.projectedDecodeBytes(visionRequest)
            // Scheduler-free vision gate (v0.7.5): the per-slot
            // `VisionMemoryGate` carries the slot's fp16 KV rate + context
            // window and reserves against the same shared budget the old
            // scheduler surface did. A nil gate (standalone/unit tests
            // without a shared ledger) degrades to "always proceed" —
            // identical to the old nil-kvBudget scheduler behavior.
            let mediaGate = visionGate
                ?? VisionMemoryGate(kvBudget: nil, fp16KVBytesPerToken: 0, contextLength: 0)
            // Full KV-token span the vision cache will hold: prompt text + image/
            // video soft tokens + generated output (clamped to the context). The
            // vision path bypasses the batched KV reservation, so charging only the
            // output tokens would under-count the prompt + vision tokens that also
            // occupy KV.
            let kvTokens = MediaIngest.projectedKVTokens(
                visionRequest, defaultMaxTokens: defaultMaxTokens,
                contextLength: mediaGate.contextLength)
            let mediaReserved = await mediaGate.reserve(
                requestId: mediaReqId, mediaDecodeBytes: projectedBytes,
                kvTokens: kvTokens)
            do {
                try checkFirstContentDeadline()
            } catch {
                if mediaReserved {
                    await mediaGate.release(requestId: mediaReqId)
                }
                await releaseBox.fire()
                throw error
            }
            if !mediaReserved {
                await releaseBox.fire()
                let mib = projectedBytes / (1024 * 1024)
                throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(
                    "insufficient global kv cache headroom for vision request "
                    + "(media decode ~\(mib) MiB + generation KV) — retry after capacity frees")
            }
            // MEDIA → ENGINE V2: image, video, and mixed requests use the
            // wrapper's vision tower/projector, then prefill its same owned
            // text tower through CBv2. Per-image / per-video-frame embeddings
            // ride `CBv2Request.multimodal` and are spliced at placeholder
            // spans with bidirectional masks and chunk snapping.
            //
            // FAIL LOUD (v0.7.5): a construction failure is REFUSED — ERROR
            // `engine_v2_vision_refusal` telemetry (tagged with the media
            // kind) + a retriable 503 (`.requestRejected`) so the
            // coordinator's pre-content failover reroutes invisibly. The
            // legacy wrapper path below is NOT reachable for media on a
            // v2-bridged slot anymore (the pre-release silent fallback is gone).
            // Four throws are NOT refusals: `CancellationError` (the
            // caller went away — propagate, 499), `MediaError`
            // (deterministic input fault — keeps its 4xx mapping), and
            // `noProcessedMedia` (media on non-user roles only — a
            // deterministic 400; rerouting would fail identically
            // everywhere), plus `unsupportedMedia` (the loaded family rejects
            // this shape on every equivalent provider).
            if let bridge = engineV2Bridge {
                let plumbing = engineV2Vision ?? .production
                do {
                    try checkFirstContentDeadline()
                    profile?.mark(.promptPrepStart)
                    let visionPrepStart = SuspendingClock.now
                    let visionPrepared: EngineV2VisionPrefill.PreparedSubmission
                    if let diffusionContainer {
                        visionPrepared = try await EngineV2VisionPrefill.prepareDiffusion(container: diffusionContainer,
                            request: visionRequest, templateControls: templateControls)
                    } else if let container {
                        visionPrepared = try await plumbing.prepare(container, visionRequest, templateControls)
                    } else {
                        throw EngineV2VisionPrefillError.unsupportedVLM("missing typed model owner")
                    }
                    if let profile {
                        // Media prompt prep = decode + vision tower; one lock.
                        let visionPrepUs = RequestProfileBuilder.microseconds(
                            SuspendingClock.now - visionPrepStart)
                        let visionPromptTokens = Int64(visionPrepared.promptTokens.count)
                        profile.update { f, now in
                            f.mark(.promptPrepEnd, offsetUs: now)
                            f.set(.promptTokens, visionPromptTokens)
                            f.add(.visionPrep, us: visionPrepUs)
                        }
                    }
                    // MLX vision evaluation mutates container/Metal state and is
                    // not safely cancellable. Reject immediately after it returns.
                    try checkFirstContentDeadline()
                    let visionRequestId = "req-\(UUID().uuidString.prefix(12))"
                    // Hash the evaluated media while its reservation still
                    // owns the preparation peak. Bind cache lookup to actual
                    // native features/positions, never a filename or URL.
                    let mediaPrefixIdentity: CBv2HybridPrefixIdentity?
                    if diffusionContainer != nil, cacheEnabled {
                        mediaPrefixIdentity = try visionPrepared.hybridPrefixIdentity()
                    } else if nativeMediaTools, Qwen4SupportPolicy.isOwnedModelID(modelId), cacheEnabled,
                       await bridge.ssdHybridCheckpointStore != nil {
                        mediaPrefixIdentity = try visionPrepared.hybridPrefixIdentity(
                            canonicalQwen4TextTail: true)
                    } else {
                        mediaPrefixIdentity = nil
                    }
                    try checkFirstContentDeadline()
                    // Hand off memory accounting to the bridge BEFORE
                    // submit: the decode-phase peak this vision reservation
                    // covered (CIImage rasters, tower activations) is
                    // behind us — the embeddings were eval'ed inside
                    // `prepare` — and `submitTokenized`'s shared-budget
                    // gate re-reserves the SAME KV span (prompt incl. soft
                    // tokens + max_tokens at the fp16 rate) against the
                    // SAME `GlobalKVCacheBudget`. Holding both across the
                    // submit would double-charge that span, spuriously
                    // rejecting near-headroom requests that fit under a
                    // single reservation (`token_budget_exhausted`).
                    // `release` is idempotent, so the catch-arms below (and
                    // the post-throw paths they share with `prepare`
                    // failures) stay correct as written.
                    await mediaGate.release(requestId: mediaReqId)
                    try checkFirstContentDeadline()
                    // Qualified native media shares text's request-owned
                    // parser. Other VLMs retain their legacy media behavior.
                    let upstream = try await bridge.submitTokenized(
                        promptTokens: visionPrepared.promptTokens,
                        request: Self.translate(
                            openAIRequest: visionRequest, defaultMaxTokens: defaultMaxTokens,
                            logprobs: engineV2Logprobs != nil ? true : nil,
                            topLogprobs: engineV2Logprobs?.topLogprobs,
                            logitBias: engineV2Sampling?.logitBias,
                            seed: engineV2Sampling?.seed),
                        requestId: visionRequestId,
                        cacheScope: requestCacheScope,
                        cacheEnabled: cacheEnabled,
                        logprobsChannel: engineV2Logprobs?.channel,
                        // Media requests are prefix-cache-excluded engine-
                        // side (hit tokens always 0), but the signal still
                        // reaches its terminal so the frames loop never
                        // waits on an unset box.
                        usageSignal: requestUsage,
                        multimodal: visionPrepared.multimodalInput(),
                        hybridPrefixIdentity: mediaPrefixIdentity,
                        mediaKind: visionPrepared.mediaKind,
                        firstContentDeadline: firstContentDeadline,
                        profile: profile
                    )
                    do {
                        try checkFirstContentDeadline()
                    } catch {
                        await bridge.cancel(requestId: visionRequestId)
                        throw error
                    }
                    // Initialize the think parser from the rendered media
                    // prompt: reasoning for an open block, content for a
                    // pre-closed block (thinking-disabled media).
                    try checkFirstContentDeadline()
                    let reasoningPrefix = ReasoningPromptProbe.streamingPrefix(
                        reasoningParser: visionRequest.reasoningParser,
                        stream: visionRequest.stream,
                        promptTokens: visionPrepared.promptTokens,
                        decodeTail: { tokenizer.inner.decode(tokenIds: $0, skipSpecialTokens: false) }
                    )
                    try checkFirstContentDeadline()
                    return try await makeDeadlineCheckedEventStream(
                        upstream: upstream,
                        cancelUpstream: { await bridge.cancel(requestId: visionRequestId) },
                        toolHandler: toolHandler,
                        prepared: prepared,
                        releaseBox: releaseBox,
                        usageSignal: requestUsage,
                        reasoningPrefix: reasoningPrefix,
                        nativeReasoningPrefix: nativeMediaTools
                            ? (ReasoningPromptProbe.streamingPrefix(forPromptTail:
                                tokenizer.inner.decode(tokenIds: Array(visionPrepared.promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                                                       skipSpecialTokens: false)) ?? "<think></think>") : nil,
                        preserveInnerReasoningSpans: ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(
                            .init(modelId: modelId, modelType: modelType)),
                        nativeGemmaChannels: diffusionContainer != nil && modelType == "diffusion_gemma",
                        nativeGemmaReasoningEnabled: modelType != "diffusion_gemma"
                            || DiffusionGemmaReasoningControl.enabled(for: visionRequest, controls: templateControls)
                    )
                } catch {
                    // Every failed media construction releases the same reservations
                    // before classifying the failure or publishing refusal telemetry.
                    await mediaGate.release(requestId: mediaReqId)
                    await releaseBox.fire()
                    if let failure = error as? PreContentDeadlineFailure { throw failure }
                    if error is CancellationError { throw CancellationError() }
                    if let mediaError = error as? MediaIngest.MediaError { throw mediaError }
                    if let visionError = error as? EngineV2VisionPrefillError {
                        switch visionError {
                        case .noProcessedMedia:
                            throw MultiModelBatchSchedulerEngineError.multimodalRejected(
                                "multimodal_rejected: media parts must be attached to user "
                                    + "messages; none of this request's media was consumable")
                        case .unsupportedMedia(let detail):
                            throw MultiModelBatchSchedulerEngineError.multimodalRejected(
                                "multimodal_rejected: \(detail)")
                        default:
                            break
                        }
                    }
                    // Construction failures are retryable; deterministic input faults,
                    // cancellation and deadlines above keep their original mappings.
                    let mediaKind = EngineV2VisionPrefill.mediaKind(of: visionRequest)
                    plumbing.emitTelemetry(
                        EngineV2VisionPrefill.refusalTelemetryEvent(
                            modelId: modelId, mediaKind: mediaKind, error: error))
                    throw MultiModelBatchSchedulerEngineError.requestRejected(
                        "engine_v2 media prefill construction failed "
                            + "(media=\(mediaKind.rawValue)): "
                            + EngineV2VisionPrefill.refusalDetail(for: error)
                            + " — request not started; retry on another provider")
                }
            }

            // ONE ENGINE (v0.7.5): media can only serve through a v2 bridge.
            // A media request reaching a slot with NO bridge is a wiring bug
            // — the same fail-loud backstop as the text path's, never a
            // silent legacy serve (the legacy wrapper stream died with the
            // legacy engine).
            await mediaGate.release(requestId: mediaReqId)
            await releaseBox.fire()
            throw MultiModelBatchSchedulerEngineError.generationFailed(
                "internal error: model '\(modelId)' has no serving engine for media (no v2 bridge)")
        }

        // If we reach here with media still present, the resolved model is NOT
        // a usable VLM (either `!isVLM`, or it is flagged VLM but no container
        // was handed to us, so the vision prepare/generate path is unavailable).
        // The batched text path below silently discards image/video parts, so
        // letting media fall through would answer a vision question from text
        // alone — a wrong, confusing result. Fail closed with a 4xx instead.
        if MediaIngest.hasMedia(request) {
            await releaseBox.fire()
            throw MultiModelBatchSchedulerEngineError.mediaUnsupportedByModel(modelId)
        }

        let promptTokens: [Int]
        do {
            try checkFirstContentDeadline()
            // Profiler: template render + BPE encode is the dominant CPU
            // stage before submit.
            profile?.mark(.promptPrepStart)
            promptTokens = try ProviderPromptContractPipeline.tokenize(
                prepared: prepared,
                request: request,
                tokenizer: tokenizer.inner,
                modelType: modelType,
                templateControls: templateControls)
            try checkFirstContentDeadline()
        } catch {
            emitToolConstraintTelemetry(
                operation: "tool_constraint_compile_rejection",
                reason: prepared.mode.telemetryValue,
                severity: .warn)
            await releaseBox.fire()
            throw error
        }
        if let profile {
            let promptTokenCount = Int64(promptTokens.count)
            profile.update { f, now in
                f.mark(.promptPrepEnd, offsetUs: now)
                f.set(.promptTokens, promptTokenCount)
            }
        }

        // The rendered prompt determines whether output starts in reasoning
        // or content mode. Seed that state before any model output so neither
        // thinking-enabled nor thinking-disabled answers buffer until finish.
        do {
            try checkFirstContentDeadline()
        } catch {
            await releaseBox.fire()
            throw error
        }
        let reasoningPrefix = ReasoningPromptProbe.streamingPrefix(
            reasoningParser: request.reasoningParser,
            stream: request.stream,
            promptTokens: promptTokens,
            decodeTail: { tokenizer.inner.decode(tokenIds: $0, skipSpecialTokens: false) }
        )
        do {
            try checkFirstContentDeadline()
        } catch {
            await releaseBox.fire()
            throw error
        }

        // Parser resolution precedes both text and qualified native media.
        let tokenConstraint: (any CBv2TokenConstraint)?
        do {
            try checkFirstContentDeadline()
            guard let bridge = engineV2Bridge else {
                throw MultiModelBatchSchedulerEngineError.generationFailed(
                    "internal error: model '\(modelId)' has no serving engine (no v2 bridge)")
            }
            let toolConstraintStart = SuspendingClock.now
            tokenConstraint = try ToolConstraintFactory.make(
                prepared: prepared,
                request: request,
                tokenizer: tokenizer,
                modelContext: ChatTemplateFixContext(
                    modelId: request.model, modelType: modelType),
                defaultMaxTokens: defaultMaxTokens,
                stopTokenIDs: bridge.stopTokenIds,
                nativePromptTokens: promptTokens)
            // Grammar compile (Gemma) can take the tool-constraint lock on the
            // first build per stop-set; only worth a lock when tools exist.
            if prepared.tools?.isEmpty == false {
                profile?.markDuration(.toolConstraint, start: toolConstraintStart)
            }
            try checkFirstContentDeadline()
        } catch {
            await releaseBox.fire()
            throw error
        }

        let requestId = "req-\(UUID().uuidString.prefix(12))"

        // ONE ENGINE (v0.7.5): every production slot — ProviderLoop AND
        // the standalone server — carries a v2 bridge; the tokenized
        // prompt submits through it. The bridge yields the identical
        // `AsyncStream<GenerationEvent>` shape, so everything downstream —
        // tool-call parsing, SSE framing, error→status mapping, billing
        // extraction — is engine-agnostic. A TEXT request that reaches an
        // entry with NO bridge is a hard internal error (500) —
        // structurally unreachable, kept as loud insurance per the
        // fail-loud contract (the legacy scheduler is deleted).
        let upstream: AsyncStream<GenerationEvent>
        let cancelUpstream: @Sendable () async -> Void
        if let bridge = engineV2Bridge {
            do {
                try checkFirstContentDeadline()
                upstream = try await bridge.submitTokenized(
                    promptTokens: promptTokens,
                    // Sampling/stop/max-token translation reuses the OpenAI →
                    // internal request mapping (`EngineV2Translation` reads the
                    // internal shape). `logprobs`/`top_logprobs` and
                    // Sealed-body sampling controls arrive through
                    // `engineV2Sampling` and override the decoded upstream
                    // fields. Standalone requests use the upstream fields.
                    request: Self.translate(
                        openAIRequest: request, defaultMaxTokens: defaultMaxTokens,
                        logprobs: engineV2Logprobs != nil ? true : nil,
                        topLogprobs: engineV2Logprobs?.topLogprobs,
                        logitBias: engineV2Sampling?.logitBias,
                        seed: engineV2Sampling?.seed),
                    requestId: requestId,
                    // Same per-tenant scope the legacy submit threads into the
                    // checkpoint cache; the bridge maps it to CBv2Request.cacheSalt
                    // (TB-007/T-041 — LIVE as of v0.7.5 when PrefixCachePolicy
                    // funds the cache).
                    cacheScope: requestCacheScope,
                    cacheEnabled: cacheEnabled,
                    logprobsChannel: engineV2Logprobs?.channel,
                    usageSignal: requestUsage,
                    tokenConstraint: tokenConstraint,
                    firstContentDeadline: firstContentDeadline,
                    profile: profile
                )
                do {
                    try checkFirstContentDeadline()
                } catch {
                    await bridge.cancel(requestId: requestId)
                    throw error
                }
            } catch {
                await releaseBox.fire()
                throw error
            }
            cancelUpstream = { await bridge.cancel(requestId: requestId) }
        } else {
            // Fail-loud backstop: no engine at all on the entry. This can
            // only mean a wiring bug — surface it as a 500 provider fault,
            // never a silent degrade.
            await releaseBox.fire()
            throw MultiModelBatchSchedulerEngineError.generationFailed(
                "internal error: model '\(modelId)' has no serving engine (no v2 bridge)")
        }

        return try await makeDeadlineCheckedEventStream(
            upstream: upstream,
            cancelUpstream: cancelUpstream,
            toolHandler: toolHandler,
            prepared: prepared,
            releaseBox: releaseBox,
            usageSignal: requestUsage,
            reasoningPrefix: reasoningPrefix,
            // MiMo ON/unset emits only the assistant header, not an open think
            // span. Empty initial content state keeps native splitting active
            // without fabricating prompt/seed bytes. Output permission is the
            // independently validated Boolean, never this generic probe.
            nativeReasoningPrefix: modelType == "mimo_v2" ? "" : (ToolChoiceEnforcementPolicy.usesNativeTextChannels(
                ChatTemplateFixContext(modelId: modelId, modelType: modelType))
                ? (ReasoningPromptProbe.streamingPrefix(forPromptTail:
                    tokenizer.inner.decode(tokenIds: Array(promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                                           skipSpecialTokens: false)) ?? "<think></think>") : nil),
            preserveInnerReasoningSpans: ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(
                .init(modelId: modelId, modelType: modelType)),
            nativeGemmaChannels: modelType == "diffusion_gemma",
            nativeGemmaReasoningEnabled: modelType != "diffusion_gemma"
                || DiffusionGemmaReasoningControl.enabled(for: request, controls: templateControls),
            nativeMiMoChannels: modelType == "mimo_v2",
            nativeMiMoThinkingEnabled: nativeMiMoThinkingEnabled
        )
    }

    @inline(__always)
    private func checkFirstContentDeadline() throws {
        try Task.checkCancellation()
        try firstContentDeadline?.check()
    }

    /// Same authenticated parser, acquired lease, bridge, tool validator and
    /// native reasoning router as text. Never enter generic VLM generation.
    private func prepareNativeMiMoMedia(request: OpenAIChatCompletionRequest,
        templateControls: ChatTemplateControls, requestUsage: EngineV2RequestUsageSignal,
        prepared: ToolChoicePromptPolicy.Prepared, toolHandler: BatchedToolStreamHandler?,
        thinkingEnabled: Bool, acquired: consuming AcquiredModel
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent,Error> {
        try checkFirstContentDeadline()
        try templateControls.rawMiMoControls.validateMedia(modelType:acquired.modelType)
        guard engineV2Logprobs == nil, request.minP == nil || request.minP == 0,
              request.responseFormat?.requiresJSONOutput != true,
              let bridge = acquired.engineV2Bridge, acquired.nativeConsumerLease != nil else {
            throw MultiModelBatchSchedulerEngineError.multimodalRejected("native media output controls are unsupported")
        }
        let binding = try await bridge.nativeMiMoDecodedMediaBinding()
        if MediaIngest.hasAudio(request) {
            let audio = try await bridge.nativeMiMoDecodedAudioBinding()
            guard audio.load === binding.load else { throw MiMoV26ServingLoadError.nativeOwnerMismatch }
        }
        try checkFirstContentDeadline()
        // Compose with the reviewed native prepared-media deadline packet.
        // The SAME authenticated absolute deadline reaches existing atomic
        // SDK admission below; missing rates/expired clocks still refuse.
        // Never bypass it with a fabricated nil or text-only cost proof.
        let normalized = try ProviderPromptContractPipeline.normalizedInput(prepared:prepared,
            request:request,modelType:acquired.modelType,templateControls:templateControls,
            preserveMiMoMediaParts:true)
        let maximumOutput = request.maxTokens ?? binding.defaultMaxTokens
        let started = SuspendingClock.now
        profile?.mark(.promptPrepStart)
        let native = try await binding.load.prepareEncodedMediaInOwnedTask(normalized:normalized,
            controls:templateControls,maximumOutputTokens:maximumOutput,sampling:binding.sampling,acquired:acquired)
        defer {
            if let input = native.request.multimodal { native.engine.discardUnsubmittedNativeMedia(input) }
        }
        try checkFirstContentDeadline()
        if let profile {
            let elapsed = RequestProfileBuilder.microseconds(SuspendingClock.now - started)
            profile.update { fields, now in
                fields.mark(.promptPrepEnd,offsetUs:now)
                fields.set(.promptTokens,Int64(native.request.promptTokens.count))
                fields.add(.visionPrep,us:elapsed)
            }
        }
        let constraint = try ToolConstraintFactory.make(prepared:prepared,request:request,
            tokenizer:acquired.tokenizer,modelContext:.init(modelId:request.model,modelType:acquired.modelType),
            defaultMaxTokens:maximumOutput,stopTokenIDs:bridge.stopTokenIds,
            nativePromptTokens:native.request.promptTokens)
        guard constraint == nil else {
            throw MultiModelBatchSchedulerEngineError.multimodalRejected("native media token constraints are unsupported")
        }
        let id = "req-" + UUID().uuidString
        let upstream = try await bridge.submitTokenized(promptTokens:native.request.promptTokens,
            request:Self.translate(openAIRequest:request,defaultMaxTokens:maximumOutput,
                logitBias:engineV2Sampling?.logitBias,seed:engineV2Sampling?.seed),
            requestId:id,cacheScope:cacheScope,cacheEnabled:false,usageSignal:requestUsage,
            multimodal:native.request.multimodal,firstContentDeadline:firstContentDeadline,profile:profile)
        // Install the ONE existing router/forwarder before any post-submit
        // cancellation veto. Its protected mode drains actual terminal/error.
        do {
            return try makeEventStream(upstream:upstream,cancelUpstream:{ await bridge.cancel(requestId:id) },
                toolHandler:toolHandler,prepared:prepared,releaseBox:acquired.releaseToken,
                usageSignal:requestUsage,nativeReasoningPrefix:"",
                preserveInnerReasoningSpans:ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(
                    .init(modelId:request.model,modelType:acquired.modelType)),
                nativeMiMoChannels:true,nativeMiMoThinkingEnabled:thinkingEnabled,
                nativeMediaTerminalDrain:true)
        } catch {
            await bridge.cancel(requestId:id)
            throw error
        }
    }

    private func checkFirstContentDeadline(
        releasing releaseBox: OneShotRelease
    ) async throws {
        do {
            try checkFirstContentDeadline()
        } catch {
            await releaseBox.fire()
            throw error
        }
    }

    /// Build the outer event stream only while the absolute pre-content
    /// deadline remains live. `makeEventStream` starts its forwarding task
    /// synchronously, so an expiry observed after construction must cancel the
    /// engine row and release the model pin before the throw escapes.
    private func makeDeadlineCheckedEventStream(
        upstream: AsyncStream<GenerationEvent>,
        cancelUpstream: @escaping @Sendable () async -> Void,
        toolHandler: BatchedToolStreamHandler?,
        prepared: ToolChoicePromptPolicy.Prepared,
        releaseBox: OneShotRelease,
        usageSignal: EngineV2RequestUsageSignal,
        reasoningPrefix: String? = nil,
        nativeReasoningPrefix: String? = nil,
        preserveInnerReasoningSpans: Bool = false,
        nativeGemmaChannels: Bool = false,
        nativeGemmaReasoningEnabled: Bool = true,
        nativeMiMoChannels: Bool = false,
        nativeMiMoThinkingEnabled: Bool = true
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        do {
            try checkFirstContentDeadline()
        } catch {
            await cancelUpstream()
            await releaseBox.fire()
            throw error
        }
        do {
            let stream = try makeEventStream(
                upstream: upstream,
                cancelUpstream: cancelUpstream,
                toolHandler: toolHandler,
                prepared: prepared,
                releaseBox: releaseBox,
                usageSignal: usageSignal,
                reasoningPrefix: reasoningPrefix,
                nativeReasoningPrefix: nativeReasoningPrefix,
                preserveInnerReasoningSpans: preserveInnerReasoningSpans,
                nativeGemmaChannels: nativeGemmaChannels,
                nativeGemmaReasoningEnabled: nativeGemmaReasoningEnabled,
                nativeMiMoChannels: nativeMiMoChannels,
                nativeMiMoThinkingEnabled: nativeMiMoThinkingEnabled)
            try checkFirstContentDeadline()
            return stream
        } catch {
            releaseBox.nativeConsumerLease?.closeAndCancel()
            await cancelUpstream()
            await releaseBox.fire()
            throw error
        }
    }

    /// Translate an engine `GenerationEvent` stream into the upstream
    /// `MLXServerGenerationEvent` shape, with tool-call parsing, usage/info
    /// framing, structured-error promotion, and release-on-every-exit.
    /// Shared by the batched/v2 TEXT path and the v0.7.5 media-through-v2
    /// path (which passes `toolHandler: nil` — see the routing comment) so
    /// the downstream SSE/billing contract is identical for both.
    private func makeEventStream(
        upstream: AsyncStream<GenerationEvent>,
        cancelUpstream: @escaping @Sendable () async -> Void,
        toolHandler: BatchedToolStreamHandler?,
        prepared: ToolChoicePromptPolicy.Prepared,
        releaseBox: OneShotRelease,
        usageSignal: EngineV2RequestUsageSignal,
        reasoningPrefix: String? = nil,
        nativeReasoningPrefix: String? = nil,
        preserveInnerReasoningSpans: Bool = false,
        nativeGemmaChannels: Bool = false,
        nativeGemmaReasoningEnabled: Bool = true,
        nativeMiMoChannels: Bool = false,
        nativeMiMoThinkingEnabled: Bool = true,
        nativeMediaTerminalDrain: Bool = false
    ) throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        // One forwarding implementation preserves all parser/event bytes. The
        // native path changes only task ownership and cancellation handoff.
        let forward: @Sendable (AsyncThrowingStream<MLXServerGenerationEvent, Error>.Continuation,
                                @Sendable () -> Void) async -> Void = { continuation, removeDisconnect in
                defer { removeDisconnect() }
                var promptTokenCount = 0
                var completionTokens = 0
                var startedAt = Date()
                var firstTokenAt: Date?
                var lastTokenAt: Date?
                var stopReason: String = "stop"
                var failed: String?
                var observedEngineTerminal = false
                var mediaParserFailure: Error?
                // Typed platform/engine terminal (deadline lease / watchdog),
                // carrying the cause + reconciled usage so they survive the
                // throw instead of being flattened into a string by `failed`.
                var failedTerminal: MultiModelBatchSchedulerEngineError?
                var router = NativeToolStreamRouter(handler: toolHandler,
                    requiresToolCall: prepared.requiresToolCall, nativePrefix: nativeReasoningPrefix,
                    preserveInnerReasoningSpans: preserveInnerReasoningSpans,
                    nativeGemmaChannels: nativeGemmaChannels,
                    nativeGemmaReasoningEnabled: nativeGemmaReasoningEnabled,
                    nativeMiMoChannels: nativeMiMoChannels,
                    nativeMiMoThinkingEnabled: nativeMiMoThinkingEnabled,
                    nativeMiMoRequiresConstraint: nativeMiMoChannels && prepared.mode.requiresInferenceConstraint)
                startedAt = Date()

                #if DEBUG
                if releaseBox.nativeConsumerLease != nil, let hold = _testNativeForwardingHold {
                    await hold(.beforeForward)
                }
                #endif
                // Owner-driven close can cancel this Task while a client is
                // still listening, unlike a vanished onTermination consumer.
                // Do not seed content or manufacture a successful empty stop.
                if releaseBox.nativeConsumerLease != nil, Task.isCancelled {
                    await cancelUpstream()
                    await releaseBox.fire()
                    continuation.finish(throwing: CancellationError())
                    return
                }

                // Restore the prompt-side reasoning state in the downstream
                // parser before model output. This prefix emits no SSE frame
                // and bypasses the tool handler because it is not generated
                // output. Real content and usage continue through the normal
                // event handling below.
                if let reasoningPrefix, !router.usesNativeChannels {
                    continuation.yield(.content(reasoningPrefix))
                }

                eventLoop: for await event in upstream {
                    #if DEBUG
                    if releaseBox.nativeConsumerLease != nil, let hold = _testNativeForwardingHold {
                        await hold(.receivedEvent(event))
                    }
                    #endif
                    if nativeMediaTerminalDrain,
                       (releaseBox.nativeConsumerLease?.snapshot().phase != .active || mediaParserFailure != nil),
                       case .chunk = event {
                        continue
                    }
                    if Task.isCancelled {
                        // Preserve already-observed engine terminal/error
                        // precedence, including a failure just returned by
                        // next() before this cancellation check. Other native
                        // events must not become new visible content/success.
                        if releaseBox.nativeConsumerLease != nil {
                            switch event {
                            case .terminal, .error: break
                            default: break eventLoop
                            }
                        } else {
                            await cancelUpstream()
                            await releaseBox.fire()
                            continuation.finish()
                            return
                        }
                    }
                    switch event {
                    case .chunk(let text):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        lastTokenAt = Date()
                        if !text.isEmpty {
                            do {
                                for routed in try router.process(text) { continuation.yield(routed) }
                            } catch {
                                await cancelUpstream()
                                if nativeMediaTerminalDrain {
                                    mediaParserFailure = error
                                    continue eventLoop
                                }
                                await releaseBox.fire()
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                    case .info(let p, let c, _, let reason):
                        observedEngineTerminal = true
                        promptTokenCount = p
                        completionTokens = c
                        // Engine-reported finish reason ("stop"/"length");
                        // nil (cancel-partials, older paths) keeps "stop".
                        // Threaded into ServerGenerationInfo.stopReason below,
                        // which MLXOpenAIService emits as finish_reason —
                        // max_tokens truncations now reach clients as "length".
                        if let reason { stopReason = reason }
                    case .error(let message):
                        observedEngineTerminal = true
                        failed = message
                    case .terminal(let cause, let message, let p, let c):
                        observedEngineTerminal = true
                        // Preserve the machine-readable cause AND the
                        // engine-reconciled usage (partial generation included)
                        // so the provider can emit terminal_cause/attempt_usage
                        // instead of a generic string with zero usage. The
                        // human-readable message is cause-prefixed so the wire
                        // `error` field is informative on its own.
                        failedTerminal = .platformTerminal(
                            cause: cause,
                            message: "\(cause.rawValue): \(message)",
                            attemptUsage: UsageInfo(
                                promptTokens: UInt64(max(0, p)),
                                completionTokens: UInt64(max(0, c))))
                    }
                }

                if let failedTerminal {
                    // A typed terminal wins over any legacy string: it carries
                    // the cause + usage the status mapper and coordinator need.
                    await releaseBox.fire()
                    continuation.finish(throwing: failedTerminal)
                    return
                }

                if let failed {
                    if failed == "tool_constraint_impossible_state" {
                        emitToolConstraintTelemetry(
                            operation: "tool_constraint_impossible",
                            reason: prepared.mode.telemetryValue,
                            severity: .error)
                    }
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

                // AsyncStream.next() may return nil on cancellation WITHOUT
                // entering the loop body. A native owner close must not turn
                // that nil into successful tool flushing or .info(stop).
                // Already-observed typed/legacy engine failures above win.
                if nativeMediaTerminalDrain, !observedEngineTerminal {
                    await releaseBox.fire()
                    continuation.finish(throwing:MultiModelBatchSchedulerEngineError.generationFailed(
                        "native media stream closed without a terminal event"))
                    return
                }
                if let mediaParserFailure {
                    await releaseBox.fire()
                    continuation.finish(throwing:mediaParserFailure)
                    return
                }
                if releaseBox.nativeConsumerLease != nil, Task.isCancelled {
                    await cancelUpstream()
                    await releaseBox.fire()
                    continuation.finish(throwing: CancellationError())
                    return
                }
                if nativeMediaTerminalDrain,
                   releaseBox.nativeConsumerLease?.snapshot().phase != .active {
                    await releaseBox.fire()
                    continuation.finish(throwing:CancellationError())
                    return
                }

                // Flush and validate parsed calls. Gemma required/named are
                // sampler-constrained; Qwen required/named are prompt-forced
                // and fail closed here before a call is exposed. This remains
                // defense in depth for every mode.
                do {
                    for routed in try router.finishText() { continuation.yield(routed) }
                } catch {
                    await releaseBox.fire()
                    continuation.finish(throwing: error)
                    return
                }
                let toolCalls = toolHandler?.finish() ?? []
                if nativeMiMoChannels, (toolHandler?.parseFailureCount ?? 0) > 0 {
                    await releaseBox.fire()
                    continuation.finish(throwing: prepared.mode.requiresInferenceConstraint
                        ? MultiModelBatchSchedulerEngineError.toolChoiceViolation("native MiMo tool output is invalid")
                        : MultiModelBatchSchedulerEngineError.generationFailed("native MiMo tool output is invalid"))
                    return
                }
                if prepared.mode == .auto,
                    let residual = toolHandler?.takeResidualText(),
                    !residual.isEmpty
                {
                    continuation.yield(router.visibleEvent(residual))
                }
                if prepared.mode == .auto, (toolHandler?.parseFailureCount ?? 0) > 0 {
                    emitToolConstraintTelemetry(
                        operation: "tool_constraint_fallback",
                        reason: "parser",
                        severity: .warn)
                }
                do {
                    try ToolConstraintValidation.validate(
                        toolCalls, prepared: prepared)
                } catch {
                    await releaseBox.fire()
                    continuation.finish(throwing: error)
                    return
                }
                if prepared.mode.requiresInferenceConstraint {
                    emitToolConstraintTelemetry(
                        operation: "tool_constraint_valid",
                        reason: prepared.mode.telemetryValue)
                }
                for toolCall in toolCalls {
                    continuation.yield(.toolCall(toolCall))
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
                            stopReason: stopReason,
                            cachedPromptTokens: usageSignal.prefixCacheHitTokens
                        )
                    )
                )
                await releaseBox.fire()
                continuation.finish()
        }
        if let lease = releaseBox.nativeConsumerLease {
            let pair = AsyncThrowingStream<MLXServerGenerationEvent, Error>.makeStream()
            let disconnect = NativeLocalDisconnectRegistration()
            let handoff = try lease.makeForwardingHandoff(cancelForwardingTask:!nativeMediaTerminalDrain,cancel: {
                await cancelUpstream()
                await releaseBox.fire()
            }, operation: {
                await forward(pair.continuation, { disconnect.remove() })
            })
            // The actual forwarding handle and its termination obligation are
            // installed before either disconnect or body work can run.
            pair.continuation.onTermination = { @Sendable _ in handoff.terminate() }
            disconnect.set(LocalRequestCancellation.current?.register { handoff.cancel() })
            handoff.activate()
            return pair.stream
        }
        // Exact existing non-native cancellation/release behavior.
        let disconnect = LocalRequestCancellation.current?.register {
            Task { await cancelUpstream() }
        }
        return AsyncThrowingStream { continuation in
            let task = Task { await forward(continuation, { disconnect?.remove() }) }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task {
                    await cancelUpstream()
                    await releaseBox.fire()
                }
            }
        }
    }

    #if DEBUG
    /// Exercise the production forwarding body with real host streams. This
    /// bypasses only acquisition/tokenization, never substitutes parser output.
    func _testMakeEventStream(
        upstream: AsyncStream<GenerationEvent>,
        cancelUpstream: @escaping @Sendable () async -> Void,
        prepared: ToolChoicePromptPolicy.Prepared,
        releaseBox: OneShotRelease,
        reasoningPrefix: String? = nil
    ) throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        try makeEventStream(upstream: upstream, cancelUpstream: cancelUpstream,
            toolHandler: nil, prepared: prepared, releaseBox: releaseBox,
            usageSignal: EngineV2RequestUsageSignal(), reasoningPrefix: reasoningPrefix)
    }
    #endif

    public func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse {
        let resolved = try await resolveTokenizer(modelId: request.model)
        let tokens = resolved.tokenizer.inner.encode(
            text: request.prompt,
            addSpecialTokens: request.addSpecialTokens ?? true
        )
        return TokenizeResponse(tokens: tokens)
    }

    public func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse {
        let resolved = try await resolveTokenizer(modelId: request.model)
        let text = resolved.tokenizer.inner.decode(
            tokenIds: request.tokens,
            skipSpecialTokens: request.skipSpecialTokens ?? false
        )
        return DetokenizeResponse(text: text)
    }

    public func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse {
        let resolved = try await resolveTokenizer(modelId: request.model)
        if resolved.modelType == "mimo_v2" {
            let chat = OpenAIChatCompletionRequest(model: request.model ?? "",
                messages: request.messages, tools: request.tools)
            try MiMoV26TemplateFix.validateRequest(chat)
        }
        let messages = request.messages.map { $0.templateMessageDict() }
        let tools = request.tools?.map { $0.toolSpec() }
        // Drop JSON `null` / `Optional` leaves the Jinja bridge
        // can't convert before rendering (mirrors `streamChatCompletion`).
        let fixContext = ChatTemplateFixContext(
            modelId: request.model, modelType: resolved.modelType)
        let tokens = try resolved.tokenizer.inner.applyChatTemplate(
            messages: ChatTemplateFixes.normalizeMessages(messages, context: fixContext),
            tools: ChatTemplateFixes.normalizeTools(tools, context: fixContext),
            additionalContext: nil
        )
        return TokenizeResponse(tokens: tokens)
    }

    // MARK: - Tokenizer resolution

    /// Resolve the tokenizer for a request. If the request specifies a
    /// `model`, prefer that. Otherwise fall back to any resident model
    /// (sorted for determinism). Throws when no model is loaded.
    private func resolveTokenizer(modelId: String?) async throws -> TokenizerResolution {
        if let tokenizerProvider {
            return try await tokenizerProvider(modelId)
        }
        let registry = await (registryProvider?() ?? [:])
        if let modelId, let entry = registry[modelId] {
            return TokenizerResolution(
                tokenizer: entry.tokenizer, modelType: entry.modelType)
        }
        if let modelId, registry[modelId] == nil {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        if let firstKey = registry.keys.min(),
            let entry = registry[firstKey]
        {
            return TokenizerResolution(
                tokenizer: entry.tokenizer, modelType: entry.modelType)
        }
        throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
    }

    private func emitToolConstraintTelemetry(
        operation: String,
        reason: String,
        severity: TelemetrySeverity = .info
    ) {
        let event = TelemetryEvent(
            source: .provider,
            severity: severity,
            kind: .engineHealth,
            message: "engine_v2: tool constraint state"
        ).withFields([
            "component": .string("engine"),
            "backend": .string("engine_v2"),
            "operation": .string(operation),
            "reason": .string(reason),
        ])
        TelemetryClient.shared.emit(event)
    }
}
