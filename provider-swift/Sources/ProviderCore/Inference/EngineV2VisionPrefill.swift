// Copyright © 2026 Eigen Labs.
//
// ContinuousBatchingV2 — media-prefill construction for VLM slots.
//
// v0.7.2 routed only TEXT requests on a VLM-loaded Gemma 4 slot through the
// v2 engine (over the directly owned/shared `Gemma4TextModel` tower); v0.7.5
// added IMAGE requests via embedding-spliced vision prefill; v0.7.5 adds
// VIDEO (and mixed image+video), removing the last media reason to keep a
// legacy path. The engine contract is unchanged: `CBv2Request.multimodal`
// carries placeholder-token spans plus one precomputed
// `[1, spanTokens, hidden]` embedding per span, and the engine splices them
// verbatim over the scaled text embeddings (the exact `maskedScatter`
// semantics of MLXVLM Gemma4's `prepare`), applying the blockwise
// bidirectional span mask and snapping prefill chunks to block edges. This
// file builds that submission on the provider side:
//
//   1. decode media EXACTLY as the legacy path does
//      (`MediaIngest.buildUserInput` — same caps, same errors; inline videos
//      remain in owned memory-backed AVFoundation assets);
//   2. run the SAME `Gemma4Processor.prepare` the legacy path runs (same
//      resize/normalization, same chat templating, same per-image
//      `boi + <|image|> × imageSeqLength + eoi` expansion, same per-video
//      `timestamp + boi + <|video|> × count + eoi` block PER SAMPLED FRAME,
//      ≤32 frames uniformly sampled) to get the tokenized prompt + packed
//      pixels;
//   3. run the wrapper's vision tower + multimodal projector through the
//      public per-image / per-video-frame seams
//      (`Gemma4.perImageVisionFeatures` / `.perVideoFrameVisionFeatures` —
//      the SAME arrays `prepare` would scatter, the video seam selecting
//      the per-frame video patch budget), and eval them here, under the
//      container's serial isolation, so the engine's step loop never pays
//      the tower cost (the CBv2 contract calls the embeddings closure once
//      on the submit thread; we hand it precomputed arrays);
//   4. locate the placeholder runs of BOTH token ids in the tokenized
//      prompt — in prompt order — and carve one `CBv2ImageSpan` per image
//      and per sampled video frame (ascending, non-overlapping, in-prompt —
//      matching engine validation; adjacent media carve into adjacent
//      spans, which the engine coalesces into one bidirectional block,
//      exactly the wrapper's contiguous-run semantics). Runs pair with
//      features strictly by prompt order per kind, so interleaved
//      image/video requests keep their interleave.
//
// FAIL-LOUD CONTRACT (v0.7.5): every throw out of `prepare` lands in the
// scheduler engine's catch → ERROR `engine_v2_vision_refusal` telemetry +
// a retriable 503 (`.requestRejected`) so the coordinator's pre-content
// failover reroutes the request invisibly. There is NO legacy fallback for
// media on a v2-bridged slot (the pre-release `engine_v2_vision_fallback` WARN
// is gone with it). Deterministic input faults (`MediaError` — malformed/
// oversized media, or an intentionally unsupported family/media pairing) keep
// their 4xx mapping and are not refusals.
//
// FAIL-LOUD REQUIRES SURVIVING: a refusal contract is only worth what the
// process is worth, and MLX's default error handler is `fatalError` — a C++
// fault under this file used to kill the daemon outright, with every
// co-batched request on it. Two changes close that:
//
//   1. `prepare` runs under `MLX.withError`, and the recorded fault is checked
//      at every `eval` site (not just on block exit — the handler records and
//      RETURNS), so an MLX fault becomes a Swift throw the catch arms above
//      already handle: one failed request, not one dead provider.
//   2. The Qwen tower is driven ONE IMAGE AT A TIME and each image is admitted
//      against `MTLDevice.maxBufferLength` first (`VisionTowerBudget`), so the
//      dominant fault — the tower's N×N attention intermediate growing
//      quadratically in the request's TOTAL patch count — is neither produced
//      nor left for the allocator to discover. See `EngineV2VisionTowerRun`.
//
// BACKEND NOTE: CBv2 multimodal prefill requires a KV backend whose layer
// caches AFFIRM `CBv2MultimodalSpanCapableCache.honorsSpanMaskContexts`;
// one that does not vouch rejects at submit with
// `CBv2MultimodalError.unsupportedBackend`. Both shipping backends now
// vouch — contiguous always did, and the paged cache applies the
// bidirectional-within-block overlay in `PagedLayerCache.attendQueryBlock`
// (WS-2.2) — so `EngineV2KVBackendPolicy.applySlotVetoes` no longer forces
// VLM slots to contiguous unconditionally; it forces them only while the
// paged cache does NOT vouch. The submit-time rejection is therefore still
// unreachable in production, but for a different and better reason: not
// "vision never reaches paged", but "vision only reaches a backend that
// affirmed it can serve it". If it ever fires it maps to a deterministic
// 4xx via `multimodal_rejected:` (see
// `EngineV2Translation.admissionErrorMessage`) and doubles as the loud
// signal that the claim and the implementation disagreed.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXVLM

