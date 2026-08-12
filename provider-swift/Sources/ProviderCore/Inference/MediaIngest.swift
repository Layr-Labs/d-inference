// Copyright © 2026 Eigen Labs.
//
// Media ingest for multimodal (image/video) requests.
//
// Everything between an OpenAI request's inline `data:` media parts and a
// model-ready `UserInput`: decode (CIImage / memory-backed AVFoundation assets),
// decompression-bomb caps (per-image + per-request pixels, byte/second/
// count limits), up-front validation (`validateMedia` — throws the 4xx
// before any stream starts), memory projections for the vision gate
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
import CoreImage
import Foundation
import ImageIO
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
            }
        }

        public var errorDescription: String? { description }
    }

    // MARK: - Routing

    /// True when any message carries an image or video content part.
    /// Used by the engine to decide between the batched (text) path and
    /// this non-batched vision path.
    public static func hasMedia(_ request: OpenAIChatCompletionRequest) -> Bool {
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                switch part {
                case .imageURL, .videoURL:
                    return true
                case .text, .unsupported:
                    continue
                }
            }
        }
        return false
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
                    case .imageURL: add(visionTokensPerImage)
                    case .videoURL: add(visionTokensPerVideo)
                    case .unsupported: continue
                    }
                }
            case .null:
                continue
            }
        }
        // The KV cache can't hold more input tokens than the context window.
        if contextLength > 0 { promptTokens = min(promptTokens, contextLength) }
        let maxOutput = max(0, resolveMaxOutputTokens(for: request, defaultMaxTokens: defaultMaxTokens))
        let (total, overflow) = promptTokens.addingReportingOverflow(maxOutput)
        return overflow ? Int.max : total
    }

    // MARK: - Up-front validation

    /// Validate all inline media for a request UP FRONT, throwing `MediaError`
    /// synchronously on any oversized/malformed/non-`data:` payload (or video-cap
    /// violation). Callers MUST call this (and propagate the throw) BEFORE
    /// returning a streaming response, so the correct 4xx is surfaced instead of
    /// a 200 SSE body that only errors mid-iteration.
    ///
    /// This runs the decode path (`buildUserInput`) purely for its throwing
    /// side-effects and discards the result. Inline-video bytes remain in the
    /// returned input's owned memory-backed assets and are released with it;
    /// they are never materialized on disk. The decode work is bounded by the
    /// very caps it enforces (≤ per-image / aggregate pixels, ≤ byte cap), so
    /// the up-front pass can't itself be a DoS, and the eventual rebuild in
    /// the v2 media prefill re-validates identically.
    public static func validateMedia(
        _ request: OpenAIChatCompletionRequest,
        maxImagePixels: Int = Self.maxImagePixels,
        maxRequestImagePixels: Int = Self.maxRequestImagePixels,
        maxVideosPerRequest: Int = Self.maxVideosPerRequest,
        maxRequestVideoFramePixels: Int = Self.maxRequestVideoFramePixels
    ) async throws {
        _ = try await buildUserInput(
            from: request, maxImagePixels: maxImagePixels,
            maxRequestImagePixels: maxRequestImagePixels,
            maxVideosPerRequest: maxVideosPerRequest,
            maxRequestVideoFramePixels: maxRequestVideoFramePixels)
    }

    // MARK: - UserInput construction

    /// Build a model-agnostic `UserInput` from the OpenAI request, decoding any
    /// inline image/video content parts. Inline MP4s are retained in memory by
    /// their `UserInput.Video` values for the lifetime of the returned input.
    static func buildUserInput(
        from request: OpenAIChatCompletionRequest,
        reasoningEffort: String? = nil,
        maxImagePixels: Int = Self.maxImagePixels,
        maxRequestImagePixels: Int = Self.maxRequestImagePixels,
        maxVideosPerRequest: Int = Self.maxVideosPerRequest,
        maxRequestVideoFramePixels: Int = Self.maxRequestVideoFramePixels
    ) async throws -> UserInput {
        var chatMessages: [Chat.Message] = []
        var totalPixels = 0
        var totalVideoPixels = 0
        var videoCount = 0
        for message in request.messages {
            let (text, images, videos) = try await parts(
                from: message.content, totalPixels: &totalPixels,
                totalVideoPixels: &totalVideoPixels, videoCount: &videoCount,
                maxImagePixels: maxImagePixels,
                maxRequestImagePixels: maxRequestImagePixels,
                maxVideosPerRequest: maxVideosPerRequest,
                maxRequestVideoFramePixels: maxRequestVideoFramePixels)
            switch message.role {
            case .user:
                chatMessages.append(.user(text, images: images, videos: videos))
            case .system:
                chatMessages.append(.system(text))
            case .assistant:
                chatMessages.append(.assistant(text))
            case .tool:
                chatMessages.append(.tool(text))
            }
        }
        return UserInput(
            chat: chatMessages,
            additionalContext: MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request, reasoningEffort: reasoningEffort))
    }


    /// Split a message's content into the concatenated text plus decoded
    /// image/video media. Non-user roles drop media at the call site, but
    /// we still decode here so a malformed inline payload fails loudly
    /// rather than being silently ignored.
    private static func parts(
        from content: OpenAIMessageContent,
        totalPixels: inout Int,
        totalVideoPixels: inout Int,
        videoCount: inout Int,
        maxImagePixels: Int,
        maxRequestImagePixels: Int,
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
                    if case .ciImage(let ci) = image {
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
    /// The estimate is clamped to the SAME ceilings `validateMedia` enforces, so
    /// it can never exceed what a maximally-large *valid* request consumes:
    ///   • image pixels are summed but clamped to the aggregate image cap
    ///     (`maxRequestImagePixels`) — a single oversized image, or many
    ///     unreadable-header images, can't project past the request-wide image
    ///     ceiling validation guarantees;
    ///   • videos are charged the aggregate per-request video-frame cap ONCE if
    ///     any video is present — NOT per video. `validateMedia` bounds the SUM
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
                case .text, .unsupported:
                    continue
                }
            }
        }
        // Clamp images to the request-wide aggregate cap, then add the video
        // aggregate once. Both mirror validateMedia's ceilings exactly.
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
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int,
            w > 0, h > 0
        else { return nil }
        let (product, overflow) = w.multipliedReportingOverflow(by: h)
        return overflow ? Int.max : product
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
        guard let image = CIImage(data: data) else {
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

    /// Decode an inline MP4 or QuickTime video into an owned memory-backed `AVURLAsset`. The
    /// asset's custom resource loader serves strict byte ranges directly from
    /// the decoded `Data`; no plaintext file is created. Anything else is
    /// REJECTED for the same reason as `decodeImage`:
    /// accepting an arbitrary `http(s)://`/`file://` URL would hand a crafted
    /// request an SSRF / local-file-read primitive via `AVAsset(url:)`. The
    /// only legitimate media transport on this E2E-encrypted provider is an
    /// inline `data:` URI, so a non-`data:` URI fails closed with `invalidURL`.
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
        let header = String(uri[..<commaIndex])
        let isMP4 = header.caseInsensitiveCompare("data:video/mp4;base64") == .orderedSame
        let isQuickTime =
            header.caseInsensitiveCompare("data:video/quicktime;base64") == .orderedSame
        guard isMP4 || isQuickTime else {
            throw MediaError.malformedDataURI(
                "inline video must use data:video/mp4;base64 or data:video/quicktime;base64")
        }
        let data = try dataFromDataURI(uri, maxMediaDecodedBytes: maxMediaDecodedBytes)
        let memoryAsset: MemoryBackedVideoAsset
        do {
            memoryAsset = try MemoryBackedVideoAsset(videoData: data)
        } catch {
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
