// Copyright © 2026 Eigen Labs.
//
// Non-batched vision-language inference path.
//
// The continuous-batching engine (`BatchScheduler` / `BatchedEngine`)
// carries only `[Int]` token arrays, so it cannot represent image/video
// pixels. Multimodal requests for a VLM model are served here instead:
// we build a `UserInput` carrying the decoded media, `prepare` it into an
// `LMInput`, and stream `container.generate(...)`. This mirrors exactly
// the prepare → generate path proven by `Sources/vlm-smoke/main.swift`.
//
// Text-only requests never reach this file — they stay on the batched
// engine. Routing lives in
// `MultiModelBatchSchedulerEngine.streamChatCompletion`, which calls
// `VLMRequestInference.hasMedia` and, when true for a VLM model,
// delegates to `VLMRequestInference.stream`.

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import MLXLMCommon
import MLXLMServer

/// Namespace for the non-batched VLM (image/video) inference path.
///
/// Pure functions + one streaming entry point; holds no state. The
/// container is owned by `ProviderLoop`'s `ModelSlot` and passed in.
public enum VLMRequestInference {

    /// Errors surfaced while decoding inline media from a request. These
    /// finish the stream via `continuation.finish(throwing:)` so the
    /// status mapper can turn them into a 4xx for the caller.
    ///
    /// Conforms to `LocalizedError` so the human-readable `description`
    /// reaches the client (via `error.localizedDescription`) instead of
    /// the generic Cocoa "operation couldn't be completed" fallback.
    public enum MediaError: Error, CustomStringConvertible, LocalizedError {
        case malformedDataURI(String)
        case base64DecodeFailed
        case percentDecodeFailed
        case imageDecodeFailed
        case invalidURL(String)
        case videoWriteFailed(String)
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
            case .videoWriteFailed(let detail):
                return "failed to write inline video to a temp file (\(detail))"
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

    /// Build the engine sampling parameters from an OpenAI request. Forwards all
    /// sampling penalties — repetition, presence, and frequency — so they take
    /// effect on image/video (VLM) requests, matching the text/batched engine.
    /// The penalty processors apply only for non-identity values (repetition ≠ 1,
    /// presence/frequency ≠ 0); identities are no-ops.
    /// The max output-token bound this request will actually generate with —
    /// the consumer's `max_tokens` if set, else the model's default. The KV
    /// reservation for the vision path sizes the generation cache from this, so
    /// it must match what `generateParameters` feeds the generator exactly.
    static func resolveMaxOutputTokens(
        for request: OpenAIChatCompletionRequest, defaultMaxTokens: Int
    ) -> Int {
        request.maxTokens ?? defaultMaxTokens
    }

    /// Conservative per-image soft-token allotment for the KV-token estimate.
    /// Gemma-4 pools every image to a FIXED `vision_soft_tokens_per_image` (256)
    /// regardless of resolution; other VLMs run higher. 1024 (4× Gemma) is a
    /// generous model-agnostic upper bound that is still bounded by the model's
    /// context window via the clamp in `projectedKVTokens`.
    static let visionTokensPerImage = 1024
    /// A video samples multiple frames, each contributing image-like soft tokens.
    /// Charge a larger fixed allotment per video; still clamped to the context.
    static let visionTokensPerVideo = 4096
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

    static func generateParameters(
        for request: OpenAIChatCompletionRequest, defaultMaxTokens: Int
    ) -> GenerateParameters {
        GenerateParameters(
            maxTokens: resolveMaxOutputTokens(for: request, defaultMaxTokens: defaultMaxTokens),
            temperature: request.temperature ?? 0,
            topP: request.topP ?? 1.0,
            topK: request.topK ?? 0,
            repetitionPenalty: request.repetitionPenalty,
            presencePenalty: request.presencePenalty,
            frequencyPenalty: request.frequencyPenalty
        )
    }

    // MARK: - Streaming