/// Coarse media shape of a request, for telemetry tagging only (rides the
/// allowlisted `media_kind` field). Never carries media content.
public enum EngineV2MediaKind: String, Sendable {
    case image
    case video
    case mixed
}

/// Construction failures of the v2 media-prefill submission. Every case is
/// caught by the scheduler engine and REFUSED loudly (ERROR telemetry + a
/// retriable 503; the coordinator reroutes) except deterministic request
/// shapes (`noProcessedMedia` and `unsupportedMedia`), which map to 400.
/// Messages are operator-facing and must never embed prompt or media content.
enum EngineV2VisionPrefillError: Error, CustomStringConvertible {
    /// The slot's loaded module is not a supported Gemma 4 or Qwen wrapper.
    case unsupportedVLM(String)
    /// The loaded family intentionally rejects this media shape on every
    /// provider, so rerouting cannot make the request serveable.
    case unsupportedMedia(String)
    /// The processor produced neither image nor video pixels for a media
    /// request — every media part sits on a non-user role, which
    /// `buildUserInput` drops (identically on the legacy path). This shape
    /// is deterministic for the request on EVERY provider, so the routing
    /// engine maps this one case to a 400 client fault instead of a
    /// retriable refusal (failover would burn retries on an identical
    /// outcome).
    case noProcessedMedia
    /// The tower/projector seam returned zero feature arrays for media the
    /// processor did produce pixels for.
    case emptyVisionFeatures(kind: EngineV2VisionPrefill.SpanKind)
    /// The request carries video but the model config declares no video
    /// placeholder token id (video explicitly disabled for the checkpoint).
    case videoPlaceholderUnavailable
    /// The config maps image and video placeholders to the SAME token id —
    /// runs would be unclassifiable, so the pairing cannot be trusted.
    case conflictingPlaceholderIds(Int)
    /// The tokenized prompt ran out of placeholder runs before every
    /// image's / video frame's span was carved (for video this is one half
    /// of the frame-count/span-count assertion: fewer runs than frames).
    case placeholderRunMissing(kind: EngineV2VisionPrefill.SpanKind, mediaIndex: Int)
    /// A placeholder run is shorter than its feature's soft-token count.
    case placeholderRunTooShort(
        kind: EngineV2VisionPrefill.SpanKind, mediaIndex: Int, expected: Int)
    /// Placeholder tokens remain after all of a kind's features were paired
    /// (for video: more runs than frames — the other half of the
    /// frame-count/span-count assertion). The span/embedding correspondence
    /// cannot be trusted.
    case unexpectedTrailingPlaceholders(kind: EngineV2VisionPrefill.SpanKind, count: Int)
    /// A vision feature has a non-positive soft-token length.
    case invalidFeatureLength(
        kind: EngineV2VisionPrefill.SpanKind, mediaIndex: Int, length: Int)
    /// A processor grid has a non-positive or unrepresentable patch count, so
    /// its pixel rows cannot be located in the packed tensor.
    case invalidVisionGrid(mediaIndex: Int)
    /// The processor's grids do not tile its packed pixel tensor exactly.
    /// Slicing on that disagreement would feed one image's pixels through
    /// another image's grid, so the prefill refuses instead.
    case visionPixelRunMismatch(expected: Int, actual: Int)
    /// The vision tower's projected activation would exceed what this GPU can
    /// allocate, predicted from the processor's grids BEFORE any tower work.
    /// Device-dependent, so it refuses retriably: a machine with a larger
    /// `MTLDevice.maxBufferLength` can serve the same request. The detail is
    /// built from integers and literals only (`VisionTowerBudget`).
    case towerBudgetExceeded(String)
    /// MLX refused an allocation the vision tower asked for. Carries only the
    /// two integers MLX itself reported — never its message — so the enum's
    /// content-safe-by-construction invariant survives a foreign fault.
    case towerAllocationRefused(requestedBytes: UInt64, limitBytes: UInt64)
    /// MLX raised a fault the tower could not attribute to an allocation.
    /// Content-free by construction: the stage name is a literal.
    case towerFault(stage: String)

