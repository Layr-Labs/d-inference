// Copyright © 2026 Eigen Labs.
//
// Media ingest for multimodal (image/video) requests.
//
// Everything between an OpenAI request's inline `data:` media parts and a
// model-ready `UserInput`: decode (CIImage / memory-backed AVFoundation assets),
// decompression-bomb caps (per-image + per-request pixels, byte/second/
// count limits), memory projections for the vision gate
// (`projectedDecodeBytes` / `projectedKVTokens`), and media classification
// (`hasMedia` / `hasVideo`).
//
// Extracted from the legacy `VLMRequestInference` when its non-batched
// prepare→generate stream path died with the legacy engine (v0.7.5
// one-engine). Consumers: `EngineV2VisionPrefill.buildUserInput` (the v2
// media prefill), `MultiModelBatchSchedulerEngine.streamChatCompletion`
// (routing + vision-gate reservations), and the error mappers (MediaError
// → 4xx).

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Jinja
import MLXLMCommon
import MLXLMServer
import MLXVLM

/// Namespace for media ingest: decode, caps, validation, projections.
/// Static helpers; holds no state.
public enum MediaIngest {

    /// Remove plaintext video files left by pre-fix providers that exited
    /// before their `defer` cleanup ran. Production calls this after acquiring
    /// the single-instance lock, so no live provider can still own a matching
    /// file. The exact UUID-shaped legacy name avoids touching unrelated temp
    /// files; non-regular files are left alone.
    static func purgeLegacyVideoTempFiles(
        in directory: URL = FileManager.default.temporaryDirectory
    ) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
        else { return }