    /// Stream a multimodal completion through the container's
    /// `prepare`/`generate` vision path.
    ///
    /// Emits the same `MLXServerGenerationEvent` shape as the batched
    /// engine so the surrounding HTTP/SSE plumbing is identical:
    /// `.content` chunks during generation, then a final `.info` carrying
    /// token counts and timing. Inline-video temp files are removed when
    /// the stream ends (normal completion, error, or cancellation).
    /// Validate all inline media for a request UP FRONT, throwing `MediaError`
    /// synchronously on any oversized/malformed/non-`data:` payload (or video-cap
    /// violation). Callers MUST call this (and propagate the throw) BEFORE
    /// returning a streaming response, so the correct 4xx is surfaced instead of
    /// a 200 SSE body that only errors mid-iteration — `stream` builds its own
    /// `UserInput` inside the generation task (UserInput isn't Sendable, so it
    /// can't cross the task boundary), which is why validation is a separate
    /// pass here rather than handing the decoded input through.
    ///
    /// This runs the same decode path as `stream` (`buildUserInput`) purely for
    /// its throwing side-effects and discards the result; any inline-video temp
    /// file it writes is removed before returning. The decode work is bounded by
    /// the very caps it enforces (≤ per-image / aggregate pixels, ≤ byte cap), so
    /// the up-front pass can't itself be a DoS, and the eventual rebuild inside
    /// `stream` re-validates identically.
    public static func validateMedia(
        _ request: OpenAIChatCompletionRequest,
        maxImagePixels: Int = Self.maxImagePixels,
        maxRequestImagePixels: Int = Self.maxRequestImagePixels,
        maxVideosPerRequest: Int = Self.maxVideosPerRequest,
        maxRequestVideoFramePixels: Int = Self.maxRequestVideoFramePixels
    ) async throws {
        var tempFiles: [URL] = []
        defer { for url in tempFiles { try? FileManager.default.removeItem(at: url) } }
        _ = try await buildUserInput(
            from: request, tempFiles: &tempFiles, maxImagePixels: maxImagePixels,
            maxRequestImagePixels: maxRequestImagePixels,
            maxVideosPerRequest: maxVideosPerRequest,
            maxRequestVideoFramePixels: maxRequestVideoFramePixels)
    }

    public static func stream(
        container: ModelContainer,
        request: OpenAIChatCompletionRequest,
        defaultMaxTokens: Int
    ) -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Inline `data:` videos are materialized to temp files for
                // AVFoundation; track them so we can clean up on exit. Media was
                // already validated up front by `validateMedia` (so an oversized
                // payload surfaced its 4xx before this stream was returned); the
                // rebuild here re-runs the same decode to produce the UserInput
                // (which isn't Sendable and so can't cross the task boundary).
                var tempFiles: [URL] = []
                defer {
                    for url in tempFiles {
                        try? FileManager.default.removeItem(at: url)
                    }
                }