    var description: String {
        switch self {
        case .unsupportedVLM(let type):
            return "engine_v2 media prefill: unsupported VLM wrapper \(type)"
        case .unsupportedMedia(let detail):
            return "engine_v2 media prefill: unsupported media \(detail)"
        case .noProcessedMedia:
            return "engine_v2 media prefill: processor produced no image or video pixels"
        case .emptyVisionFeatures(let kind):
            return "engine_v2 media prefill: vision tower returned no \(kind.rawValue) features"
        case .videoPlaceholderUnavailable:
            return "engine_v2 media prefill: model config has no video placeholder token id"
        case .conflictingPlaceholderIds(let id):
            return "engine_v2 media prefill: image and video share placeholder token id \(id)"
        case .placeholderRunMissing(let kind, let index):
            return "engine_v2 media prefill: no placeholder run for \(kind.noun) \(index)"
        case .placeholderRunTooShort(let kind, let index, let expected):
            return "engine_v2 media prefill: placeholder run for \(kind.noun) \(index) "
                + "is shorter than its \(expected) soft tokens"
        case .unexpectedTrailingPlaceholders(let kind, let count):
            return "engine_v2 media prefill: \(count) \(kind.rawValue) placeholder token(s) "
                + "left after pairing every \(kind.noun)"
        case .invalidFeatureLength(let kind, let index, let length):
            return "engine_v2 media prefill: \(kind.noun) \(index) produced an invalid "
                + "soft-token count \(length)"
        case .invalidVisionGrid(let index):
            return "engine_v2 media prefill: image \(index) has an unusable patch grid"
        case .visionPixelRunMismatch(let expected, let actual):
            return "engine_v2 media prefill: image grids cover \(actual) of \(expected) "
                + "packed pixel rows"
        case .towerBudgetExceeded(let detail):
            return "engine_v2 media prefill: \(detail)"
        case .towerAllocationRefused(let requested, let limit):
            return "engine_v2 media prefill: the vision tower asked MLX for \(requested) B "
                + "in one buffer, above this GPU's \(limit) B limit"
        case .towerFault(let stage):
            return "engine_v2 media prefill: MLX raised a fault during \(stage)"
        }
    }
}

/// Builds `CBv2MultimodalInput` submissions for image/video requests on a
/// v2-bridged Gemma 4 VLM slot. Pure functions; no state.
public enum EngineV2VisionPrefill {

    /// The media kind of one carved span (a span is always exactly one
    /// image or one sampled video frame — never `mixed`).
    public enum SpanKind: String, Sendable, Equatable {
        case image
        case video

        /// Human-readable unit for error messages ("image 2" vs "video
        /// frame 2" — a video span is one FRAME, not one clip).
        var noun: String {
            switch self {
            case .image: return "image"
            case .video: return "video frame"
            }
        }
    }

    /// One carved placeholder run: its engine span plus the media kind it
    /// pairs with. `carveSpans` returns these in prompt order; consuming
    /// each kind's features in that same order reproduces the exact
    /// span/embedding pairing.
    public struct CarvedSpan: Equatable, Sendable {
        public let kind: SpanKind
        public let span: CBv2ImageSpan
    }

    /// One fully-constructed media submission: the processor-expanded
    /// prompt (text + `boi`/placeholder/`eoi` blocks, one block per image
    /// and per sampled video frame), the per-media spans in prompt order,
    /// and the EVALUATED embeddings, one per span in the same order.
    ///
    /// `@unchecked Sendable` justification: the embedding arrays are
    /// `eval`ed before this struct leaves `container.perform` (the
    /// container API requires exactly that), never mutated afterwards, and
    /// ownership passes linearly scheduler-engine → bridge → engine submit.
    public struct PreparedSubmission: @unchecked Sendable {
        public let promptTokens: [Int]
        public let spans: [CBv2ImageSpan]
        public let embeddings: [MLXArray]
        public let attention: CBv2MultimodalAttention
        public let positionState: CBv2PositionState?
        /// Coarse request shape (image / video / mixed) for telemetry.
        public let mediaKind: EngineV2MediaKind

