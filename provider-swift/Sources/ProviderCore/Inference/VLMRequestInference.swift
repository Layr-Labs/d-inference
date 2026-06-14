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

    // MARK: - Streaming

    /// Stream a multimodal completion through the container's
    /// `prepare`/`generate` vision path.
    ///
    /// Emits the same `MLXServerGenerationEvent` shape as the batched
    /// engine so the surrounding HTTP/SSE plumbing is identical:
    /// `.content` chunks during generation, then a final `.info` carrying
    /// token counts and timing. Inline-video temp files are removed when
    /// the stream ends (normal completion, error, or cancellation).
    public static func stream(
        container: ModelContainer,
        request: OpenAIChatCompletionRequest,
        defaultMaxTokens: Int
    ) -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Inline `data:` videos are materialized to temp files for
                // AVFoundation; track them so we can clean up on exit.
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

                    let params = GenerateParameters(
                        maxTokens: request.maxTokens ?? defaultMaxTokens,
                        temperature: request.temperature ?? 0,
                        topP: request.topP ?? 1.0,
                        topK: request.topK ?? 0,
                        repetitionPenalty: request.repetitionPenalty
                    )

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
        maxRequestImagePixels: Int = Self.maxRequestImagePixels
    ) async throws -> UserInput {
        var chatMessages: [Chat.Message] = []
        var totalPixels = 0
        for message in request.messages {
            let (text, images, videos) = try await parts(
                from: message.content, tempFiles: &tempFiles, totalPixels: &totalPixels,
                maxRequestImagePixels: maxRequestImagePixels)
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
        maxRequestImagePixels: Int = Self.maxRequestImagePixels
    ) async throws -> UserInput {
        var sink: [URL] = []
        return try await buildUserInput(
            from: request, tempFiles: &sink, maxRequestImagePixels: maxRequestImagePixels)
    }

    /// Split a message's content into the concatenated text plus decoded
    /// image/video media. Non-user roles drop media at the call site, but
    /// we still decode here so a malformed inline payload fails loudly
    /// rather than being silently ignored.
    private static func parts(
        from content: OpenAIMessageContent,
        tempFiles: inout [URL],
        totalPixels: inout Int,
        maxRequestImagePixels: Int
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
                    let image = try decodeImage(uri)
                    // Charge the request-wide aggregate (each image is already
                    // ≤ maxImagePixels, so peak is bounded by aggregate + one image).
                    // Overflow-safe to match imagePixelCount's handling.
                    if case .ciImage(let ci) = image {
                        let (sum, overflow) =
                            totalPixels.addingReportingOverflow(safeExtentPixels(ci.extent))
                        totalPixels = overflow ? Int.max : sum
                        guard totalPixels <= maxRequestImagePixels else {
                            throw MediaError.mediaTooLarge(
                                "request images total \(totalPixels) px; aggregate cap is "
                                    + "\(maxRequestImagePixels) px")
                        }
                    }
                    images.append(image)
                case .videoURL(let uri):
                    videos.append(try await decodeVideo(uri, tempFiles: &tempFiles))
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

    /// Resolve a megapixel limit from `env` (a positive megapixel count) or fall
    /// back to `defaultMegapixels`. Injectable environment for tests.
    static func resolveMaxPixels(
        env name: String, defaultMegapixels: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        if let raw = environment[name], let mp = Double(raw), mp > 0, mp.isFinite {
            return Int(min(mp * 1_000_000, Double(Int.max)))
        }
        return defaultMegapixels * 1_000_000
    }

    /// Resolve a byte limit from `env` (a positive MiB count) or `defaultMiB`.
    static func resolveMaxBytes(
        env name: String, defaultMiB: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        if let raw = environment[name], let mib = Int(raw), mib > 0 {
            return mib * 1024 * 1024
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

    /// Pixel count (width × height) read from the image's format **header only**
    /// — no raster decode (proven O(header): ~0 MB RSS even for a gigapixel
    /// bomb). Returns `nil` if ImageIO can't size the data (truncated/unknown
    /// format), in which case `CIImage(data:)` fails closed downstream.
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
        // Reject a decompression bomb from the header BEFORE CIImage(data:)
        // eagerly rasterizes it (the allocation happens at decode, not at first
        // use — there is no lazy escape, and the model's downscale doesn't help
        // because CoreImage decodes the full-res source first).
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
    ) async throws -> UserInput.Video {
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
        do {
            try await enforceVideoLimits(
                tempURL, maxFramePixels: maxFramePixels,
                maxDurationSeconds: maxVideoDurationSeconds)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        tempFiles.append(tempURL)
        return .url(tempURL)
    }

    /// Reject a video whose frame dimensions or duration exceed the caps, read
    /// from track metadata without decoding frames. A file with no readable
    /// video track is left to the model (still bounded by the byte cap) rather
    /// than rejected here — mirroring the image header nil-fallthrough.
    static func enforceVideoLimits(
        _ url: URL, maxFramePixels: Int, maxDurationSeconds: Double
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return
        }
        if let size = try? await track.load(.naturalSize) {
            let pixels = safeExtentPixels(CGRect(origin: .zero, size: size))
            if pixels > maxFramePixels {
                throw MediaError.mediaTooLarge(
                    "video frame is \(pixels) px; per-frame cap is \(maxFramePixels) px")
            }
        }
        if let duration = try? await asset.load(.duration),
            duration.seconds.isFinite, duration.seconds > maxDurationSeconds
        {
            throw MediaError.mediaTooLarge(
                "video is \(Int(duration.seconds))s; duration cap is \(Int(maxDurationSeconds))s")
        }
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
