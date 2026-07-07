// Copyright © 2026 Eigen Labs.
//
// ContinuousBatchingV2 — vision-prefill construction for VLM slots (v0.7.4).
//
// v0.7.2 routed only TEXT requests on a VLM-loaded Gemma 4 slot through the
// v2 engine (over the weight-shared extracted `Gemma4TextModel`); image
// requests kept the legacy non-batched wrapper path. The engine branch
// (`cbv2/multimodal-prefill`) adds embedding-spliced vision prefill:
// `CBv2Request.multimodal` carries placeholder-token spans plus one
// precomputed `[1, spanTokens, hidden]` embedding per span, and the engine
// splices them verbatim over the scaled text embeddings (the exact
// `maskedScatter` semantics of MLXVLM Gemma4's `prepare`), applying the
// blockwise bidirectional span mask and snapping prefill chunks to block
// edges. This file builds that submission on the provider side:
//
//   1. decode media EXACTLY as the legacy path does
//      (`VLMRequestInference.buildUserInput` — same caps, same errors);
//   2. run the SAME `Gemma4Processor.prepare` the legacy path runs (same
//      resize/normalization, same chat templating, same `boi + <|image|> ×
//      imageSeqLength + eoi` placeholder expansion) to get the tokenized
//      prompt + packed pixels;
//   3. run the wrapper's vision tower + multimodal projector through the
//      public per-image seam (`Gemma4.perImageVisionFeatures` — the SAME
//      arrays `prepare` would scatter), and eval them here, under the
//      container's serial isolation, so the engine's step loop never pays
//      the tower cost (the CBv2 contract calls the embeddings closure once
//      on the submit thread; we hand it precomputed arrays);
//   4. locate the per-image placeholder runs in the tokenized prompt and
//      carve one `CBv2ImageSpan` per image (ascending, non-overlapping,
//      in-prompt — matching engine validation; adjacent images carve into
//      adjacent spans, which the engine coalesces into one bidirectional
//      block, exactly the wrapper's contiguous-run semantics).
//
// FALLBACK CONTRACT: every throw out of `prepare` lands in the scheduler
// engine's catch → WARN `engine_v2_vision_fallback` telemetry + the legacy
// VLM path. A vision request is NEVER dropped because this construction
// failed. Video requests never reach this file (gated to legacy by
// `VLMRequestInference.hasVideo` — see that helper for why).
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

/// Construction failures of the v2 vision-prefill submission. Every case is
/// caught by the scheduler engine and downgraded to the legacy VLM path
/// (WARN telemetry; the request is served either way). Messages are
/// operator-facing — they ride the telemetry `error` field and must never
/// embed prompt or image content.
enum EngineV2VisionPrefillError: Error, CustomStringConvertible {
    /// The slot's loaded module is not the MLXVLM Gemma4 wrapper (the only
    /// VLM this seam supports — mirrors the v0.7.2 extraction gate).
    case notGemmaVLM(String)
    /// The processor produced no packed image pixels for a media request.
    case noProcessedImages
    /// The processor produced video pixels — video is gated to legacy
    /// upstream, so this is a defense-in-depth backstop.
    case videoUnsupported
    /// The tokenized prompt ran out of placeholder tokens before every
    /// image's span was carved.
    case placeholderRunMissing(imageIndex: Int)
    /// A placeholder run is shorter than the image's soft-token count.
    case placeholderRunTooShort(imageIndex: Int, expected: Int)
    /// Placeholder tokens remain after all images were paired — the
    /// span/embedding correspondence cannot be trusted.
    case unexpectedTrailingPlaceholders(count: Int)
    /// A vision feature has a non-positive soft-token length.
    case invalidFeatureLength(imageIndex: Int, length: Int)

