// Copyright © 2026 Eigen Labs.
//
// ContinuousBatchingV2 — media-prefill construction for VLM slots.
//
// v0.7.2 routed only TEXT requests on a VLM-loaded Gemma 4 slot through the
// v2 engine (over the weight-shared extracted `Gemma4TextModel`); v0.7.4
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
//      (`VLMRequestInference.buildUserInput` — same caps, same errors;
//      inline videos materialize to temp files for AVFoundation and are
//      removed before this construction returns);
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
// media on a v2-bridged slot (the v0.7.4 `engine_v2_vision_fallback` WARN
// is gone with it). Deterministic input faults (`MediaError` — malformed/
// oversized media) keep their 4xx mapping and are not refusals.
//
// BACKEND NOTE: CBv2 multimodal prefill requires the CONTIGUOUS KV backend
// (the paged backend cannot bind span attention masks and rejects at submit
// with `CBv2MultimodalError.unsupportedBackend`). Production engines are
// always built on `CBv2ContiguousKVBackend` (`EngineV2Factory
// .makeProductionEngine`), so the rejection is unreachable there; if it
// ever fires it maps to a deterministic 4xx via `multimodal_rejected:`
// (see `EngineV2Translation.admissionErrorMessage`).

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
/// retriable 503; the coordinator reroutes) — except `noProcessedMedia`,
/// which is a deterministic request shape mapped to a 400 client fault (see
/// its doc). Messages are operator-facing — they ride the telemetry `error`
/// field and the client-facing rejection message, and must never embed
/// prompt or media content.
enum EngineV2VisionPrefillError: Error, CustomStringConvertible {
    /// The slot's loaded module is not the MLXVLM Gemma4 wrapper (the only
    /// VLM this seam supports — mirrors the v0.7.2 extraction gate).
    case notGemmaVLM(String)
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

    var description: String {
        switch self {
        case .notGemmaVLM(let type):
            return "engine_v2 media prefill: unsupported VLM wrapper \(type)"
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
        /// Coarse request shape (image / video / mixed) for telemetry.
        public let mediaKind: EngineV2MediaKind

        /// The engine-facing input. The closure returns the precomputed
        /// arrays — the contract's "typically it returns precomputed
        /// arrays" fast path, so the engine's submit-thread call does no
        /// vision work.
        public func multimodalInput() -> CBv2MultimodalInput {
            let arrays = embeddings
            return CBv2MultimodalInput(spans: spans) { arrays }
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
        request: OpenAIChatCompletionRequest
    ) async throws -> PreparedSubmission {
        try await container.perform { ctx in
            guard let wrapper = ctx.model as? MLXVLM.Gemma4 else {
                throw EngineV2VisionPrefillError.notGemmaVLM(
                    String(describing: type(of: ctx.model)))
            }
            // Same decode path as the legacy stream (same caps, same
            // MediaError surface). Inline videos are written to temp files
            // for AVFoundation; `processor.prepare` consumes them fully
            // (frame sampling, resize, and rasterization all happen inside
            // it), so they are removed when this closure exits — on every
            // path.
            var tempFiles: [URL] = []
            defer { for url in tempFiles { try? FileManager.default.removeItem(at: url) } }
            let userInput = try await VLMRequestInference.buildUserInput(
                from: request, tempFiles: &tempFiles)
            let lmInput = try await ctx.processor.prepare(input: userInput)
            guard lmInput.image != nil || lmInput.video != nil else {
                throw EngineV2VisionPrefillError.noProcessedMedia
            }

            // [1, L] → [Int]. Forces evaluation of the (tiny, host-built)
            // token array only.
            let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)

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
                mediaKind: lmInput.video == nil
                    ? .image : (lmInput.image == nil ? .video : .mixed))
        }
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
    /// → loud refusal (v0.7.5; replaces the v0.7.4 fallback WARN — there is
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
        @Sendable (ModelContainer, OpenAIChatCompletionRequest) async throws
            -> EngineV2VisionPrefill.PreparedSubmission
    let emitTelemetry: @Sendable (TelemetryEvent) -> Void

    init(
        prepare: @escaping @Sendable (ModelContainer, OpenAIChatCompletionRequest)
            async throws -> EngineV2VisionPrefill.PreparedSubmission,
        emitTelemetry: @escaping @Sendable (TelemetryEvent) -> Void
    ) {
        self.prepare = prepare
        self.emitTelemetry = emitTelemetry
    }

    static let production = EngineV2VisionPlumbing(
        prepare: { container, request in
            try await EngineV2VisionPrefill.prepare(container: container, request: request)
        },
        emitTelemetry: { TelemetryClient.shared.emit($0) }
    )
}