        public init(
            promptTokens: [Int], spans: [CBv2ImageSpan], embeddings: [MLXArray],
            attention: CBv2MultimodalAttention = .bidirectionalSpans,
            positionState: CBv2PositionState? = nil,
            mediaKind: EngineV2MediaKind
        ) {
            self.promptTokens = promptTokens
            self.spans = spans
            self.embeddings = embeddings
            self.attention = attention
            self.positionState = positionState
            self.mediaKind = mediaKind
        }

        /// The engine-facing input. The closure returns the precomputed
        /// arrays — the contract's "typically it returns precomputed
        /// arrays" fast path, so the engine's submit-thread call does no
        /// vision work.
        public func multimodalInput() -> CBv2MultimodalInput {
            let arrays = embeddings
            return CBv2MultimodalInput(
                spans: spans, attention: attention,
                positionState: positionState
            ) { arrays }
        }
    }

    /// Build the v2 media submission for `request` over the slot's loaded
    /// VLM container. Runs media decode, processor prepare, the vision
    /// tower + projector, and span carving under the container's serial
    /// isolation (the same serialization the legacy `container.prepare`/
    /// `generate` path uses, so wrapper module access never races).
    ///
    /// Throws `EngineV2VisionPrefillError` (and any `MediaError`/processor
    /// error the legacy path would also throw) — callers refuse loudly on
    /// every throw except `MediaError` (deterministic client fault, keeps
    /// its 4xx mapping) and `CancellationError` (the caller went away).
    static func prepare(
        container: ModelContainer,
        request: OpenAIChatCompletionRequest,
        reasoningEffort: String? = nil,
        enableThinkingOverride: Bool? = nil
    ) async throws -> PreparedSubmission {
        // Same decode path as the legacy stream (same caps, same MediaError
        // surface). Inline video bytes stay in the UserInput's owned
        // memory-backed asset while processor preparation samples and
        // rasterizes its frames; no plaintext file exists to clean up.
        let userInput = try await MediaIngest.buildUserInput(
            from: request,
            reasoningEffort: reasoningEffort,
            enableThinkingOverride: enableThinkingOverride)
        let towerLimits = VisionTowerBudget.liveLimits
        return try await container.perform(nonSendable: userInput) { ctx, userInput in
            // MLX's DEFAULT error handler is `fatalError`. A C++ fault raised
            // anywhere under this closure — most consequentially an allocation
            // the Metal allocator refuses because it exceeds
            // `MTLDevice.maxBufferLength` — therefore used to kill the whole
            // provider process, taking every co-batched request with it and
            // leaving a stale pid file behind (v0.8.7, 8 crashes in 9 hours on
            // one node). `withError` installs a task-local handler for the
            // duration of the prefill, so the same fault becomes a Swift throw
            // that the scheduler's existing catch arms turn into one failed
            // request. It is the LAST line of defence: `VisionTowerBudget`
            // refuses the predictable cases deterministically, up front.
            //
            // The handler RECORDS and RETURNS — it does not unwind — so the
            // box is threaded down to every `eval` site and checked there
            // (`throwIfMLXFaulted`) rather than only on block exit. Checking
            // only on exit would let the code run on after a refused
            // allocation and let a later Swift throw hide the real cause.
            do {
                return try await MLX.withError { (mlxErrors: MLX.ErrorBox) in
                    let submission = try await Self.buildSubmission(
                        ctx: ctx, userInput: userInput, towerLimits: towerLimits,
                        mlxErrors: mlxErrors)
                    try Self.throwIfMLXFaulted(mlxErrors)
                    return submission
                }
            } catch let mlxError as MLX.MLXError {
                throw Self.visionPrefillError(for: mlxError)
            }
        }
    }

    /// Convert a recorded MLX fault into our own vocabulary and throw it.
    ///
    /// `MLX.ErrorBox.check()` throws the raw `MLXError`, which would reach the
    /// scheduler's generic catch as a foreign error and lose its numbers to
    /// the telemetry privacy filter. Translating here keeps the operator-facing
    /// byte counts while the enum stays content-safe by construction.
    static func throwIfMLXFaulted(_ box: MLX.ErrorBox) throws {
        if let error = translatedFault(box.firstError) { throw error }
    }

    /// The pure half of ``throwIfMLXFaulted(_:)`` — `MLX.ErrorBox` has no
    /// public initializer, so the translation lives here where tests can
    /// reach it.
    static func translatedFault(_ recorded: Error?) -> Error? {
        guard let recorded else { return nil }
        if let mlxError = recorded as? MLX.MLXError {
            return visionPrefillError(for: mlxError)
        }
        return recorded
    }