    var description: String {
        switch self {
        case .notGemmaVLM(let type):
            return "engine_v2 vision prefill: unsupported VLM wrapper \(type)"
        case .noProcessedImages:
            return "engine_v2 vision prefill: processor produced no image pixels"
        case .videoUnsupported:
            return "engine_v2 vision prefill: video reached the images-only v2 seam"
        case .placeholderRunMissing(let index):
            return "engine_v2 vision prefill: no placeholder run for image \(index)"
        case .placeholderRunTooShort(let index, let expected):
            return "engine_v2 vision prefill: placeholder run for image \(index) "
                + "is shorter than its \(expected) soft tokens"
        case .unexpectedTrailingPlaceholders(let count):
            return "engine_v2 vision prefill: \(count) placeholder token(s) left "
                + "after pairing all images"
        case .invalidFeatureLength(let index, let length):
            return "engine_v2 vision prefill: image \(index) produced an invalid "
                + "soft-token count \(length)"
        }
    }
}

/// Builds `CBv2MultimodalInput` submissions for image requests on a
/// v2-bridged Gemma 4 VLM slot. Pure functions; no state.
public enum EngineV2VisionPrefill {

    /// One fully-constructed vision submission: the processor-expanded
    /// prompt (text + `boi`/placeholder/`eoi` blocks), the per-image spans,
    /// and the EVALUATED per-image embeddings.
    ///
    /// `@unchecked Sendable` justification: the embedding arrays are
    /// `eval`ed before this struct leaves `container.perform` (the
    /// container API requires exactly that), never mutated afterwards, and
    /// ownership passes linearly scheduler-engine → bridge → engine submit.
    public struct PreparedSubmission: @unchecked Sendable {
        public let promptTokens: [Int]
        public let spans: [CBv2ImageSpan]
        public let embeddings: [MLXArray]

        /// The engine-facing input. The closure returns the precomputed
        /// arrays — the contract's "typically it returns precomputed
        /// arrays" fast path, so the engine's submit-thread call does no
        /// vision work.
        public func multimodalInput() -> CBv2MultimodalInput {
            let arrays = embeddings
            return CBv2MultimodalInput(spans: spans) { arrays }
        }
    }

    /// Build the v2 vision submission for `request` over the slot's loaded
    /// VLM container. Runs media decode, processor prepare, the vision
    /// tower + projector, and span carving under the container's serial
    /// isolation (the same serialization the legacy `container.prepare`/
    /// `generate` path uses, so wrapper module access never races).
    ///
    /// Throws `EngineV2VisionPrefillError` (and any `MediaError`/processor
    /// error the legacy path would also throw) — callers treat every throw
    /// as "fall back to legacy".
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
            // MediaError surface). Video never reaches here (router gate),
            // so the temp-file-tracking overload is unnecessary.
            let userInput = try await VLMRequestInference.buildUserInput(from: request)
            let lmInput = try await ctx.processor.prepare(input: userInput)
            guard lmInput.video == nil else {
                throw EngineV2VisionPrefillError.videoUnsupported
            }
            guard let image = lmInput.image else {
                throw EngineV2VisionPrefillError.noProcessedImages
            }

            // [1, L] → [Int]. Forces evaluation of the (tiny, host-built)
            // token array only.
            let promptTokens = lmInput.text.tokens.asArray(Int32.self).map(Int.init)

            // Vision tower + multimodal projector — the SAME per-image
            // arrays the wrapper's own `prepare` scatters.
            let features = wrapper.perImageVisionFeatures(
                pixels: image.pixels, frames: image.frames)
            guard !features.isEmpty else {
                throw EngineV2VisionPrefillError.noProcessedImages
            }

            let spans = try carveSpans(
                tokens: promptTokens,
                placeholderId: wrapper.imagePlaceholderTokenId,
                spanLengths: features.map { $0.dim(1) })