        for url in entries where isLegacyVideoTempFileName(url.lastPathComponent) {
            guard let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func isLegacyVideoTempFileName(_ name: String) -> Bool {
        let prefix = "vlm-"
        let suffix = ".mp4"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let uuidStart = name.index(name.startIndex, offsetBy: prefix.count)
        let uuidEnd = name.index(name.endIndex, offsetBy: -suffix.count)
        return UUID(uuidString: String(name[uuidStart..<uuidEnd])) != nil
    }

    /// Errors surfaced while decoding inline media from a request. These
    /// finish the stream via `continuation.finish(throwing:)` so the
    /// status mapper can turn them into a 4xx for the caller.
    ///
    /// Conforms to `LocalizedError` for in-process classification and tests.
    /// Request-derived descriptions must never cross an outbound logging,
    /// telemetry, or protocol boundary; those surfaces use `InferenceFailure`.
    public enum MediaError: Error, CustomStringConvertible, LocalizedError {
        case malformedDataURI(String)
        case base64DecodeFailed
        case percentDecodeFailed
        case imageDecodeFailed
        case invalidURL(String)
        case mediaTooLarge(String)
        /// Well-formed media of a kind, encoding or arrangement that this
        /// route does not serve (fixed text naming the rule, never request
        /// content). Failure code `unsupported_media`.
        case unsupportedMedia(String)

        public var description: String {
            switch self {
            case .malformedDataURI(let detail):
                return "malformed data: URI (\(detail))"
            case .base64DecodeFailed:
                return "failed to base64-decode data: URI payload"
            case .percentDecodeFailed:
                return "failed to percent-decode data: URI payload"
            case .imageDecodeFailed:
                return "failed to decode image data into a CIImage"
            case .invalidURL(let uri):
                // Actionable for clients porting from OpenAI/OpenRouter: our wire
                // format is identical, but media must be an inline base64 data:
                // URI — remote/file URLs are rejected for E2E + SSRF safety.
                let shown = uri.count > 200 ? String(uri.prefix(200)) + "…" : uri
                return "media must be sent as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\") on this end-to-end-encrypted endpoint; remote http(s):// and file:// URLs are rejected. Got: \(shown)"
            case .mediaTooLarge(let detail):
                return "inline media exceeds a decode limit (\(detail))"
            case .unsupportedMedia(let detail):
                return "inline media is not supported here (\(detail))"
            }
        }

        public var errorDescription: String? { description }
    }

    // MARK: - Routing

    /// Reject audio before model acquisition, template rendering, or media decoding.
    /// Only provider-owned architecture metadata can select native MiMo dispatch;
    /// this is not a loaded-profile or media admission proof. Generic callers
    /// omit the type and always refuse audio. The native bridge checks its real
    /// issued audio binding again after acquisition.
    static func rejectUnsupportedAudio(
        _ request: OpenAIChatCompletionRequest, modelType: String? = nil
    ) throws {
        if modelType == "mimo_v2" { return }
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                if case .inputAudio = part { throw unsupportedAudioError }
            }
        }
    }

    private static var unsupportedAudioError: MultiModelBatchSchedulerEngineError {
        .multimodalRejected("multimodal_rejected: input_audio is not supported")
    }

    /// True when any message carries image, video or audio. Audio uses only
    /// the separately issued native path, never this generic visual producer.
    /// Used by the engine to decide between the batched (text) path and
    /// this non-batched vision path.
    public static func hasMedia(_ request: OpenAIChatCompletionRequest) -> Bool {
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                switch part {
                case .imageURL, .videoURL, .inputAudio:
                    return true
                case .text, .unsupported:
                    continue
                }
            }
        }
        return false
    }

    /// True when an image or video part sits in a system, assistant or tool
    /// message. Such media is rendered where the model's chat template renders
    /// it (`buildUserInput(keepNonUserMedia:)`); a request without it takes the
    /// user-media path unchanged.
    public static func hasNonUserMedia(_ request: OpenAIChatCompletionRequest) -> Bool {
        request.messages.contains { message in
            guard message.role != .user, case .parts(let parts) = message.content else { return false }
            return parts.contains { part in
                switch part {
                case .imageURL, .videoURL: true
                case .text, .inputAudio, .unsupported: false
                }
            }
        }
    }

    /// `DARKBLOOM_MEDIA_ON_EVERY_ROLE`: media in a system, assistant or tool
    /// message is kept and rendered where the model's chat template renders it,
    /// by default; `0`, `off`, `false` or `no` restores keeping only user-message
    /// media (the others refused, or dropped beside a user image). Read once per
    /// process.
    static let everyRoleEnvironmentKey = "DARKBLOOM_MEDIA_ON_EVERY_ROLE"
    static let everyRoleEnabled = !ToolOutputLeniencySwitch.isOff(
        ProcessInfo.processInfo.environment[everyRoleEnvironmentKey])

    /// Whether `request`'s media outside user messages is kept and placed by
    /// the chat template: the switch is on and such media exists. False for
    /// every request whose media is only in user messages.
    static func placesNonUserMedia(_ request: OpenAIChatCompletionRequest) -> Bool {
        everyRoleEnabled && hasNonUserMedia(request)
    }

    /// The messages whose image and video parts the vision ingest keeps, in
    /// request order: every message when `placesNonUserMedia(request)`, else
    /// the user messages. Scans that must agree with the built input read these.
    static func messagesKeepingMedia(of request: OpenAIChatCompletionRequest) -> [OpenAIChatMessage] {
        placesNonUserMedia(request) ? request.messages : request.messages.filter { $0.role == .user }
    }

    /// Classification only; the actual loaded native audio profile is still
    /// required. Generic text/vision/diffusion paths must not drop this part.
    public static func hasAudio(_ request: OpenAIChatCompletionRequest) -> Bool {
        request.messages.contains { message in
            guard case .parts(let parts) = message.content else { return false }
            return parts.contains { if case .inputAudio = $0 { return true }; return false }
        }
    }

    /// True when any message carries a video content part. Since v0.7.5
    /// this no longer gates routing (video prefills through engine_v2 like
    /// images — `EngineV2VisionPrefill` pairs the up-to-32 per-frame
    /// placeholder blocks with per-frame tower features); it remains a pure
    /// classification helper for reservations, telemetry media-kind
    /// tagging, and tests.
    public static func hasVideo(_ request: OpenAIChatCompletionRequest) -> Bool {
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                if case .videoURL = part { return true }
            }
        }
        return false
    }

    /// The max output-token bound this request will actually generate with —
    /// the consumer's `max_tokens` if set, else the model's default. The KV
    /// reservation for the vision path sizes the generation cache from this,
    /// matching what the engine's translation feeds the generator.
    static func resolveMaxOutputTokens(
        for request: OpenAIChatCompletionRequest, defaultMaxTokens: Int
    ) -> Int {
        request.maxTokens ?? defaultMaxTokens
    }

    /// Conservative per-image (and per-video-frame) soft-token allotment for the
    /// KV-token estimate. Gemma-4 pools every image/frame to a FIXED soft-token
    /// block (`image_seq_length`, default 280) regardless of resolution and wraps
    /// it with 2 `boi`/`eoi` delimiter tokens; other VLMs run higher. 1024 is a
    /// generous model-agnostic upper bound that over-covers that whole
    /// `boi + soft_tokens + eoi` per-frame span, and is still bounded by the
    /// model's context window via the clamp in `projectedKVTokens`.
    static let visionTokensPerImage = 1024
    /// Max frames Gemma-4 samples from a single video. Mirrors `maxFrames: 32`
    /// in the Gemma4 video processor (`Gemma4Processor.prepare`), which samples
    /// up to 32 frames spread uniformly across the clip and expands EACH into its
    /// own image-like `boi + soft_token*image_seq_length + eoi` block. A video's
    /// KV footprint therefore scales with the sampled frame count — it is NOT a
    /// flat per-video allotment.
    static let maxVideoFramesSampled = 32
    /// A video reserves KV for EVERY sampled frame: the processor emits one
    /// image-like soft-token block per sampled frame (up to
    /// `maxVideoFramesSampled`), so the worst case is `maxVideoFramesSampled ×
    /// visionTokensPerImage`. Because `visionTokensPerImage` already over-covers
    /// a single frame's soft tokens AND its `boi`/`eoi` delimiters, this product
    /// bounds the full `32 × (soft tokens + delimiters)` span the prefill
    /// actually writes into KV. The previous flat 4096 covered only ~4 frames and
    /// badly under-reserved a full clip (Gemma-4's real worst case is
    /// 32 × (280 + 2) = 9024 soft tokens). Still clamped to the model's context
    /// window via the clamp in `projectedKVTokens`, so over-reservation never
    /// projects past a request the context could actually hold.
    static let visionTokensPerVideo = maxVideoFramesSampled * visionTokensPerImage
    /// The image soft tokens `projectedKVTokens` reserves: `visionTokensPerImage`
    /// each, except that a request past its model's image budget holds at most
    /// the visual tokens of its shares (one per 32x32 px): the budget's pixels,
    /// or each image's `minImageShare` once an override above 64 images floors
    /// the share. It reserves those plus a quarter (slack that covers the two
    /// delimiters an image); never more than the per-image charge.
    static func projectedImageTokens(_ images: Int, model: String?) -> Int {
        let (perImage, overflow) = images.multipliedReportingOverflow(by: visionTokensPerImage)
        let charge = overflow ? Int.max : perImage
        guard let budget = imageBudget(forModel: model), images > budget.images else { return charge }
        let (floored, floorOverflow) = images.multipliedReportingOverflow(by: minImageShare)
        let pixels = floorOverflow ? Int.max : max(budget.pixels, floored)
        return min(charge, pixels / 1_024 / 4 * 5)
    }

    /// Conservative chars→tokens divisor for the text prompt estimate. Real
    /// tokenizers average ~4 chars/token; dividing by 3 OVER-estimates the token
    /// count (the safe direction for a reservation).
    static let textCharsPerToken = 3

    /// Conservative upper bound on the number of tokens the vision generation's
    /// KV cache will hold: prompt text + image/video soft tokens + generated
    /// output. The vision path bypasses the batched `submitTokenized` reservation
    /// (which reserves `promptTokenCount + maxTokens`), so without this the cap
    /// would charge only the output tokens and badly under-count — a single image
    /// expands to hundreds of vision tokens that all occupy KV.
    ///
    /// Prompt + vision is clamped to `contextLength` when known: the model can't
    /// attend beyond its context window, so the cache never holds more than that
    /// many input tokens. Output tokens are added on top (the generation extends
    /// past the prompt up to `maxOutputTokens`), mirroring the batched path's
    /// `promptTokenCount + maxTokens`. Saturating; never traps.
    static func projectedKVTokens(
        _ request: OpenAIChatCompletionRequest,
        defaultMaxTokens: Int,
        contextLength: Int
    ) -> Int {
        var promptTokens = 0
        var images = 0
        func add(_ n: Int) {
            let (s, o) = promptTokens.addingReportingOverflow(max(0, n))
            promptTokens = o ? Int.max : s
        }
        for message in request.messages {
            switch message.content {
            case .text(let s):
                add(s.utf8.count / textCharsPerToken)
            case .parts(let parts):
                for part in parts {
                    switch part {
                    case .text(let s): add(s.utf8.count / textCharsPerToken)
                    case .imageURL: images += 1
                    case .videoURL: add(visionTokensPerVideo)
                    // No finite reservation exists for unsupported audio.
                    // Native MiMo uses its separately sealed plan, not this projection.
                    case .inputAudio: return .max
                    case .unsupported: continue
                    }
                }
            case .null:
                continue
            }
        }
        add(projectedImageTokens(images, model: request.model))
        // The KV cache can't hold more input tokens than the context window.
        if contextLength > 0 { promptTokens = min(promptTokens, contextLength) }
        let maxOutput = max(0, resolveMaxOutputTokens(for: request, defaultMaxTokens: defaultMaxTokens))
        let (total, overflow) = promptTokens.addingReportingOverflow(maxOutput)
        return overflow ? Int.max : total
    }

    // MARK: - UserInput construction

    /// Build a model-agnostic `UserInput` from the OpenAI request, decoding any
    /// inline image/video content parts. Inline MP4s are retained in memory by
    /// their `UserInput.Video` values for the lifetime of the returned input.
    /// Without `maxImagesPerRequest`, the image cap is the request's model's
    /// (`imageCap(forModel:)`). Serving callers pass
    /// `keepNonUserMedia: placesNonUserMedia(request)`, so the scans that read
    /// `messagesKeepingMedia(of:)` agree with the input built here.
    static func buildUserInput(
        from request: OpenAIChatCompletionRequest,
        templateControls: ChatTemplateControls = .init(),
        tools: [ToolSpec]? = nil,
        preserveTemplateFields: Bool = false,
        keepNonUserMedia: Bool = false,
        modelType: String? = nil,
        maxImagePixels: Int = Self.maxImagePixels,
        maxRequestImagePixels: Int = Self.maxRequestImagePixels,
        maxImagesPerRequest: Int? = nil,
        maxVideosPerRequest: Int = Self.maxVideosPerRequest,
        maxRequestVideoFramePixels: Int = Self.maxRequestVideoFramePixels
    ) async throws -> UserInput {
        let maxImagesPerRequest = maxImagesPerRequest ?? imageCap(forModel: request.model)
        let imagePixelTarget = imagePixelTarget(for: request)
        try rejectUnsupportedAudio(request)
        let tools = ChatTemplateFixes.normalizeToolMetadata(
            tools, context: .init(modelId: request.model, modelType: modelType))
        try ReasoningEffortPolicy.validate(request, controls: templateControls, modelType: modelType)
        let additionalContext = MultiModelBatchSchedulerEngine.templateAdditionalContext(
            for: request, controls: templateControls, modelType: modelType, hasMedia: true)
        var chatMessages: [Chat.Message] = []
        let inklingParts = Inkling2PromptContract.applies(modelType: modelType)
        // The native Inkling and diffusion Gemma templates keep tool-result media
        // even on the legacy user-media path.
        let retainToolMedia = preserveTemplateFields && (modelType == "diffusion_gemma" || inklingParts)
        // When enabled, the template places each role's media. Vision prefill
        // refuses requests whose template rejects media or omits its placeholder.
        let everyRole = keepNonUserMedia && hasNonUserMedia(request)
        var totalPixels = 0
        var totalVideoPixels = 0
        var imageCount = 0
        var videoCount = 0
        for message in request.messages {
            let (text, images, videos) = try await parts(
                from: message.content, totalPixels: &totalPixels,
                totalVideoPixels: &totalVideoPixels,
                imageCount: &imageCount, videoCount: &videoCount,
                maxImagePixels: maxImagePixels,
                maxRequestImagePixels: maxRequestImagePixels,
                maxImagesPerRequest: maxImagesPerRequest,
                maxVideosPerRequest: maxVideosPerRequest,
                maxRequestVideoFramePixels: maxRequestVideoFramePixels)
            switch message.role {
            case .user:
                chatMessages.append(.user(text, images: images, videos: videos))
            case .system:
                chatMessages.append(everyRole
                    ? .init(role: .system, content: text, images: images, videos: videos) : .system(text))
            case .assistant:
                chatMessages.append(everyRole
                    ? .init(role: .assistant, content: text, images: images, videos: videos) : .assistant(text))
            case .tool:
                let keep = retainToolMedia || everyRole
                chatMessages.append(.init(role: .tool, content: text,
                    images: keep ? images : [], videos: keep ? videos : []))
            }
            if preserveTemplateFields {
                chatMessages[chatMessages.count - 1].templateFields = message.templateMessageDict()
            }
        }
        if preserveTemplateFields || everyRole {
            // Preserve the interleaved order of the validated native Qwen4
            // request, or of media outside user messages.
            // Only symbolic placeholders enter the template; decoded media
            // remains owned by UserInput, never rendered as URLs/base64 text.
            let generator = Qwen3VLMessageGenerator()
            let messages = try zip(request.messages, chatMessages).map { original, decoded in
                // Inkling preserves strings and reasoning fields exactly as its text
                // path does. Other native templates use the Qwen message generator.
                var message = preserveTemplateFields && !inklingParts
                    ? generator.generate(messages: [decoded])[0] : original.templateMessageDict()
                if original.role == .user || (retainToolMedia && original.role == .tool) || everyRole,
                    case .parts(let parts) = original.content {
                    message["content"] = try parts.compactMap { part -> [String: String]? in
                        switch part {
                        case .text(let text): return ["type": "text", "text": text]
                        case .imageURL: return ["type": "image"]
                        case .videoURL: return ["type": "video"]
                        case .inputAudio: throw unsupportedAudioError
                        case .unsupported: return nil
                        }
                    }
                } else if inklingParts, let parts = Inkling2PromptContract.textParts(of: original) {
                    // Inkling renders every role's parts as blocks, as its
                    // text requests do; system and assistant messages carry
                    // no media (`EngineV2VisionPrefill.validateInkling2ImageRoles`).
                    message["content"] = parts
                }
                return message
            }
            // A family trained on Transformers' rendering takes earlier calls'
            // arguments and its tool declarations as sent, as its text
            // requests do (`TemplateJSONOrder`).
            let callerJSON = TemplateJSONOrder.rendersCallerArguments(modelType: modelType)
            let rendered = callerJSON ? TemplateJSONOrder.orderingToolCalls(in: messages, request: request) : messages
            var renderedTools = tools
            var renderedContext = additionalContext
            if callerJSON, let tools,
                let declared = TemplateJSONOrder.declaredTools(tools, evidence: templateControls.templateJSON) {
                var context = additionalContext ?? [:]
                context["tools"] = Jinja.Value.array(declared)
                renderedTools = nil
                renderedContext = context
            }
            var input = UserInput(messages: rendered,
                images: chatMessages.flatMap(\.images), videos: chatMessages.flatMap(\.videos),
                tools: renderedTools, additionalContext: renderedContext)
            input.processing.maxPixels = imagePixelTarget
            return input
        }
        var input = UserInput(
            chat: chatMessages,
            tools: tools,
            additionalContext: additionalContext)
        // Past the model's image budget the processor sizes every image to its
        // share (one resize to its own grid, as for any image); the source-pixel
        // caps above are unchanged.
        input.processing.maxPixels = imagePixelTarget
        return input
    }


    /// Split a message's content into the concatenated text plus decoded
    /// image/video media. Unsupported roles drop media at the call site, but
    /// the native Diffusion path also retains tool-result assets. We still
    /// decode here so a malformed inline payload fails loudly
    /// rather than being silently ignored.
    private static func parts(
        from content: OpenAIMessageContent,
        totalPixels: inout Int,
        totalVideoPixels: inout Int,
        imageCount: inout Int,
        videoCount: inout Int,
        maxImagePixels: Int,
        maxRequestImagePixels: Int,
        maxImagesPerRequest: Int,
        maxVideosPerRequest: Int,
        maxRequestVideoFramePixels: Int
    ) async throws -> (text: String, images: [UserInput.Image], videos: [UserInput.Video]) {
        switch content {
        case .text(let string):
            return (string, [], [])
        case .null:
            return ("", [], [])
        case .parts(let parts):
            var text = ""
            var images: [UserInput.Image] = []
            var videos: [UserInput.Video] = []
            for part in parts {
                switch part {
                case .text(let string):
                    text += string
                case .imageURL(let uri):
                    guard uri.hasPrefix("data:") else {
                        throw MediaError.invalidURL(uri)
                    }
                    // Per-request image COUNT, not just pixels. The aggregate
                    // pixel cap bounds decode RAM but not the image count: the
                    // processor resizes each image down, so 384 MP of input can
                    // still be dozens of images, and the vision tower now runs
                    // once PER IMAGE under the model container's lock
                    // (EngineV2VisionTowerRun). Without this a legal request
                    // could hold that lock for minutes before the token budget
                    // rejected it at submit. Mirrors maxVideosPerRequest.
                    imageCount += 1
                    guard imageCount <= maxImagesPerRequest else {
                        throw MediaError.mediaTooLarge(
                            "request has \(imageCount) images; cap is \(maxImagesPerRequest)")
                    }
                    let data = try dataFromDataURI(uri)
                    // Charge the request-wide aggregate from the HEADER pixel count
                    // BEFORE decoding — CIImage(data:) is the allocation we're
                    // guarding against, so an over-aggregate request (with prior
                    // images already retained) must be rejected before this image's
                    // raster is ever materialized. Overflow-safe (matches
                    // imagePixelCount). The header read is O(header), ~0 RSS.
                    //
                    // When the header is unreadable (imagePixelCount nil), charge
                    // 0 here and let decodeImageData enforce the per-image cap on
                    // the realized extent; the post-decode extent is then folded
                    // into the aggregate below so a nil-header image still counts.
                    let headerPixels = imagePixelCount(data) ?? 0
                    let (preSum, preOverflow) =
                        totalPixels.addingReportingOverflow(headerPixels)
                    let projectedTotal = preOverflow ? Int.max : preSum
                    guard projectedTotal <= maxRequestImagePixels else {
                        throw MediaError.mediaTooLarge(
                            "request images total \(projectedTotal) px; aggregate cap is "
                                + "\(maxRequestImagePixels) px")
                    }
                    // Within aggregate: now decode (per-image cap + extent backstop).
                    let image = try decodeImageData(data, maxImagePixels: maxImagePixels)
                    // Reconcile the aggregate with the REALIZED extent: when the
                    // header was readable both are equal; when it was nil the
                    // extent is the real charge. Re-check so a nil-header image
                    // can't slip an over-aggregate raster through.
                    if case .ciImage(let ci) = image.source {
                        let realized = safeExtentPixels(ci.extent)
                        let charge = max(headerPixels, realized)
                        let (sum, overflow) =
                            totalPixels.addingReportingOverflow(charge)
                        totalPixels = overflow ? Int.max : sum
                        guard totalPixels <= maxRequestImagePixels else {
                            throw MediaError.mediaTooLarge(
                                "request images total \(totalPixels) px; aggregate cap is "
                                    + "\(maxRequestImagePixels) px")
                        }
                    }
                    images.append(image)
                case .videoURL(let uri):
                    // Per-request video caps: count + summed per-frame pixels.
                    // The model samples up to N frames PER video, so a per-video
                    // cap alone doesn't bound many-tiny-videos amplification.
                    videoCount += 1
                    guard videoCount <= maxVideosPerRequest else {
                        throw MediaError.mediaTooLarge(
                            "request has \(videoCount) videos; cap is \(maxVideosPerRequest)")
                    }
                    let decoded = try await decodeVideo(uri)
                    let (sum, overflow) =
                        totalVideoPixels.addingReportingOverflow(decoded.framePixels)
                    totalVideoPixels = overflow ? Int.max : sum
                    guard totalVideoPixels <= maxRequestVideoFramePixels else {
                        throw MediaError.mediaTooLarge(
                            "request video frames total \(totalVideoPixels) px; aggregate cap is "
                                + "\(maxRequestVideoFramePixels) px")
                    }
                    videos.append(decoded.video)
                case .inputAudio:
                    throw unsupportedAudioError
                case .unsupported:
                    continue
                }
            }
            return (text, images, videos)
        }
    }

    // MARK: - Media limits (decompression-bomb guard)

    // `CIImage(data:)` eagerly rasterizes (W*H*4 bytes) and has no scaled-decode
    // for PNG, so a tiny highly-compressed "bomb" (a uniform 40000x40000 PNG is
    // ~5 MB on the wire — well under the 32 MiB WS frame cap) explodes on decode.
    // Measured on M-series hardware: even the real resample-to-448 provider path
    // peaks at 1.78 GB for a 16000^2 input and 5.73 GB at 32000^2, all *before*
    // any KV/token/load admission runs. These caps reject such inputs from the
    // format header, before the raster is ever allocated. Defaults are generous
    // for genuine media (a 100 MP camera frame is 100 Mpx) yet bound the
    // otherwise-unbounded allocation; all are env-tunable.

    /// Per-image pixel ceiling (width × height). Rejected from the header.
    public static let maxImagePixels = resolveMaxPixels(
        env: "DARKBLOOM_MAX_IMAGE_MEGAPIXELS", defaultMegapixels: 100)

    /// Aggregate pixel ceiling across all image parts in one request — bounds
    /// the "pack many max-size images into one frame" amplification.
    public static let maxRequestImagePixels = resolveMaxPixels(
        env: "DARKBLOOM_MAX_REQUEST_IMAGE_MEGAPIXELS", defaultMegapixels: 384)

    /// Per-part decoded-byte ceiling for a `data:` payload (image or video).
    /// Bounds the inline-video in-memory asset and its decode buffers.
    public static let maxMediaDecodedBytes = resolveMaxBytes(
        env: "DARKBLOOM_MAX_MEDIA_MIB", defaultMiB: 25)

    /// Inline-video duration ceiling (seconds) — bounds how many frames the
    /// model samples/decodes from one clip. A video's per-frame pixels are
    /// capped at ``maxImagePixels`` (a frame is an image).
    public static let maxVideoDurationSeconds = resolveMaxSeconds(
        env: "DARKBLOOM_MAX_VIDEO_SECONDS", defaultSeconds: 600)

    /// Max inline image parts per request — bounds the number of sequential
    /// vision-tower forward passes one request can drive (the tower runs once
    /// per image) independently of their pixel count, which the processor
    /// resizes away. The image analog of `maxVideosPerRequest`. A model in
    /// `modelMaxImagesPerRequest` has its own default (`imageCap(forModel:)`).
    public static let maxImagesPerRequest = resolveMaxCount(
        env: maxImagesEnvironmentKey, defaultCount: defaultMaxImagesPerRequest)

    static let maxImagesEnvironmentKey = "DARKBLOOM_MAX_IMAGES_PER_REQUEST"
    static let defaultMaxImagesPerRequest = 16

    /// Image-count defaults above 16, by served model id: the Qwen3VL-family
    /// builds, whose per-request image budget (`modelImageBudget`) holds a
    /// request past 16 images to at most 16,384 visual tokens however many
    /// images it carries. A release build of this change on an M5 Ultra, VGI
    /// video frames (~1280x720) at full size, time to first content: Qwen 3.8
    /// 27B 16 frames 9.3-9.6 s, 32 frames 9.8-10.0 s, 64 frames 11.4-11.5 s
    /// (16.0-16.4K prompt tokens); the 9B 4.5-4.7 s at 32 and 5.5 s at 64;
    /// `qwen3.5-35b-a3b` 4.8-6.6 s at 64 (Qwen 3.6 35B not run). Without the
    /// budget 64 frames took 41-44 s and 17-18 s (signed 0.10.13 with the cap
    /// lifted).
    /// Gemma 4 26B pools every image to 280 soft tokens, so its cost grows with
    /// the count alone (signed 0.10.13 on an M5 Ultra: 16 frames 2.5 s, 24
    /// frames 3.8 s, 32 frames 5.0-5.1 s to first content; ~2x on an M5 Max,
    /// ~4x on a Pro): it takes 24. Exact catalog ids; the pair's Qwen media path
    /// keeps its explicit 16, and Super keeps
    /// `NemotronSuperServingPolicy.maximumImages`. The coordinator condenses an
    /// image sequence to its own copy of these caps (darkbloom-platform
    /// `EIGENINFERENCE_IMAGE_SEQUENCE_MODELS`, 16 for every build until a release
    /// carrying these values is on the fleet); raise it there once it is.
    /// Inkling 2 Mini (`Inkling2ModelIdentity.servedModelIDs`) takes 64, not
    /// below its peers elsewhere, which publish no per-request image limit. It
    /// needs no image budget: it does not pool, but has one visual token per
    /// 40x40 px of the image as sent (a side above 4,096 px is scaled down), so the
    /// per-request 384 MP (`maxRequestImagePixels`) and per-image 100 MP
    /// (`maxImagePixels`) caps bound a request's visual tokens to about 240K
    /// (plus padding to the 40 px grid), and the prompt must still fit the
    /// context. The coordinator does not condense its image sequences.
    static let modelMaxImagesPerRequest: [String: Int] = [
        "gemma-4-26b-qat-4bit": 24,
        "Qwen3.5-9B": 64,
        "qwen3.5-35b-a3b": 64,
        "qwen3.6-35b-a3b-vl-mtp-mxfp8": 64,
        "EigenLabs/Qwen3.8-27B-4bit-mtp": 64,
        "thinkingmachines/Inkling-2-Mini": 64,
    ]

    /// The image cap for one request to `model`: the
    /// `DARKBLOOM_MAX_IMAGES_PER_REQUEST` override when set (every model), else
    /// the model's own default (`modelMaxImagesPerRequest`), else 16.
    static func imageCap(
        forModel model: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        resolveMaxCount(
            env: maxImagesEnvironmentKey,
            defaultCount: model.flatMap { modelMaxImagesPerRequest[$0] } ?? defaultMaxImagesPerRequest,
            environment: environment)
    }

    /// A per-request image budget: a request with more than `images` images
    /// has each image sized by the processor to at most `pixels / imageCount`
    /// pixels (`UserInput.Processing.maxPixels`) instead of its own per-image
    /// ceiling. Requests within `images` are untouched.
    struct ImageBudget: Equatable, Sendable {
        let images: Int
        let pixels: Int
    }

    /// The Qwen3VL-family builds' budget: 16 images of 1,024 visual tokens
    /// (32x32 px each), 16,777,216 px. The processor floors each side to its
    /// 32-px grid within the share, so past 16 images a request has at most
    /// 16,384 visual tokens: about what 16 video frames of ~1280x720 cost
    /// (~14.7K visual tokens), below the 20,480 that 16 images at the
    /// processor's own per-image ceiling (1,280 tokens) may already reach. It assumes the
    /// default `Qwen3VLProcessor` policy (`maxPixels` replaces the per-image
    /// ceiling); a build on checkpoint image bounds needs its own budget.
    static let qwenImageBudget = ImageBudget(images: 16, pixels: 16 * 1_048_576)

    /// Image budgets by served model id: the Qwen builds of
    /// `modelMaxImagesPerRequest`, whose cap of 64 rests on this budget.
    static let modelImageBudget: [String: ImageBudget] = [
        "Qwen3.5-9B": qwenImageBudget,
        "qwen3.5-35b-a3b": qwenImageBudget,
        "qwen3.6-35b-a3b-vl-mtp-mxfp8": qwenImageBudget,
        "EigenLabs/Qwen3.8-27B-4bit-mtp": qwenImageBudget,
    ]

    /// The image budget of `model`'s requests, if it has one.
    static func imageBudget(forModel model: String?) -> ImageBudget? {
        model.flatMap { modelImageBudget[$0] }
    }

    /// The pixels each image of `request` may keep: its model's budget shared
    /// by its images (every image part, as the cap counts) when they exceed the
    /// budget's count, else nil (the processor's own ceiling).
    static func imagePixelTarget(for request: OpenAIChatCompletionRequest) -> Int? {
        guard let budget = imageBudget(forModel: request.model) else { return nil }
        var imageCount = 0
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                if case .imageURL = part { imageCount += 1 }
            }
        }
        return imageCount > budget.images ? max(budget.pixels / imageCount, minImageShare) : nil
    }

    /// The fewest pixels a budgeted image keeps: one video frame's bound
    /// (Qwen3VLProcessor's `maxVideoFramePixels`, 512 x 512). Only an
    /// operator's override above 64 images reaches it; then video frames in the
    /// request stay unnarrowed and a 200:1 strip keeps a 32-px side.
    static let minImageShare = 262_144

    /// Max inline video parts per request — bounds the "many tiny valid MP4s"
    /// amplification (each video passes per-part checks, but the model samples
    /// up to N frames PER video, so aggregate frame/tensor work still explodes).
    public static let maxVideosPerRequest = resolveMaxCount(
        env: "DARKBLOOM_MAX_VIDEOS_PER_REQUEST", defaultCount: 8)

    /// Aggregate per-frame pixel ceiling summed across every video in a request
    /// (the video analog of `maxRequestImagePixels`).
    public static let maxRequestVideoFramePixels = resolveMaxPixels(
        env: "DARKBLOOM_MAX_REQUEST_VIDEO_FRAME_MEGAPIXELS", defaultMegapixels: 384)

    /// Resolve a megapixel limit from `env` (a positive megapixel count) or fall
    /// back to `defaultMegapixels`. Injectable environment for tests.
    static func resolveMaxPixels(
        env name: String, defaultMegapixels: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        if let raw = environment[name], let mp = Double(raw), mp > 0, mp.isFinite {
            // Clamp to Int.max WITHOUT `Int(Double(Int.max))`: that round-trip
            // rounds 2^63−1 up to 2^63, which is > Int.max, so `Int(...)` traps
            // (a single huge env override would crash the provider at static
            // init). `intMaxAsDouble` is exactly 2^63; anything ≥ it saturates.
            let scaled = mp * 1_000_000
            return scaled >= intMaxAsDouble ? Int.max : Int(scaled)
        }
        return defaultMegapixels * 1_000_000
    }

    /// `Double(Int.max)` rounded to the nearest representable Double — exactly
    /// 2^63 (one more than `Int.max`). Used as the saturation threshold for env
    /// clamps so a comparison `>= intMaxAsDouble` catches every value that would
    /// trap on `Int(_:)` conversion.
    static let intMaxAsDouble = Double(Int.max)

    /// Resolve a byte limit from `env` (a positive MiB count) or `defaultMiB`.
    static func resolveMaxBytes(
        env name: String, defaultMiB: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        if let raw = environment[name], let mib = Int(raw), mib > 0 {
            // Saturate instead of trapping: `mib * 1024 * 1024` overflows for a
            // large-but-parseable Int, which would crash the provider at static
            // init from a single bad byte-limit override.
            let (bytes, overflow) = mib.multipliedReportingOverflow(by: 1024 * 1024)
            return overflow ? Int.max : bytes
        }
        return defaultMiB * 1024 * 1024
    }

    /// Resolve a seconds limit from `env` (a positive number) or `defaultSeconds`.
    static func resolveMaxSeconds(
        env name: String, defaultSeconds: Double,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double {
        if let raw = environment[name], let s = Double(raw), s > 0, s.isFinite {
            return s
        }
        return defaultSeconds
    }

    /// Resolve a positive integer count from `env` or `defaultCount`.
    static func resolveMaxCount(
        env name: String, defaultCount: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        if let raw = environment[name], let n = Int(raw), n > 0 { return n }
        return defaultCount
    }

    /// Pixel count (width × height) read from the image's format **header only**
    /// — no raster decode (proven O(header): ~0 MB RSS even for a gigapixel
    /// bomb). Returns `nil` if ImageIO can't size the data (truncated/unknown
    /// format), in which case `CIImage(data:)` fails closed downstream.
    /// Decode-overhead multiplier over the raw RGBA raster (W*H*4). `CIImage`
    /// rasterization + the intermediate Swift `Data` in `MediaProcessing
    /// .asMLXArray` + the resampled MLX pixel-values tensor coexist briefly, so
    /// peak transient RAM is a few times the final raster. 4x is a conservative
    /// upper bound measured against the decode-bomb repro (16000^2 -> ~1.78 GB
    /// peak for a 256 MP = 1 GB raster ~= 1.7x; 4x leaves generous margin).
    static let decodeOverheadFactor = 4

    /// Projected PEAK unified-memory bytes the media decode of `request` will
    /// transiently consume, so the caller can RESERVE it against the 90% cap
    /// (GlobalKVCacheBudget) before rasterizing — these CIImage/Data buffers are
    /// NOT MLX arrays and are otherwise invisible to the cap. Estimated from
    /// HEADER pixel counts (no decode); when a header is unreadable the per-image
    /// cap is used as the worst case the media caps still admit.
    ///
    /// The estimate is clamped to the SAME ceilings `buildUserInput` enforces, so
    /// it can never exceed what a maximally-large *valid* request consumes:
    ///   • image pixels are summed but clamped to the aggregate image cap
    ///     (`maxRequestImagePixels`) — a single oversized image, or many
    ///     unreadable-header images, can't project past the request-wide image
    ///     ceiling validation guarantees;
    ///   • videos are charged the aggregate per-request video-frame cap ONCE if
    ///     any video is present — NOT per video. `buildUserInput` bounds the SUM
    ///     of all videos' frame pixels by `maxRequestVideoFramePixels`, so
    ///     charging it per-video would over-reserve by the video count and could
    ///     falsely 503 a valid multi-video request.
    /// Consequently an oversized/invalid request projects no more than a max
    /// valid one: on a saturated box both get a retryable 503 (and the invalid
    /// one resolves to its deterministic 400 once capacity frees), rather than
    /// the invalid request being singled out for a permanent 503.
    /// Saturating; never traps. Returns 0 for a request with no media.
    public static func projectedDecodeBytes(
        _ request: OpenAIChatCompletionRequest,
        maxImagePixels: Int = Self.maxImagePixels,
        maxRequestImagePixels: Int = Self.maxRequestImagePixels,
        maxRequestVideoFramePixels: Int = Self.maxRequestVideoFramePixels
    ) -> UInt64 {
        var imagePixels: UInt64 = 0
        var hasVideo = false
        func addImagePixels(_ p: Int) {
            let (s, o) = imagePixels.addingReportingOverflow(UInt64(max(0, p)))
            imagePixels = o ? .max : s
        }
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                switch part {
                case .imageURL(let uri):
                    // Header read is O(header), ~0 RSS; fall back to the per-image
                    // cap (the worst case the existing caps admit) if unreadable.
                    if let data = try? dataFromDataURI(uri) {
                        addImagePixels(imagePixelCount(data) ?? maxImagePixels)
                    } else {
                        addImagePixels(maxImagePixels)
                    }
                case .videoURL:
                    hasVideo = true
                // Do not advertise a zero-cost decode for unsupported audio.
                // Native MiMo uses its separately admitted decode policy.
                case .inputAudio:
                    return .max
                case .text, .unsupported:
                    continue
                }
            }
        }
        // Clamp images to the request-wide aggregate cap, then add the video
        // aggregate once. Both mirror buildUserInput's ceilings exactly.
        var pixels = min(imagePixels, UInt64(max(0, maxRequestImagePixels)))
        if hasVideo {
            let (s, o) = pixels.addingReportingOverflow(UInt64(max(0, maxRequestVideoFramePixels)))
            pixels = o ? .max : s
        }
        // RGBA (4 bytes/px) x decode overhead. Saturating.
        let (rgba, o1) = pixels.multipliedReportingOverflow(by: 4)
        let bytes = o1 ? UInt64.max : rgba
        let (total, o2) = bytes.multipliedReportingOverflow(by: UInt64(decodeOverheadFactor))
        return o2 ? UInt64.max : total
    }

    static func imagePixelCount(_ data: Data) -> Int? {
        guard let size = imagePixelSize(data) else { return nil }
        let (product, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        return overflow ? Int.max : product
    }

    /// Stored width and height from the format header only, before any EXIF
    /// orientation is applied; `nil` when ImageIO can't size the data.
    static func imagePixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int,
            w > 0, h > 0
        else { return nil }
        return (w, h)
    }

    /// Render a (possibly extreme/untrusted) seconds value for an error message
    /// without ever converting to `Int` — `Int(Double)` traps for values beyond
    /// `Int.max` or non-finite. Whole numbers print without a decimal point so
    /// the common "600s" case reads cleanly.
    static func secondsString(_ s: Double) -> String {
        guard s.isFinite else { return "\(s)" }  // "inf" / "nan"
        return s == s.rounded() && abs(s) < 1e15
            ? String(Int64(s))
            : String(format: "%.1f", s)
    }

    /// Overflow/NaN-safe pixel count of a realized `CIImage`/track extent.
    /// Returns 0 for a non-finite or sub-pixel extent (treated as "no charge").
    static func safeExtentPixels(_ extent: CGRect) -> Int {
        guard extent.width.isFinite, extent.height.isFinite,
            extent.width >= 1, extent.height >= 1
        else { return 0 }
        let w = extent.width >= Double(Int.max) ? Int.max : Int(extent.width)
        let h = extent.height >= Double(Int.max) ? Int.max : Int(extent.height)
        let (product, overflow) = w.multipliedReportingOverflow(by: h)
        return overflow ? Int.max : product
    }

    // MARK: - Media decode

    /// Decode an image content part. Inline `data:` URIs are decoded
    /// in-memory into a `CIImage`. Anything else is REJECTED: this is an
    /// end-to-end-encrypted provider, so the only legitimate transport for
    /// media is an inline `data:` URI inside the encrypted prompt. Accepting
    /// an arbitrary `http(s)://`/`file://` URL here would let a crafted
    /// request drive `CIImage(contentsOf:)` into an SSRF / local-file-read
    /// primitive (the provider is the fetcher), so a non-`data:` URI fails
    /// closed with `invalidURL`.
    static func decodeImage(
        _ uri: String, maxImagePixels: Int = Self.maxImagePixels
    ) throws -> UserInput.Image {
        guard uri.hasPrefix("data:") else {
            throw MediaError.invalidURL(uri)
        }
        let data = try dataFromDataURI(uri)
        return try decodeImageData(data, maxImagePixels: maxImagePixels)
    }

    /// Decode already-extracted image bytes into a `CIImage`, enforcing the
    /// per-image pixel cap from the format header BEFORE `CIImage(data:)` eagerly
    /// rasterizes (the allocation happens at decode, not at first use — there is
    /// no lazy escape, and the model's downscale doesn't help because CoreImage
    /// decodes the full-res source first), plus a post-decode extent backstop.
    ///
    /// Split out of `decodeImage` so the request-aggregate path (`parts`) can read
    /// the header and charge the aggregate BEFORE this allocates the raster.
    static func decodeImageData(
        _ data: Data, maxImagePixels: Int = Self.maxImagePixels
    ) throws -> UserInput.Image {
        if let pixels = imagePixelCount(data), pixels > maxImagePixels {
            throw MediaError.mediaTooLarge(
                "image is \(pixels) px; per-image cap is \(maxImagePixels) px")
        }
        // Full image at index 0 (never the EXIF thumbnail) with the file's
        // orientation applied. `CIImage(data:)` skips EXIF rotation and can
        // surface a JPEG thumbnail — both turn a real photograph into
        // abstract pixels the model then confidently misdescribes.
        let image: CIImage
        if let src = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: true] as CFDictionary),
            let cgImage = CGImageSourceCreateImageAtIndex(
                src, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        {
            var decoded = CIImage(cgImage: cgImage)
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                let raw = props[kCGImagePropertyOrientation] as? UInt32,
                let orientation = CGImagePropertyOrientation(rawValue: raw)
            {
                decoded = decoded.oriented(orientation)
            }
            image = normalizedExtent(decoded)
        } else if let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            image = normalizedExtent(decoded)
        } else {
            throw MediaError.imageDecodeFailed
        }
        // Backstop: if ImageIO couldn't size the header (imagePixelCount nil) but
        // CIImage still rasterized, enforce the cap on the realized extent so the
        // nil-fallthrough can't carry an oversized raster downstream.
        let extentPixels = safeExtentPixels(image.extent)
        if extentPixels > maxImagePixels {
            throw MediaError.mediaTooLarge(
                "image extent is \(extentPixels) px; per-image cap is \(maxImagePixels) px")
        }
        return .ciImage(image)
    }

    /// `oriented()` (and some ImageIO decodes) can leave a non-zero origin.
    /// The Qwen processor sizes from `extent.size` but `asMLXArray` renders
    /// `extent`; a shifted origin is a silent crop/empty-raster class of bugs.
    private static func normalizedExtent(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(
            by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    /// Decode an inline MP4 or QuickTime video into an owned memory-backed `AVURLAsset`. The
    /// asset's custom resource loader serves strict byte ranges directly from
    /// the decoded `Data`; no plaintext file is created. The bytes decide, not
    /// the `data:` label: clients send the same MP4 as `video/mov`,
    /// `video/x-m4v`, `application/octet-stream` or with a `codecs` parameter.
    /// The payload must be base64 (`;base64`); anything else is
    /// `malformedDataURI`. Bytes that are no ISO BMFF file at all (WebM,
    /// Matroska, MPEG streams) are `unsupportedMedia`; a damaged ISO BMFF
    /// file is `malformedDataURI`.
    /// Anything but a `data:` URI is REJECTED for the same reason as
    /// `decodeImage`: accepting an arbitrary `http(s)://`/`file://` URL would
    /// hand a crafted request an SSRF / local-file-read primitive via
    /// `AVAsset(url:)`. The only legitimate media transport on this
    /// E2E-encrypted provider is an inline `data:` URI, so a non-`data:` URI
    /// fails closed with `invalidURL`.
    static func decodeVideo(
        _ uri: String,
        maxFramePixels: Int = Self.maxImagePixels,
        maxVideoDurationSeconds: Double = Self.maxVideoDurationSeconds,
        maxMediaDecodedBytes: Int = Self.maxMediaDecodedBytes
    ) async throws -> (video: UserInput.Video, framePixels: Int) {
        guard uri.hasPrefix("data:") else {
            throw MediaError.invalidURL(uri)
        }
        guard let commaIndex = uri.firstIndex(of: ",") else {
            throw MediaError.malformedDataURI("missing ','")
        }
        // A movie is binary: only a base64 payload carries it. The test is
        // `dataFromDataURI`'s own, so the pair leaders, which decode the same
        // URI again for their wire, read the same bytes.
        guard uri[..<commaIndex].contains(";base64") else {
            throw MediaError.malformedDataURI("inline video must be base64-encoded (data:…;base64,…)")
        }
        let data = try dataFromDataURI(uri, maxMediaDecodedBytes: maxMediaDecodedBytes)
        guard !data.isEmpty else {
            throw MediaError.malformedDataURI("empty inline video")
        }
        let memoryAsset: MemoryBackedVideoAsset
        do {
            memoryAsset = try MemoryBackedVideoAsset(videoData: data)
        } catch {
            guard startsWithISOBMFFAtom(data) else {
                throw MediaError.unsupportedMedia(
                    "inline video must be an MP4 or QuickTime file; "
                        + "WebM, Matroska and MPEG streams are not supported")
            }
            throw MediaError.malformedDataURI("inline video is not a valid MP4 or QuickTime file")
        }
        // Reject a video bomb (huge frames / very long clip) before the model
        // decodes frames — the byte cap alone doesn't bound the decoded raster.
        // The metadata API retains the loader and bytes for the complete probe
        // without exposing a bare AVURLAsset across the package boundary.
        let metadata: VideoMetadata
        do {
            metadata = try await MediaProcessing.metadata(for: memoryAsset)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaError.mediaTooLarge("video metadata is unreadable")
        }
        let framePixels = try enforceVideoLimits(
            metadata, maxFramePixels: maxFramePixels,
            maxDurationSeconds: maxVideoDurationSeconds)
        return (.memoryBacked(memoryAsset), framePixels)
    }

    /// Top-level atom types an ISO BMFF (MP4 or QuickTime) file starts with.
    private static let isoBMFFLeadingAtomTypes: Set<String> = [
        "ftyp", "moov", "mdat", "free", "skip", "wide", "pnot", "uuid", "styp", "moof",
    ]

    /// True when `data` begins like an ISO BMFF file: its first atom's type is
    /// one an MP4 or QuickTime file starts with. Separates a damaged MP4 (a
    /// malformed request) from another container (unsupported media) after
    /// `MemoryBackedVideoAsset` refused the bytes.
    static func startsWithISOBMFFAtom(_ data: Data) -> Bool {
        guard data.count >= 8,
            let type = String(bytes: data.dropFirst(4).prefix(4), encoding: .isoLatin1)
        else { return false }
        return isoBMFFLeadingAtomTypes.contains(type)
    }

    /// Reject a video bomb using track metadata only (no frame decode). Fails
    /// CLOSED: the byte cap does NOT bound decoded frame pixels or the sampled
    /// frame count, so a video whose duration or any track's frame dimensions
    /// can't be read and proven within cap is rejected. The model samples frames
    /// from these same properties, so a video it can actually use is always
    /// probeable here — fail-closed never rejects a usable video.
    @discardableResult
    static func enforceVideoLimits(
        _ metadata: VideoMetadata, maxFramePixels: Int, maxDurationSeconds: Double
    ) throws -> Int {
        try Task.checkCancellation()

        // Duration bounds the sampled frame count (frames = duration × fps).
        // Unreadable / non-finite / over-cap → reject.
        let durationSeconds = metadata.duration.seconds
        guard durationSeconds.isFinite else {
            throw MediaError.mediaTooLarge("video duration is unreadable")
        }
        try Task.checkCancellation()
        guard durationSeconds <= maxDurationSeconds else {
            // Format as Double, not Int: this is untrusted metadata, and a
            // duration > Int.max seconds would trap on `Int(_:)` while building
            // the rejection message — turning a fail-closed 400 into a crash.
            throw MediaError.mediaTooLarge(
                "video is \(secondsString(durationSeconds))s; duration cap is "
                    + "\(secondsString(maxDurationSeconds))s")
        }

        guard !metadata.tracks.isEmpty else {
            throw MediaError.mediaTooLarge("no readable video track")
        }
        // EVERY track's CODED frame dimensions (what the decoder allocates before
        // AVAssetImageGenerator scales to naturalSize) must be readable and ≤ cap.
        // A file can understate naturalSize while coding huge frames, so charge
        // the larger of naturalSize and the format-description dimensions.
        var maxTrackPixels = 0
        for track in metadata.tracks {
            try Task.checkCancellation()
            guard !track.decodedFrameDimensions.isEmpty else {
                throw MediaError.mediaTooLarge("video frame dimensions are unreadable")
            }
            var framePixels = 0
            if let size = track.naturalSize {
                framePixels = safeExtentPixels(CGRect(origin: .zero, size: size))
            }
            for size in track.decodedFrameDimensions {
                framePixels = max(
                    framePixels,
                    safeExtentPixels(CGRect(origin: .zero, size: size)))
            }
            if framePixels > maxFramePixels {
                throw MediaError.mediaTooLarge(
                    "video frame is \(framePixels) px; per-frame cap is \(maxFramePixels) px")
            }
            maxTrackPixels = max(maxTrackPixels, framePixels)
        }
        return maxTrackPixels
    }

    /// Extract the raw bytes from a `data:` URI. The header before the
    /// first comma decides the encoding: `;base64` ⇒ base64, otherwise
    /// the payload is percent-encoded UTF-8 text.
    static func dataFromDataURI(
        _ uri: String, maxMediaDecodedBytes: Int = Self.maxMediaDecodedBytes
    ) throws -> Data {
        guard let commaIndex = uri.firstIndex(of: ",") else {
            throw MediaError.malformedDataURI("missing ','")
        }
        let header = uri[uri.startIndex..<commaIndex]
        let payload = String(uri[uri.index(after: commaIndex)...])

        if header.contains(";base64") {
            let stripped = payload.filter { !$0.isWhitespace }
            // base64 decodes to (len/4)*3 minus the trailing '=' padding. Subtract
            // the padding so the cap boundary is exact (Swift rejects unpadded
            // base64, so this length is never an underestimate). Reject from the
            // length BEFORE allocating the decoded buffer.
            let padding = stripped.suffix(2).filter { $0 == "=" }.count
            let approxDecoded = stripped.utf8.count / 4 * 3 - padding
            guard approxDecoded <= maxMediaDecodedBytes else {
                throw MediaError.mediaTooLarge(
                    "payload ~\(approxDecoded) bytes; cap is \(maxMediaDecodedBytes) bytes")
            }
            guard let data = Data(base64Encoded: stripped) else {
                throw MediaError.base64DecodeFailed
            }
            return data
        }

        // Percent-encoded: each %XX (3 bytes) decodes to 1 byte and every other
        // byte is itself, so decoded length = len − 2·(number of '%'). Preflight
        // from that length BEFORE allocating the decoded String/Data (mirrors the
        // base64 path; the post-decode check below stays as a backstop).
        let encoded = payload.utf8
        let percentCount = encoded.lazy.filter { $0 == UInt8(ascii: "%") }.count
        let approxDecoded = encoded.count - 2 * percentCount
        guard approxDecoded <= maxMediaDecodedBytes else {
            throw MediaError.mediaTooLarge(
                "payload ~\(approxDecoded) bytes; cap is \(maxMediaDecodedBytes) bytes")
        }
        guard let decoded = payload.removingPercentEncoding,
            let data = decoded.data(using: .utf8)
        else {
            throw MediaError.percentDecodeFailed
        }
        guard data.count <= maxMediaDecodedBytes else {
            throw MediaError.mediaTooLarge(
                "payload \(data.count) bytes; cap is \(maxMediaDecodedBytes) bytes")
        }
        return data
    }

}