    /// Run the processor, then dispatch to the loaded family's builder. Runs
    /// under the container's serial isolation, with MLX faults routed into
    /// Swift throws by the caller.
    private static func buildSubmission(
        ctx: ModelContext,
        userInput: UserInput,
        towerLimits: VisionTowerBudget.Limits,
        mlxErrors: MLX.ErrorBox
    ) async throws -> PreparedSubmission {
        let lmInput = try await ctx.processor.prepare(input: userInput)
        guard lmInput.image != nil || lmInput.video != nil else {
            throw EngineV2VisionPrefillError.noProcessedMedia
        }
        try throwIfMLXFaulted(mlxErrors)

        // [1, L] → [Int]. Forces evaluation of the (tiny, host-built)
        // token array only.
        let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)

        if let wrapper = ctx.model as? MLXVLM.Qwen35MoE {
            return try buildQwenSubmission(
                wrapper: wrapper, lmInput: lmInput, promptTokens: promptTokens,
                towerLimits: towerLimits, mlxErrors: mlxErrors)
        }
        guard let wrapper = ctx.model as? MLXVLM.Gemma4 else {
            throw EngineV2VisionPrefillError.unsupportedVLM(
                String(describing: type(of: ctx.model)))
        }
        return try buildGemmaSubmission(
            wrapper: wrapper, lmInput: lmInput, promptTokens: promptTokens)
    }

    /// Qwen3-VL: causal visual tokens, M-RoPE position state, and a vision
    /// tower driven ONE IMAGE AT A TIME (see `qwenPerImageVisionFeatures`).
    private static func buildQwenSubmission(
        wrapper: MLXVLM.Qwen35MoE,
        lmInput: LMInput,
        promptTokens: [Int],
        towerLimits: VisionTowerBudget.Limits,
        mlxErrors: MLX.ErrorBox
    ) throws -> PreparedSubmission {
        // Video remains fail-closed until a real processor/output
        // representation canary pins temporal packing end-to-end.
        guard lmInput.video == nil else {
            throw EngineV2VisionPrefillError.unsupportedMedia(
                "Qwen35MoE video media is not production-proven")
        }
        // `noProcessedMedia` means "the processor consumed no media", which
        // maps to a deterministic 400. Pixels WITHOUT grids is a different
        // thing — the processor produced something the seam cannot describe —
        // and must keep its retriable refusal rather than tell the caller
        // their media was attached to the wrong role.
        guard let image = lmInput.image else {
            throw EngineV2VisionPrefillError.noProcessedMedia
        }
        guard let grids = image.frames, !grids.isEmpty else {
            throw EngineV2VisionPrefillError.emptyVisionFeatures(kind: .image)
        }
        let imageFeatures = try qwenPerImageVisionFeatures(
            wrapper: wrapper, pixels: image.pixels, grids: grids,
            towerLimits: towerLimits, mlxErrors: mlxErrors)
        let carved = try carveSpans(
            tokens: promptTokens,
            imagePlaceholderId: wrapper.imagePlaceholderTokenId,
            imageSpanLengths: imageFeatures.map { $0.dim(1) },
            videoPlaceholderId: nil,
            videoSpanLengths: [])
        let position = try wrapper.positionResult(
            tokens: lmInput.text.tokens,
            imageGrids: grids,
            attentionMask: lmInput.text.mask)
        // The features are already materialized per image; only the position
        // ids are still lazy here.
        eval(position.promptPositionIds)
        return PreparedSubmission(
            promptTokens: promptTokens,
            spans: carved.map(\.span),
            embeddings: imageFeatures,
            attention: .causal,
            positionState: CBv2PositionState(
                promptPositionIds: position.promptPositionIds,
                decodeDeltas: position.decodeState.deltas),
            mediaKind: .image)
    }

    /// Gemma 4: bidirectional span masks, no position state, and a SigLIP
    /// tower whose own seam already forwards one image (or one sampled video
    /// frame) at a time with a fixed per-image patch count.
    private static func buildGemmaSubmission(
        wrapper: MLXVLM.Gemma4,
        lmInput: LMInput,
        promptTokens: [Int]
    ) throws -> PreparedSubmission {
        // Vision tower + multimodal projector — the SAME arrays the
        // wrapper's own `prepare` scatters: one per image, one per
        // sampled video frame (the video seam applies the per-frame
        // video patch budget, ~70 soft tokens per frame vs 280 per
        // image).
        var imageFeatures: [MLXArray] = []
        if let image = lmInput.image {
            imageFeatures = wrapper.perImageVisionFeatures(
                pixels: image.pixels, frames: image.frames)
            guard !imageFeatures.isEmpty else {
                throw EngineV2VisionPrefillError.emptyVisionFeatures(kind: .image)
            }
        }
        var videoFeatures: [MLXArray] = []
        var videoPlaceholderId: Int?
        if let video = lmInput.video {
            guard let videoId = wrapper.videoPlaceholderTokenId else {
                throw EngineV2VisionPrefillError.videoPlaceholderUnavailable
            }
            videoPlaceholderId = videoId
            videoFeatures = wrapper.perVideoFrameVisionFeatures(
                pixels: video.pixels, frames: video.frames)
            guard !videoFeatures.isEmpty else {
                throw EngineV2VisionPrefillError.emptyVisionFeatures(kind: .video)
            }
        }

        // A kind's placeholder id is watched ONLY when that kind has
        // features — mirroring the processor, which expands a
        // placeholder only when it produced the matching pixels (a
        // stray placeholder id of an absent kind stays an ordinary
        // embedded token on both paths).
        let carved = try carveSpans(
            tokens: promptTokens,
            imagePlaceholderId: imageFeatures.isEmpty
                ? nil : wrapper.imagePlaceholderTokenId,
            imageSpanLengths: imageFeatures.map { $0.dim(1) },
            videoPlaceholderId: videoPlaceholderId,
            videoSpanLengths: videoFeatures.map { $0.dim(1) })

        // Pair prompt-ordered spans back to their features. `carveSpans`
        // consumed each kind's features strictly in prompt order, so
        // walking its output with per-kind cursors reproduces the exact
        // pairing (interleaved image/video requests keep their
        // interleave; the engine receives spans and embeddings as
        // parallel arrays).
        var embeddings: [MLXArray] = []
        embeddings.reserveCapacity(carved.count)
        var imageCursor = 0
        var videoCursor = 0
        for entry in carved {
            switch entry.kind {
            case .image:
                embeddings.append(imageFeatures[imageCursor])
                imageCursor += 1
            case .video:
                embeddings.append(videoFeatures[videoCursor])
                videoCursor += 1
            }
        }

        // Materialize the tower output HERE — on the request's task,
        // under container isolation — not lazily on the engine's step
        // thread (where the fused tower graph would stall every
        // co-batched request's decode step for the duration).
        eval(embeddings)
        return PreparedSubmission(
            promptTokens: promptTokens,
            spans: carved.map(\.span),
            embeddings: embeddings,
            attention: .bidirectionalSpans,
            positionState: nil,
            mediaKind: lmInput.video == nil
                ? .image : (lmInput.image == nil ? .video : .mixed))
    }

    /// Translate an MLX fault into the prefill's content-safe vocabulary.
    ///
    /// MLX's message is produced entirely by its own C++ (shapes and byte
    /// counts; no request data is ever interpolated into it), but the
    /// `EngineV2VisionPrefillError` contract is that a case is content-safe
    /// BY CONSTRUCTION, not by trusting a foreign string. So the allocation
    /// refusal — the one MLX fault an operator actually needs numbers for —
    /// carries the two integers MLX reported and nothing else, and every
    /// other fault degrades to a stage label.
    static func visionPrefillError(for error: MLX.MLXError) -> EngineV2VisionPrefillError {
        guard case .caught(let message) = error else {
            return .towerFault(stage: "vision prefill")
        }
        if message.contains("[metal::malloc]"),
            let (requested, limit) = firstTwoIntegers(in: message)
        {
            return .towerAllocationRefused(requestedBytes: requested, limitBytes: limit)
        }
        return .towerFault(stage: "vision prefill")
    }

    /// The first two decimal integer runs in `text`, or nil.
    static func firstTwoIntegers(in text: String) -> (UInt64, UInt64)? {
        var found: [UInt64] = []
        var current = ""
        for character in text {
            if character.isASCII, character.isNumber {
                current.append(character)
                continue
            }
            if let value = UInt64(current) { found.append(value) }
            current = ""
            if found.count == 2 { break }
        }
        if found.count < 2, let value = UInt64(current) { found.append(value) }
        guard found.count == 2 else { return nil }
        return (found[0], found[1])
    }

    /// Carve one span per image and per sampled video frame out of the
    /// prompt's placeholder runs, walking the prompt LEFT TO RIGHT exactly
    /// once so interleaved image/video media keep their prompt order.
    ///
    /// `imageSpanLengths[i]` is image i's soft-token count
    /// (`imageFeatures[i].dim(1)`); `videoSpanLengths[j]` is frame j's.
    /// Media appear in the prompt in the same order the processor packed
    /// them (both derive from the same message walk; video frames are in
    /// video order then time order), so each encountered run of a kind
    /// pairs with that kind's next unconsumed feature. Each span must sit
    /// on an unbroken run of its placeholder id; adjacent media (a run
    /// longer than one feature, or back-to-back runs of different kinds)
    /// carve into back-to-back spans, which the engine coalesces into one
    /// bidirectional block — the wrapper's contiguous-run mask semantics.
    /// A nil placeholder id disables that kind (its lengths must then be
    /// empty, or `placeholderRunMissing` throws — nothing can ever pair).
    ///
    /// Any leftover or missing placeholder is a hard error (the
    /// span/embedding pairing can't be trusted) — for video these two
    /// errors ARE the frame-count/span-count assertion: the number of
    /// video placeholder runs must equal the number of frames the tower
    /// returned. The caller refuses loudly on every throw.
    ///
    /// Produces spans that satisfy engine validation by construction:
    /// ascending, non-overlapping, positive-length, in-prompt.
    static func carveSpans(
        tokens: [Int],
        imagePlaceholderId: Int?,
        imageSpanLengths: [Int],
        videoPlaceholderId: Int?,
        videoSpanLengths: [Int]
    ) throws -> [CarvedSpan] {
        if let imageId = imagePlaceholderId, let videoId = videoPlaceholderId,
            imageId == videoId
        {
            throw EngineV2VisionPrefillError.conflictingPlaceholderIds(imageId)
        }
        for (index, length) in imageSpanLengths.enumerated() where length <= 0 {
            throw EngineV2VisionPrefillError.invalidFeatureLength(
                kind: .image, mediaIndex: index, length: length)
        }
        for (index, length) in videoSpanLengths.enumerated() where length <= 0 {
            throw EngineV2VisionPrefillError.invalidFeatureLength(
                kind: .video, mediaIndex: index, length: length)
        }

        var spans: [CarvedSpan] = []
        spans.reserveCapacity(imageSpanLengths.count + videoSpanLengths.count)
        var imageCursor = 0
        var videoCursor = 0
        var position = 0
        while position < tokens.count {
            let kind: SpanKind
            if let imageId = imagePlaceholderId, tokens[position] == imageId {
                kind = .image
            } else if let videoId = videoPlaceholderId, tokens[position] == videoId {
                kind = .video
            } else {
                position += 1
                continue
            }
            let placeholderId = tokens[position]
            let lengths = kind == .image ? imageSpanLengths : videoSpanLengths
            let cursor = kind == .image ? imageCursor : videoCursor
            guard cursor < lengths.count else {
                // A run with no feature left to pair with — for video, MORE
                // placeholder runs than sampled frames.
                let trailing = tokens[position...].count(where: { $0 == placeholderId })
                throw EngineV2VisionPrefillError.unexpectedTrailingPlaceholders(
                    kind: kind, count: trailing)
            }
            let length = lengths[cursor]
            let end = position + length
            guard end <= tokens.count,
                tokens[position ..< end].allSatisfy({ $0 == placeholderId })
            else {
                throw EngineV2VisionPrefillError.placeholderRunTooShort(
                    kind: kind, mediaIndex: cursor, expected: length)
            }
            spans.append(
                CarvedSpan(
                    kind: kind, span: CBv2ImageSpan(tokenOffset: position, length: length)))
            if kind == .image { imageCursor += 1 } else { videoCursor += 1 }
            position = end
        }
        guard imageCursor == imageSpanLengths.count else {
            throw EngineV2VisionPrefillError.placeholderRunMissing(
                kind: .image, mediaIndex: imageCursor)
        }
        guard videoCursor == videoSpanLengths.count else {
            // FEWER video placeholder runs than sampled frames — the other
            // half of the frame-count/span-count assertion.
            throw EngineV2VisionPrefillError.placeholderRunMissing(
                kind: .video, mediaIndex: videoCursor)
        }
        return spans
    }

    /// Coarse media shape of `request` (image / video / mixed), for
    /// telemetry tagging on paths where the processor never ran (refusals
    /// can fire before `prepare` produced anything). Scans USER messages
    /// only — the media the processor actually consumes
    /// (`buildUserInput` drops media parts on non-user roles), so refusal
    /// tags match the success path's `lmInput`-derived kind. Callers only
    /// invoke this for requests that already passed `hasMedia`; a request
    /// whose media all sits on non-user roles reports `.image` here but
    /// never reaches refusal telemetry (it maps to the deterministic
    /// `noProcessedMedia` 400 instead).
    static func mediaKind(of request: OpenAIChatCompletionRequest) -> EngineV2MediaKind {
        var hasImage = false
        var hasVideo = false
        for message in request.messages where message.role == .user {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                switch part {
                case .imageURL: hasImage = true
                case .videoURL: hasVideo = true
                case .text, .unsupported: continue
                }
            }
        }
        if hasImage && hasVideo { return .mixed }
        return hasVideo ? .video : .image
    }

    /// ERROR `engine_health` event for a media-prefill construction failure
    /// → loud refusal (v0.7.5; replaces the pre-release fallback WARN — there is
    /// no legacy fallback anymore). Mirrors `EngineV2Config
    /// .emitFallbackTelemetry`'s field shape, plus `multimodal: true` and
    /// the `media_kind` tag (image/video/mixed) so refusal rates are
    /// observable per media shape in prod. Allowlisted fields only — never
    /// prompt/media content.
    ///
    /// PRIVACY: the human-readable `error` field is emitted ONLY for our own
    /// `EngineV2VisionPrefillError` (content-safe by construction — see the
    /// enum doc). Foreign throws (processor/MLX/media errors) carry
    /// `error_class` only: `MediaError.invalidURL`, for one, embeds up to
    /// 200 chars of the request's URI, and relying on call-site ordering
    /// (validateMedia running first) to keep such strings out of telemetry
    /// would be one refactor away from a leak — the same defense-in-depth
    /// stance as the bridge's engine-error telemetry.
    static func refusalTelemetryEvent(
        modelId: String, mediaKind: EngineV2MediaKind, error: Error
    ) -> TelemetryEvent {
        var event = TelemetryEvent(
            source: .provider,
            severity: .error,
            kind: .engineHealth,
            message: "engine_v2: media request refused — v2 media prefill construction failed"
        )
        var fields: [String: AnyCodableValue] = [
            "component": .string("engine"),
            "operation": .string("engine_v2_vision_refusal"),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
            "multimodal": .bool(true),
            "media_kind": .string(mediaKind.rawValue),
            "error_class": .string(String(reflecting: type(of: error))),
        ]
        if let visionError = error as? EngineV2VisionPrefillError {
            fields["error"] = .string(String(describing: visionError))
        }
        event.fields = TelemetryFieldFilter.filter(fields)
        return event
    }

    /// Content-safe detail for the client-facing rejection message: our own
    /// errors are content-safe by construction; foreign errors contribute
    /// their type name only (same stance as `refusalTelemetryEvent`).
    static func refusalDetail(for error: Error) -> String {
        if let visionError = error as? EngineV2VisionPrefillError {
            return String(describing: visionError)
        }
        return String(reflecting: type(of: error))
    }
}

