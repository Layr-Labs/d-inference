// Copyright © 2026 Eigen Labs.
//
// Muse Glimmer 30B image input on the text route.
//
// A Muse Glimmer image request takes the text route's own request plan: the
// same tool-choice preparation, template input, parser, constraints, stop
// scope and stream. Only the prompt differs: each user image part renders as
// the template's `{"type": "image"}` (one `<|patch|>`), the SDK expands each
// placeholder to `<|image_start|>`, the image's patch run and `<|image_end|>`,
// and the encoder's evaluated features replace the patch rows as causal
// spans (no positions of their own, no span masks). The text model attends
// to them like text, so the prefill grid cuts the prompt as it cuts text.
//
// Image rows never reuse or publish the prefix cache (no media prefix
// identity), and the SDK runs them on the target alone, never drafted.
//
// Decode goes through `MediaIngest`: data URLs only, EXIF orientation, the
// per-image, per-request and count caps. Geometry and placeholders are
// validated before any tower work, and the tower runs one image at a time.

import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXVLM
import ProviderCoreFoundation

enum MuseGlimmerImagePrefill {
    typealias Grid = MuseGlimmerImageGeometry.Grid

    // MARK: Refusals, before any decode or reservation

    /// The slot's encoder for this media request, or its typed refusal, in
    /// this order: media no Muse Glimmer slot takes (`checkMediaKinds`), a
    /// slot that serves no images (`unsupported_media`; the reason rides the
    /// error's description and this Mac's log, never the wire), then where
    /// the request puts its images (`checkPlacement`).
    static func servingEncoder(
        service: MuseGlimmerImageService?, request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared, modelID: String
    ) throws -> MuseGlimmerImageEncoder {
        try checkMediaKinds(request, modelID: modelID)
        guard let service else { throw refused(modelID, .encoderUnavailable) }
        if let refusal = service.refusal { throw refused(modelID, refusal) }
        guard let encoder = service.encoder else { throw refused(modelID, .encoderUnavailable) }
        try checkPlacement(request, prepared: prepared)
        return encoder
    }

    /// Video is `unsupported_media` until the SDK takes it; audio is refused
    /// as on every path without an audio tower.
    static func checkMediaKinds(_ request: OpenAIChatCompletionRequest, modelID: String) throws {
        if MediaIngest.hasVideo(request) { throw refused(modelID, .video) }
        try MediaIngest.rejectUnsupportedAudio(request)
    }

