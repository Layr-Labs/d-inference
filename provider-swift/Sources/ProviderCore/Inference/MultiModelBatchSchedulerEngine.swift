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
import MLXLMCommon
import MLXLMServer

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
    /// Authenticated remote or configured local prefix-cache scope. Maps to
    /// `CBv2Request.cacheSalt` for both cache tiers.
    private let cacheScope: String
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

    public init(
        registryProvider: @escaping @Sendable () async -> Registry,
        ensureLoaded: @escaping @Sendable (String) async throws -> Void = { _ in },
        reserveModel: @escaping @Sendable (String) async -> Void = { _ in },
        releaseModel: @escaping @Sendable (String) async -> Void = { _ in },
        defaultMaxTokens: Int = 4096,
        reasoningEffort: String? = nil,
        cacheScope: String = "",
        cacheEnabled: Bool = true,
        engineV2Logprobs: EngineV2LogprobsPlumbing? = nil,
        engineV2Sampling: EngineV2SamplingOverrides? = nil,
        engineV2Vision: EngineV2VisionPlumbing? = nil,
        engineV2Usage: EngineV2RequestUsageSignal? = nil
    ) {
        self.registryProvider = registryProvider
        self.ensureLoaded = ensureLoaded
        self.reserveModel = reserveModel
        self.releaseModel = releaseModel
        self.defaultMaxTokens = defaultMaxTokens
        self.reasoningEffort = reasoningEffort
        self.cacheScope = cacheScope
        self.cacheEnabled = cacheEnabled
        self.engineV2Logprobs = engineV2Logprobs
        self.engineV2Sampling = engineV2Sampling
        self.engineV2Vision = engineV2Vision
        self.engineV2Usage = engineV2Usage
        self.allowInternalToolSchemaMetadata = true
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
        self.reasoningEffort = nil
        self.cacheScope = ""
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
        let tokenizer: TokenizerHandle
        let modelType: String?
        let releaseBox: OneShotRelease
        let container: ModelContainer?
        let isVLM: Bool
        let engineV2Bridge: EngineV2Bridge?
        let visionGate: VisionMemoryGate?
        let modelId = request.model
        if let acquire {
            let acquired = try await acquire(modelId)
            tokenizer = acquired.tokenizer
            modelType = acquired.modelType
            releaseBox = acquired.releaseToken
            container = acquired.container
            isVLM = acquired.isVLM
            engineV2Bridge = acquired.engineV2Bridge
            visionGate = acquired.visionGate
        } else {
            try await ensureLoaded(modelId)
            let registry = await (registryProvider?() ?? [:])
            guard let entry = registry[modelId] else {
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
            }
            tokenizer = entry.tokenizer
            modelType = entry.modelType
            await reserveModel(modelId)
            releaseBox = OneShotRelease(release: releaseModel, modelId: modelId)
            container = entry.container
            isVLM = entry.isVLM
            engineV2Bridge = entry.engineV2Bridge
            visionGate = entry.visionGate
        }

        let prepared: ToolChoicePromptPolicy.Prepared
        do {
            prepared = try ToolChoicePromptPolicy.prepare(
                request,
                allowInternalSchemaMetadata: allowInternalToolSchemaMetadata)
        } catch {
            await releaseBox.fire()
            throw error
        }
        emitToolConstraintTelemetry(
            operation: "tool_constraint_mode",
            reason: prepared.mode.telemetryValue)

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
        if isVLM, let container, MediaIngest.hasMedia(request) {
            // `.auto` constrains nothing and `.none` hides the tools outright
            // (post-generation validation rejects any emitted call), so both
            // ride the media path unchanged. `.required`/`.named` need the
            // token automaton this path cannot install.
            guard prepared.mode == .auto || prepared.mode == .none else {
                await releaseBox.fire()
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "inference-enforced tool_choice is not supported for multimodal requests")
            }
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
            let projectedBytes = MediaIngest.projectedDecodeBytes(request)
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
                request, defaultMaxTokens: defaultMaxTokens,
                contextLength: mediaGate.contextLength)
            let mediaReserved = await mediaGate.reserve(
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
                try await MediaIngest.validateMedia(request)
            } catch {
                await mediaGate.release(requestId: mediaReqId)
                await releaseBox.fire()
                throw error
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
                    let visionPrepared = try await plumbing.prepare(
                        container, request, reasoningEffort)
                    let visionRequestId = "req-\(UUID().uuidString.prefix(12))"
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
                    // No provider-side tool parsing on this path — matching
                    // the legacy vision path exactly: the VLM processor's
                    // chat templating never renders tool specs, so the model
                    // is never prompted into tool-call syntax on either
                    // vision path.
                    let upstream = await bridge.submitTokenized(
                        promptTokens: visionPrepared.promptTokens,
                        request: Self.translate(
                            openAIRequest: request, defaultMaxTokens: defaultMaxTokens,
                            logprobs: engineV2Logprobs != nil ? true : nil,
                            topLogprobs: engineV2Logprobs?.topLogprobs,
                            logitBias: engineV2Sampling?.logitBias,
                            seed: engineV2Sampling?.seed),
                        requestId: visionRequestId,
                        cacheScope: cacheScope,
                        cacheEnabled: cacheEnabled,
                        logprobsChannel: engineV2Logprobs?.channel,
                        // Media requests are prefix-cache-excluded engine-
                        // side (hit tokens always 0), but the signal still
                        // reaches its terminal so the frames loop never
                        // waits on an unset box.
                        usageSignal: engineV2Usage,
                        multimodal: visionPrepared.multimodalInput(),
                        mediaKind: visionPrepared.mediaKind
                    )
                    return makeEventStream(
                        upstream: upstream,
                        cancelUpstream: { await bridge.cancel(requestId: visionRequestId) },
                        toolHandler: nil,
                        prepared: prepared,
                        releaseBox: releaseBox
                    )
                } catch is CancellationError {
                    // The CALLER went away mid-construction — that is not a
                    // v2 failure, so don't burn a refusal ERROR. Release and
                    // propagate like every other pre-stream throw above.
                    await mediaGate.release(requestId: mediaReqId)
                    await releaseBox.fire()
                    throw CancellationError()
                } catch let mediaError as MediaIngest.MediaError {
                    // Deterministic input fault (malformed/oversized media —
                    // the same class `validateMedia` rejects above). Fails
                    // identically on any provider, so it keeps its existing
                    // 4xx mapping (500 for the temp-file write case) instead
                    // of becoming a misleading retriable refusal.
                    await mediaGate.release(requestId: mediaReqId)
                    await releaseBox.fire()
                    throw mediaError
                } catch EngineV2VisionPrefillError.noProcessedMedia {
                    // Every media part sits on a non-user role, so the
                    // processor had nothing to consume (`buildUserInput`
                    // drops non-user media — identically on the legacy
                    // path). Deterministic for this request on EVERY
                    // provider: a 400 client fault, not a refusal — no
                    // ERROR telemetry, no failover burn.
                    await mediaGate.release(requestId: mediaReqId)
                    await releaseBox.fire()
                    throw MultiModelBatchSchedulerEngineError.multimodalRejected(
                        "multimodal_rejected: media parts must be attached to user "
                            + "messages; none of this request's media was consumable")
                } catch let visionError as EngineV2VisionPrefillError {
                    if case .unsupportedMedia(let detail) = visionError {
                        await mediaGate.release(requestId: mediaReqId)
                        await releaseBox.fire()
                        throw MultiModelBatchSchedulerEngineError.multimodalRejected(
                            "multimodal_rejected: \(detail)")
                    }
                    await mediaGate.release(requestId: mediaReqId)
                    await releaseBox.fire()
                    let mediaKind = EngineV2VisionPrefill.mediaKind(of: request)
                    plumbing.emitTelemetry(
                        EngineV2VisionPrefill.refusalTelemetryEvent(
                            modelId: modelId, mediaKind: mediaKind, error: visionError))
                    throw MultiModelBatchSchedulerEngineError.requestRejected(
                        "engine_v2 media prefill construction failed "
                            + "(media=\(mediaKind.rawValue)): "
                            + EngineV2VisionPrefill.refusalDetail(for: visionError)
                            + " — request not started; retry on another provider")
                } catch {
                    // REFUSAL: v2 media-prefill construction failed on this
                    // provider. ERROR telemetry (media-kind tagged) + 503 —
                    // the request was never started, so the coordinator's
                    // pre-content failover retries it invisibly elsewhere.
                    await mediaGate.release(requestId: mediaReqId)
                    await releaseBox.fire()
                    let mediaKind = EngineV2VisionPrefill.mediaKind(of: request)
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

        let toolSpecs = prepared.tools?.map { $0.toolSpec() }
        let promptTokens: [Int]
        do {
            promptTokens = try ProviderPromptContractPipeline.tokenize(
                prepared: prepared,
                request: request,
                tokenizer: tokenizer.inner,
                modelType: modelType,
                reasoningEffort: reasoningEffort)
        } catch {
            emitToolConstraintTelemetry(
                operation: "tool_constraint_compile_rejection",
                reason: prepared.mode.telemetryValue,
                severity: .warn)
            await releaseBox.fire()
            throw error
        }

        // Resolve tool call format before submitting so a bad
        // `tool_call_parser` value does not leave an orphaned request.
        let toolHandler: BatchedToolStreamHandler?
        if prepared.tools?.isEmpty == false {
            let format: ToolCallFormat
            do {
                format = try ServerToolParser.resolve(
                    requested: request.toolCallParser,
                    modelType: modelType
                )
                if prepared.mode.requiresInferenceGrammar, format != .gemma {
                    throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                        "inference-enforced Gemma tool_choice requires the gemma tool parser")
                }
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

        let tokenConstraint: (any CBv2TokenConstraint)?
        do {
            guard let bridge = engineV2Bridge else {
                throw MultiModelBatchSchedulerEngineError.generationFailed(
                    "internal error: model '\(modelId)' has no serving engine (no v2 bridge)")
            }
            tokenConstraint = try ToolConstraintFactory.make(
                prepared: prepared,
                request: request,
                tokenizer: tokenizer,
                modelContext: ChatTemplateFixContext(
                    modelId: request.model, modelType: modelType),
                defaultMaxTokens: defaultMaxTokens,
                stopTokenIDs: bridge.stopTokenIds)
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
            upstream = await bridge.submitTokenized(
                promptTokens: promptTokens,
                // Sampling/stop/max-token translation reuses the OpenAI →
                // internal request mapping (`EngineV2Translation` reads the
                // internal shape). `logprobs`/`top_logprobs` and
                // `logit_bias`/`seed` are not on the upstream request shape,
                // so they arrive via the `engineV2Logprobs`/`engineV2Sampling`
                // plumbing (decoded from the sealed body) and are overlaid
                // here.
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
                cacheScope: cacheScope,
                cacheEnabled: cacheEnabled,
                logprobsChannel: engineV2Logprobs?.channel,
                usageSignal: engineV2Usage,
                tokenConstraint: tokenConstraint
            )
            cancelUpstream = { await bridge.cancel(requestId: requestId) }
        } else {
            // Fail-loud backstop: no engine at all on the entry. This can
            // only mean a wiring bug — surface it as a 500 provider fault,
            // never a silent degrade.
            await releaseBox.fire()
            throw MultiModelBatchSchedulerEngineError.generationFailed(
                "internal error: model '\(modelId)' has no serving engine (no v2 bridge)")
        }

        return makeEventStream(
            upstream: upstream,
            cancelUpstream: cancelUpstream,
            toolHandler: toolHandler,
            prepared: prepared,
            releaseBox: releaseBox
        )
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
        releaseBox: OneShotRelease
    ) -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var promptTokenCount = 0
                var completionTokens = 0
                var startedAt = Date()
                var firstTokenAt: Date?
                var lastTokenAt: Date?
                var stopReason: String = "stop"
                var failed: String?
                // Typed platform/engine terminal (deadline lease / watchdog),
                // carrying the cause + reconciled usage so they survive the
                // throw instead of being flattened into a string by `failed`.
                var failedTerminal: MultiModelBatchSchedulerEngineError?
                startedAt = Date()

                for await event in upstream {
                    if Task.isCancelled {
                        await cancelUpstream()
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
                                    if prepared.requiresToolCall {
                                        let policy =
                                            switch prepared.mode {
                                            case .named: "named"
                                            case .required: "required"
                                            case .auto, .none: "constrained"
                                            }
                                        await cancelUpstream()
                                        await releaseBox.fire()
                                        continuation.finish(
                                            throwing: MultiModelBatchSchedulerEngineError
                                                .toolChoiceViolation(
                                                    "\(policy) tool_choice produced visible text before a tool call"
                                                ))
                                        return
                                    }
                                    // Auto prose remains genuinely streaming. Tool-call bytes
                                    // stay withheld and parsed calls are emitted only after the
                                    // validation boundary below; a later invalid call therefore
                                    // becomes a normal in-band stream error without exposing the
                                    // invalid call. Buffering this prose would turn every
                                    // tool-enabled auto stream into a non-streaming response.
                                    continuation.yield(.content(visible))
                                }
                            } else {
                                continuation.yield(.content(text))
                            }
                        }
                    case .info(let p, let c, _, let reason):
                        promptTokenCount = p
                        completionTokens = c
                        // Engine-reported finish reason ("stop"/"length");
                        // nil (cancel-partials, older paths) keeps "stop".
                        // Threaded into ServerGenerationInfo.stopReason below,
                        // which MLXOpenAIService emits as finish_reason —
                        // max_tokens truncations now reach clients as "length".
                        if let reason { stopReason = reason }
                    case .error(let message):
                        failed = message
                    case .terminal(let cause, let message, let p, let c):
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

                // Flush and validate parsed calls. Required/named/none are
                // enforced in the sampler; this remains the parser/schema
                // boundary for auto plus defense in depth for every mode.
                let toolCalls = toolHandler?.finish() ?? []
                if prepared.mode == .auto,
                    let residual = toolHandler?.takeResidualText(),
                    !residual.isEmpty
                {
                    continuation.yield(.content(residual))
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
                if prepared.mode.requiresInferenceGrammar {
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
                    await cancelUpstream()
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
        let fixContext = ChatTemplateFixContext(modelId: request.model)
        let tokens = try tokenizer.inner.applyChatTemplate(
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