                let userInput: UserInput
                do {
                    userInput = try await buildUserInput(from: request, tempFiles: &tempFiles)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                do {
                    // Capture the prompt-clock origin BEFORE `prepare` so the
                    // reported `promptTime` includes media decode / resize /
                    // tokenization, matching the batched + server engines
                    // (which start their clock before any prep work). Capturing
                    // it after `prepare` would undercount prompt latency.
                    let startedAt = Date()
                    let lmInput = try await container.prepare(input: userInput)

                    let params = generateParameters(
                        for: request, defaultMaxTokens: defaultMaxTokens)

                    let genStream = try await container.generate(
                        input: lmInput, parameters: params)

                    var promptTokens = 0
                    var completionTokens = 0
                    var firstTokenAt: Date?
                    var lastTokenAt: Date?
                    // Default to "stop"; overwritten from the engine's
                    // GenerateCompletionInfo so we report the real finish
                    // reason (e.g. "length" when maxTokens is hit) instead of
                    // a hardcoded value.
                    var stopReason = "stop"

                    for await gen in genStream {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        switch gen {
                        case .chunk(let text):
                            if firstTokenAt == nil { firstTokenAt = Date() }
                            lastTokenAt = Date()
                            if !text.isEmpty {
                                continuation.yield(.content(text))
                            }
                        case .info(let info):
                            promptTokens = info.promptTokenCount
                            completionTokens = info.generationTokenCount
                            stopReason = openAIFinishReason(info.stopReason)
                        case .toolCall(let toolCall):
                            continuation.yield(.toolCall(toolCall))
                        }
                    }

                    let promptTime = (firstTokenAt ?? startedAt)
                        .timeIntervalSince(startedAt)
                    let generationTime = (lastTokenAt ?? firstTokenAt ?? startedAt)
                        .timeIntervalSince(firstTokenAt ?? startedAt)
                    continuation.yield(
                        .info(
                            ServerGenerationInfo(
                                promptTokens: promptTokens,
                                completionTokens: completionTokens,
                                promptTime: max(0, promptTime),
                                generationTime: max(0, generationTime),
                                stopReason: stopReason
                            )
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - UserInput construction

    /// Build a model-agnostic `UserInput` from the OpenAI request,
    /// decoding any inline image/video content parts. `tempFiles`
    /// accumulates temp URLs created for inline videos so the caller can
    /// remove them when the stream ends.
    static func buildUserInput(
        from request: OpenAIChatCompletionRequest,
        tempFiles: inout [URL],
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
                from: message.content, tempFiles: &tempFiles, totalPixels: &totalPixels,
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
        return UserInput(chat: chatMessages)
    }

    /// Convenience overload that discards temp-file tracking. Used by
    /// tests that pass only base64/url images (no inline videos).
    static func buildUserInput(
        from request: OpenAIChatCompletionRequest,
        maxImagePixels: Int = Self.maxImagePixels,
        maxRequestImagePixels: Int = Self.maxRequestImagePixels,
        maxVideosPerRequest: Int = Self.maxVideosPerRequest,
        maxRequestVideoFramePixels: Int = Self.maxRequestVideoFramePixels
    ) async throws -> UserInput {
        var sink: [URL] = []
        return try await buildUserInput(
            from: request, tempFiles: &sink, maxImagePixels: maxImagePixels,
            maxRequestImagePixels: maxRequestImagePixels,
            maxVideosPerRequest: maxVideosPerRequest,
            maxRequestVideoFramePixels: maxRequestVideoFramePixels)
    }

    /// Split a message's content into the concatenated text plus decoded
    /// image/video media. Non-user roles drop media at the call site, but
    /// we still decode here so a malformed inline payload fails loudly
    /// rather than being silently ignored.
    private static func parts(
        from content: OpenAIMessageContent,
        tempFiles: inout [URL],
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
                    let decoded = try await decodeVideo(uri, tempFiles: &tempFiles)
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
    /// Bounds the inline-video temp file + in-RAM buffer too.
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

    /// Decode a video content part. Inline `data:` URIs are written to a
    /// unique temp file (tracked for cleanup) because AVFoundation consumes
    /// a URL. Anything else is REJECTED for the same reason as `decodeImage`:
    /// accepting an arbitrary `http(s)://`/`file://` URL would hand a crafted
    /// request an SSRF / local-file-read primitive via `AVAsset(url:)`. The
    /// only legitimate media transport on this E2E-encrypted provider is an
    /// inline `data:` URI, so a non-`data:` URI fails closed with `invalidURL`.
    static func decodeVideo(
        _ uri: String, tempFiles: inout [URL],
        maxFramePixels: Int = Self.maxImagePixels,
        maxVideoDurationSeconds: Double = Self.maxVideoDurationSeconds,
        maxMediaDecodedBytes: Int = Self.maxMediaDecodedBytes
    ) async throws -> (video: UserInput.Video, framePixels: Int) {
        guard uri.hasPrefix("data:") else {
            throw MediaError.invalidURL(uri)
        }
        let data = try dataFromDataURI(uri, maxMediaDecodedBytes: maxMediaDecodedBytes)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlm-\(UUID().uuidString).mp4")
        do {
            try data.write(to: tempURL)
        } catch {
            throw MediaError.videoWriteFailed(String(describing: error))
        }
        // Reject a video bomb (huge frames / very long clip) before the model
        // decodes frames — the byte cap alone doesn't bound the decoded raster.
        // Read track metadata only; no frame decode. The temp file isn't tracked
        // in `tempFiles` until it passes, so remove it on the reject path.
        let framePixels: Int
        do {
            framePixels = try await enforceVideoLimits(
                tempURL, maxFramePixels: maxFramePixels,
                maxDurationSeconds: maxVideoDurationSeconds)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        tempFiles.append(tempURL)
        return (.url(tempURL), framePixels)
    }

    /// Reject a video bomb using track metadata only (no frame decode). Fails
    /// CLOSED: the byte cap does NOT bound decoded frame pixels or the sampled
    /// frame count, so a video whose duration or any track's frame dimensions
    /// can't be read and proven within cap is rejected. The model samples frames
    /// from these same properties, so a video it can actually use is always
    /// probeable here — fail-closed never rejects a usable video.
    @discardableResult
    static func enforceVideoLimits(
        _ url: URL, maxFramePixels: Int, maxDurationSeconds: Double
    ) async throws -> Int {
        let asset = AVURLAsset(url: url)

        // Duration bounds the sampled frame count (frames = duration × fps).
        // Unreadable / non-finite / over-cap → reject.
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite else {
            throw MediaError.mediaTooLarge("video duration is unreadable")
        }
        guard duration.seconds <= maxDurationSeconds else {
            // Format as Double, not Int: this is untrusted metadata, and a
            // duration > Int.max seconds would trap on `Int(_:)` while building
            // the rejection message — turning a fail-closed 400 into a crash.
            throw MediaError.mediaTooLarge(
                "video is \(secondsString(duration.seconds))s; duration cap is "
                    + "\(secondsString(maxDurationSeconds))s")
        }

        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty
        else {
            throw MediaError.mediaTooLarge("no readable video track")
        }
        // EVERY track's CODED frame dimensions (what the decoder allocates before
        // AVAssetImageGenerator scales to naturalSize) must be readable and ≤ cap.
        // A file can understate naturalSize while coding huge frames, so charge
        // the larger of naturalSize and the format-description dimensions.
        var maxTrackPixels = 0
        for track in tracks {
            guard let formats = try? await track.load(.formatDescriptions), !formats.isEmpty else {
                throw MediaError.mediaTooLarge("video frame dimensions are unreadable")
            }
            var framePixels = 0
            if let size = try? await track.load(.naturalSize) {
                framePixels = safeExtentPixels(CGRect(origin: .zero, size: size))
            }
            for desc in formats {
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                framePixels = max(
                    framePixels,
                    safeExtentPixels(
                        CGRect(x: 0, y: 0, width: Int(dims.width), height: Int(dims.height))))
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

    // MARK: - Stop-reason mapping

    /// Map a `GenerateStopReason` to the OpenAI `finish_reason` string.
    ///
    /// MLXLMServer ships an equivalent `GenerateStopReason.openAIFinishReason`
    /// but it is `internal` to that module, so we mirror its mapping here to
    /// keep the same wire contract as the batched + server engines: `.length`
    /// ⇒ `"length"`, everything else (`.stop`, `.cancelled`) ⇒ `"stop"`.
    static func openAIFinishReason(_ reason: GenerateStopReason) -> String {
        switch reason {
        case .length:
            return "length"
        case .stop, .cancelled:
            return "stop"
        }
    }
}