/// Injectable seam for the scheduler engine's media-through-v2 routing
/// (mirrors `EngineV2LogprobsPlumbing` / `EngineV2SamplingOverrides`): the
/// preparer builds the submission, the sink receives the refusal ERROR.
/// `nil` on the engine ⇒ `.production`. Unit tests inject a scripted
/// preparer so the full routing seam is exercisable without model weights.
public struct EngineV2VisionPlumbing: Sendable {
    let prepare:
        @Sendable (ModelContainer, OpenAIChatCompletionRequest, String?, Bool?) async throws
            -> EngineV2VisionPrefill.PreparedSubmission
    let emitTelemetry: @Sendable (TelemetryEvent) -> Void

    init(
        prepare: @escaping @Sendable (ModelContainer, OpenAIChatCompletionRequest, String?, Bool?)
            async throws -> EngineV2VisionPrefill.PreparedSubmission,
        emitTelemetry: @escaping @Sendable (TelemetryEvent) -> Void
    ) {
        self.prepare = prepare
        self.emitTelemetry = emitTelemetry
    }

    static let production = EngineV2VisionPlumbing(
        prepare: { container, request, reasoningEffort, enableThinkingOverride in
            try await EngineV2VisionPrefill.prepare(
                container: container,
                request: request,
                reasoningEffort: reasoningEffort,
                enableThinkingOverride: enableThinkingOverride)
        },
        emitTelemetry: { TelemetryClient.shared.emit($0) }
    )
}