    /// Images go in user messages only (`invalid_media` otherwise), and a
    /// required or named tool choice is refused as on the generic media
    /// path: forced calls with images are not advertised
    /// (`native_media_tools`).
    static func checkPlacement(
        _ request: OpenAIChatCompletionRequest, prepared: ToolChoicePromptPolicy.Prepared
    ) throws {
        for message in prepared.messages where message.role != .user {
            guard case .parts(let parts) = message.content else { continue }
            if parts.contains(where: isImage) { throw nonUserImage }
        }
        guard prepared.mode == .auto || prepared.mode == .none else {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "inference-enforced tool_choice is not supported for multimodal requests",
                refusal: .unsupportedForcedToolChoice)
        }
    }

    static func refused(_ modelID: String, _ refusal: MuseGlimmerVisionPolicy.Refusal)
        -> MultiModelBatchSchedulerEngineError {
        .mediaUnsupportedByModel(modelID, reason: refusal.reason)
    }

    static let nonUserImage = MultiModelBatchSchedulerEngineError.multimodalRejected(
        "multimodal_rejected: Muse Glimmer takes images in user messages only")

    static let unsupportedPart = MultiModelBatchSchedulerEngineError.multimodalRejected(
        "multimodal_rejected: Muse Glimmer takes text and image parts only")

    static let promptAlignment = MultiModelBatchSchedulerEngineError.multimodalRejected(
        "multimodal_rejected: the image message did not render as its text")

    private static func isImage(_ part: OpenAIContentPart) -> Bool {
        if case .imageURL = part { return true }
        return false
    }

    // MARK: Prompt

    /// The text route's template input (`ProviderPromptContractPipeline
    /// .templateInput`) with each user message that carries images given back
    /// its parts: text parts as they are and each image as the template's
    /// `{"type": "image"}`. The template concatenates text parts with no
    /// separator, as the text route joins them, so the render is the text
    /// render with one `<|patch|>` at each image. A message the normalization
    /// changed is refused rather than rendered from unnormalized text.
    static func templateInput(
        prepared: ToolChoicePromptPolicy.Prepared, request: OpenAIChatCompletionRequest,
        modelType: String?, templateControls: ChatTemplateControls
    ) throws -> ProviderPromptContractPipeline.NormalizedInput {
        let text = try ProviderPromptContractPipeline.templateInput(
            prepared: prepared, request: request, modelType: modelType, templateControls: templateControls)
        guard text.messages.count == prepared.messages.count else { throw promptAlignment }
        var messages = text.messages
        for (index, message) in prepared.messages.enumerated() {
            guard case .parts(let parts) = message.content, parts.contains(where: isImage) else { continue }
            guard message.role == .user else { throw nonUserImage }
            var rendered: [[String: any Sendable]] = []
            var joined = ""
            for part in parts {
                switch part {
                case .text(let value):
                    rendered.append(["type": "text", "text": value])
                    joined += value
                case .imageURL:
                    rendered.append(["type": "image"])
                case .videoURL:
                    throw MuseGlimmerImageError.unsupportedMedia("video")
                case .inputAudio:
                    throw unsupportedPart
                case .unsupported:
                    continue
                }
            }
            guard messages[index]["content"] as? String == joined else { throw promptAlignment }
            messages[index]["content"] = rendered
        }
        return .init(messages: messages, tools: text.tools, additionalContext: text.additionalContext)
    }

    /// The rendered prompt's tokens, with one `<|patch|>` per image. Never
    /// through the tokenizer's prompt cache: an image prompt is not text.
    static func tokenize(
        prepared: ToolChoicePromptPolicy.Prepared, request: OpenAIChatCompletionRequest,
        tokenizer: any MLXLMCommon.Tokenizer, modelType: String?, templateControls: ChatTemplateControls
    ) throws -> [Int] {
        let input = try templateInput(
            prepared: prepared, request: request, modelType: modelType, templateControls: templateControls)
        return try tokenizer.applyChatTemplate(
            messages: input.messages, tools: input.tools, additionalContext: input.additionalContext)
    }

    // MARK: Decode and grids

    /// The request's images in prompt order, decoded under `MediaIngest`'s
    /// limits from the messages the template renders.
    static func decodeImages(
        prepared: ToolChoicePromptPolicy.Prepared, request: OpenAIChatCompletionRequest,
        modelType: String?, templateControls: ChatTemplateControls
    ) async throws -> [CIImage] {
        var rendered = request
        rendered.messages = prepared.messages
        let input = try await MediaIngest.buildUserInput(
            from: rendered, templateControls: templateControls, modelType: modelType)
        return try input.images.map { try $0.asCIImage() }
    }

    /// Each image's grid from its oriented extent, with the rounding the
    /// SDK's preprocessing applies to the same extent.
    static func grids(for images: [CIImage]) throws -> [Grid] {
        try images.map {
            try MuseGlimmerImageGeometry.grid(
                sourceHeight: Int($0.extent.height.rounded()), sourceWidth: Int($0.extent.width.rounded()))
        }
    }

    // MARK: Submission

    struct Prepared {
        let submission: EngineV2VisionPrefill.PreparedSubmission
        let grids: [Grid]
    }

    /// Expands the placeholders and evaluates each image's features, one image
    /// at a time. Placeholders and grids are checked before the first image is
    /// encoded; `checkpoint` (cancellation, the first-content deadline) runs
    /// before each image.
    static func submission(
        promptTokens: [Int], images: [CIImage], grids: [Grid],
        features: (CIImage, Grid) throws -> MLXArray, checkpoint: () throws -> Void
    ) throws -> Prepared {
        guard images.count == grids.count else { throw MuseGlimmerImageError.placeholders("grids") }
        let expanded = try MuseGlimmerImagePrompt.expand(promptTokens: promptTokens, grids: grids)
        var embeddings: [MLXArray] = []
        embeddings.reserveCapacity(images.count)
        for (image, grid) in zip(images, grids) {
            try checkpoint()
            embeddings.append(try features(image, grid))
        }
        try checkpoint()
        return Prepared(
            submission: .init(
                promptTokens: expanded.tokens, spans: expanded.spans, embeddings: embeddings,
                attention: .causal, positionState: nil, mediaKind: .image),
            grids: grids)
    }

    /// The encoder's features for one image: upstream's preprocessing, then
    /// the stack. The grid preprocessing picks must be the one the prompt was
    /// expanded with.
    static func features(encoder: MuseGlimmerImageEncoder, image: CIImage, grid: Grid) throws -> MLXArray {
        let (pixels, actual) = try MuseGlimmerImageEncoder.preprocess(image: image)
        guard actual == grid else { throw MuseGlimmerImageError.geometry("preprocessed grid") }
        return try encoder.features(pixels: pixels, grid: grid)
    }

    /// The whole preparation for a serving slot: prompt, decode, grids,
    /// expansion, then the tower image by image.
    static func prepare(
        prepared: ToolChoicePromptPolicy.Prepared, request: OpenAIChatCompletionRequest,
        tokenizer: any MLXLMCommon.Tokenizer, modelType: String?, templateControls: ChatTemplateControls,
        encoder: MuseGlimmerImageEncoder, checkpoint: () throws -> Void
    ) async throws -> Prepared {
        let promptTokens = try tokenize(
            prepared: prepared, request: request, tokenizer: tokenizer, modelType: modelType,
            templateControls: templateControls)
        try checkpoint()
        let images = try await decodeImages(
            prepared: prepared, request: request, modelType: modelType, templateControls: templateControls)
        try checkpoint()
        return try submission(
            promptTokens: promptTokens, images: images, grids: try grids(for: images),
            features: { try features(encoder: encoder, image: $0, grid: $1) }, checkpoint: checkpoint)
    }

    // MARK: Errors

    /// The 400 for a refusal of the request's own media; nil for any other
    /// throw. Messages are fixed text: the SDK's carry sizes and counts.
    static func clientFault(for error: Error, modelID: String) -> MultiModelBatchSchedulerEngineError? {
        guard let imageError = error as? MuseGlimmerImageError else { return nil }
        switch imageError {
        case .geometry:
            return .multimodalRejected(
                "multimodal_rejected: an image's size is outside what Muse Glimmer's processor takes")
        case .placeholders:
            return .multimodalRejected(
                "multimodal_rejected: the prompt's image placeholders do not match the request's images")
        case .unsupportedMedia:
            return refused(modelID, .video)
        case .identity, .missing, .unexpected, .layout, .dtype:
            // Load-time artifact faults; never a property of one request.
            return nil
        }
    }
}