            // Materialize the tower output HERE — on the request's task,
            // under container isolation — not lazily on the engine's step
            // thread (where the fused tower graph would stall every
            // co-batched request's decode step for the duration).
            eval(features)
            return PreparedSubmission(
                promptTokens: promptTokens, spans: spans, embeddings: features)
        }
    }

    /// Carve one span per image out of the prompt's placeholder runs.
    ///
    /// `spanLengths[i]` is image i's soft-token count (`features[i].dim(1)`);
    /// images appear in the prompt in the same order the processor packed
    /// them (both derive from the same message walk). Each span must sit on
    /// an unbroken run of `placeholderId` tokens; adjacent images (a run
    /// longer than one image) carve into back-to-back spans, which the
    /// engine coalesces into one bidirectional block — the wrapper's
    /// contiguous-run mask semantics. Any leftover or missing placeholder
    /// is a hard error (the span/embedding pairing can't be trusted), which
    /// the caller downgrades to the legacy path.
    ///
    /// Produces spans that satisfy engine validation by construction:
    /// ascending, non-overlapping, positive-length, in-prompt.
    static func carveSpans(
        tokens: [Int], placeholderId: Int, spanLengths: [Int]
    ) throws -> [CBv2ImageSpan] {
        var spans: [CBv2ImageSpan] = []
        spans.reserveCapacity(spanLengths.count)
        var cursor = 0
        for (imageIndex, length) in spanLengths.enumerated() {
            guard length > 0 else {
                throw EngineV2VisionPrefillError.invalidFeatureLength(
                    imageIndex: imageIndex, length: length)
            }
            // ArraySlice preserves absolute indices, so `start` is the
            // absolute prompt offset.
            guard let start = tokens[cursor...].firstIndex(of: placeholderId) else {
                throw EngineV2VisionPrefillError.placeholderRunMissing(
                    imageIndex: imageIndex)
            }
            let end = start + length
            guard end <= tokens.count,
                tokens[start ..< end].allSatisfy({ $0 == placeholderId })
            else {
                throw EngineV2VisionPrefillError.placeholderRunTooShort(
                    imageIndex: imageIndex, expected: length)
            }
            spans.append(CBv2ImageSpan(tokenOffset: start, length: length))
            cursor = end
        }
        let trailing = tokens[cursor...].count(where: { $0 == placeholderId })
        guard trailing == 0 else {
            throw EngineV2VisionPrefillError.unexpectedTrailingPlaceholders(count: trailing)
        }
        return spans
    }

    /// WARN `engine_health` event for a vision-prefill construction failure
    /// → legacy fallback. Mirrors `EngineV2Config.emitFallbackTelemetry`'s
    /// field shape, plus `multimodal: true` so vision-through-v2 engagement
    /// (and its fallback rate) is observable in prod. Allowlisted fields
    /// only — never prompt/image content.
    ///
    /// PRIVACY: the human-readable `error` field is emitted ONLY for our own
    /// `EngineV2VisionPrefillError` (content-safe by construction — see the
    /// enum doc). Foreign throws (processor/MLX/media errors) carry
    /// `error_class` only: `MediaError.invalidURL`, for one, embeds up to
    /// 200 chars of the request's URI, and relying on call-site ordering
    /// (validateMedia running first) to keep such strings out of telemetry
    /// would be one refactor away from a leak — the same defense-in-depth
    /// stance as the bridge's engine-error telemetry.
    static func fallbackTelemetryEvent(modelId: String, error: Error) -> TelemetryEvent {
        var event = TelemetryEvent(
            source: .provider,
            severity: .warn,
            kind: .engineHealth,
            message: "engine_v2: vision request fell back to the legacy VLM path"
        )
        var fields: [String: AnyCodableValue] = [
            "component": .string("engine"),
            "operation": .string("engine_v2_vision_fallback"),
            "backend": .string("engine_v2"),
            "model": .string(modelId),
            "multimodal": .bool(true),
            "error_class": .string(String(reflecting: type(of: error))),
        ]
        if let visionError = error as? EngineV2VisionPrefillError {
            fields["error"] = .string(String(describing: visionError))
        }
        event.fields = TelemetryFieldFilter.filter(fields)
        return event
    }
}

/// Injectable seam for the scheduler engine's vision-through-v2 routing
/// (mirrors `EngineV2LogprobsPlumbing` / `EngineV2SamplingOverrides`): the
/// preparer builds the submission, the sink receives the fallback WARN.
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
