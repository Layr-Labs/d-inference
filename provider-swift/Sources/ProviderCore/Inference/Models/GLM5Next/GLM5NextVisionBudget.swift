import Foundation
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM

extension VisionTowerBudget {
    /// GLM tiles attention queries and attends within one temporal pair. Price
    /// that actual tile, plus linear tower buffers, rather than Qwen's full N²
    /// mask. This is an additional per-buffer check, not an activation/KV grant.
    static func glm5FrameLimits(
        grid: THW, configuration: GLM5NextVisionConfiguration,
        limits: Limits
    ) throws -> GLM5NextVisionLimits {
        guard grid.t == 1, grid.h > 0, grid.w > 0, grid.h.isMultiple(of: 2),
            grid.w.isMultiple(of: 2),
            let patches = patchCount(grid), patches > 0, limits.maxBufferBytes > 0
        else {
            throw EngineV2VisionPrefillError.invalidVisionGrid(mediaIndex: 0)
        }
        // Every Mac refuses a frame past the native limit (a 4K clip of a few
        // pairs), so it is the request's fault; an operator's lower limit is
        // this Mac's own and stays retriable.
        guard patches <= GLM5NextVisionBudget.maximumFramePatches else {
            throw EngineV2VisionPrefillError.unsupportedMedia(
                "GLM frame exceeds the tower's \(GLM5NextVisionBudget.maximumFramePatches)-patch limit; "
                    + "lower the video's resolution")
        }
        let maximumPatches = min(
            GLM5NextVisionBudget.maximumFramePatches,
            limits.operatorMaxPatches ?? GLM5NextVisionBudget.maximumFramePatches)
        guard patches <= maximumPatches else {
            throw EngineV2VisionPrefillError.towerBudgetExceeded(
                "GLM frame exceeds operator patch limit")
        }
        func bytes(_ dimensions: [Int]) throws -> Int {
            var value = 4  // Conservative FP32 intermediates, including prepared pixels.
            for dimension in dimensions {
                let next = value.multipliedReportingOverflow(by: dimension)
                guard dimension > 0, !next.overflow else {
                    throw EngineV2VisionPrefillError.towerBudgetExceeded("GLM frame byte overflow")
                }
                value = next.partialValue
            }
            return value
        }
        let c = configuration
        let scoreElements = min(32_000_000, limits.maxBufferBytes / 4)
        guard c.numHeads > 0, scoreElements / c.numHeads / patches > 0 else {
            throw EngineV2VisionPrefillError.towerBudgetExceeded(
                "GLM attention query tile cannot fit")
        }
        let query = min(128, min(patches, scoreElements / c.numHeads / patches))
        let buffers = try [
            bytes([patches, c.inChannels, c.temporalPatchSize, c.patchSize, c.patchSize]),
            bytes([patches, c.hiddenSize, 3]),
            bytes([patches, c.intermediateSize, 2]),
            bytes([patches, c.hiddenSize / c.numHeads]),
            bytes([patches / 4, c.outHiddenSize]),
            bytes([c.numHeads, query, patches]),
        ]
        guard buffers.allSatisfy({ $0 <= limits.maxBufferBytes }) else {
            throw EngineV2VisionPrefillError.towerBudgetExceeded(
                "GLM tower buffer exceeds Metal limit")
        }
        return .init(
            maximumPatches: maximumPatches, maximumFramePatches: maximumPatches,
            maximumQueryTokens: query, maximumScoreElements: scoreElements)
    }
}

/// Unified-memory reservation for one GLM media preparation, charged by the
/// scheduler's `VisionMemoryGate` before decode and released after the tower.
enum GLM5NextVisionBudget {
    /// Native tower limit on one temporal pair (`GLM5NextVisionLimits`).
    static let maximumFramePatches = 32_000

    struct Reservation: Equatable {
        /// Unified-memory bytes the media preparation holds besides KV.
        let bytes: UInt64
        /// Prompt text and media tokens plus output.
        let kvTokens: Int
    }

    /// Exact `0`, `false`, `no` or `off` (trimmed, case-insensitive) prices
    /// every image and video at the processor's ceilings again, as 0.10.13 did.
    static let geometryEnvironmentKey = "DARKBLOOM_GLM_MEDIA_GEOMETRY_RESERVATION"

    static func pricesGeometry(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switchIsOn(geometryEnvironmentKey, environment)
    }

    /// Exact `0`, `false`, `no` or `off` (trimmed, case-insensitive), read
    /// when the model loads, keeps the artifact's own video token budget, so
    /// the processor refuses a clip whose 2 FPS sample passes the prepared-
    /// pixel cap, as 0.10.13 did.
    static let longVideoFitEnvironmentKey = "DARKBLOOM_GLM_LONG_VIDEO_FIT"

    static func fitsLongVideos(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switchIsOn(longVideoFitEnvironmentKey, environment)
    }

    /// `processor` with its video token budget lowered to the features its
    /// prepared-pixel cap admits (`maximumPreparedFeatures`, 28,532 at patch
    /// 14; the artifact's 240,000 never binds first), so the official resize
    /// shrinks a clip whose 2 FPS sample would pass the cap instead of the
    /// processor refusing it. A clip within the cap renders as before.
    static func fittingLongVideos(
        _ processor: GLM5NextProcessorConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GLM5NextProcessorConfiguration {
        let features = maximumPreparedFeatures(processor: processor)
        guard fitsLongVideos(environment: environment), features < processor.videoMaximumTokens,
            features >= processor.videoMinimumTokens
        else { return processor }
        return try .init(
            patchSize: processor.patchSize, imageMinimumTokens: processor.imageMinimumTokens,
            imageMaximumTokens: processor.imageMaximumTokens,
            videoMinimumTokens: processor.videoMinimumTokens, videoMaximumTokens: features,
            maximumDecodedBytes: processor.maximumDecodedBytes,
            maximumPreparedBytes: processor.maximumPreparedBytes,
            videoSamplingPolicy: processor.videoSamplingPolicy,
            fitsVideoSampleToDecodedBytes: processor.fitsVideoSampleToDecodedBytes)
    }

    /// Exact `0`, `false`, `no` or `off` (trimmed, case-insensitive), read
    /// when the model loads, keeps the official 2 FPS sample whole, so the
    /// processor refuses a clip whose sample passes the decoded-frame cap, as
    /// 0.10.14 did.
    static let longVideoSamplingEnvironmentKey = "DARKBLOOM_GLM_LONG_VIDEO_SAMPLING"

    static func samplesLongVideos(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        switchIsOn(longVideoSamplingEnvironmentKey, environment)
    }

    /// `processor` sampling a clip whose official 2 FPS sample passes the
    /// decoded-frame cap down to the frames the cap holds, spread over the
    /// whole clip (`fitsVideoSampleToDecodedBytes`), instead of refusing it.
    /// A single Mac's only: a pair's rank 0 prepares the clip with the
    /// leader's wire budgets, which carry no sampling option.
    static func samplingLongVideos(
        _ processor: GLM5NextProcessorConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> GLM5NextProcessorConfiguration {
        guard samplesLongVideos(environment: environment), !processor.fitsVideoSampleToDecodedBytes
        else { return processor }
        return try .init(
            patchSize: processor.patchSize, imageMinimumTokens: processor.imageMinimumTokens,
            imageMaximumTokens: processor.imageMaximumTokens,
            videoMinimumTokens: processor.videoMinimumTokens,
            videoMaximumTokens: processor.videoMaximumTokens,
            maximumDecodedBytes: processor.maximumDecodedBytes,
            maximumPreparedBytes: processor.maximumPreparedBytes,
            videoSamplingPolicy: processor.videoSamplingPolicy, fitsVideoSampleToDecodedBytes: true)
    }

    private static func switchIsOn(_ key: String, _ environment: [String: String]) -> Bool {
        guard let raw = environment[key] else { return true }
        return !["0", "false", "no", "off"].contains(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Working memory of one media preparation that no per-patch term covers
    /// (graph and kernel workspace): measured on GLM-5.3-Flash NVFP4 on an M5
    /// Ultra, a 256 x 256 image's preparation peaked 78.7 MB of MLX memory over
    /// its start against a 68 MB quote without it, a 720p image's 0.38 GiB
    /// against 0.76 GiB. Charged once a request; it covers that peak 1.7x.
    static let fixedWorkingBytes: UInt64 = 128 << 20

    /// Host decode frames, beyond its kept sample, that a video's reader and
    /// renderer may hold at once: decoder output buffers in flight plus the
    /// RGBA render of the frame being converted, each 4 bytes a pixel.
    static let videoDecodeTransientFrames = 24

    /// Conservative FP32 bytes live while the tower runs one frame of
    /// `patches` patches: input, residual stream, QKV and its head-major
    /// copies, one score plus one probability tile, attention output, the
    /// SwiGLU MLP and the merger. Frames run sequentially, so only one counts.
    static func towerWorkingSetBytes(
        configuration c: GLM5NextVisionConfiguration, patches: Int = maximumFramePatches,
        queryTile: Int = 128
    ) -> UInt64 {
        let n = UInt64(max(0, patches))
        let merged = n / 4
        let elements: [UInt64] = [
            n * UInt64(c.inChannels * c.temporalPatchSize * c.patchSize * c.patchSize),
            2 * n * UInt64(c.hiddenSize),
            6 * n * UInt64(c.hiddenSize),
            2 * UInt64(c.numHeads) * UInt64(min(queryTile, patches)) * n,
            2 * n * UInt64(c.hiddenSize),
            3 * n * UInt64(c.intermediateSize),
            3 * merged * UInt64(c.projectionIntermediateSize),
            2 * merged * UInt64(c.outHiddenSize),
        ]
        return elements.reduce(0) { total, count in
            let (bytes, multiplyOverflow) = count.multipliedReportingOverflow(by: 4)
            let (sum, addOverflow) = total.addingReportingOverflow(bytes)
            return multiplyOverflow || addOverflow ? .max : sum
        }
    }

    /// The media gate's whole charge for one GLM request. `generic` is the
    /// scheduler's model-agnostic projection (header-priced decode, default
    /// token allotments). Each image is priced from its header and each video
    /// from its container through the processor's resize plan; a request with
    /// any part that can't be read that way, or with the switch off, adds the
    /// processor's ceilings to `generic` instead (`reservation`).
    static func mediaReservation(
        container: ModelContainer, request: OpenAIChatCompletionRequest,
        defaultMaxTokens: Int, contextLength: Int, generic: Reservation
    ) async -> Reservation {
        let loaded = await container.perform { context
            -> (vision: GLM5NextVisionConfiguration, processor: GLM5NextProcessorConfiguration)? in
            guard let root = context.model as? GLM5NextModel,
                let processor = context.processor as? GLM5NextProcessor
            else { return nil }
            return (root.configuration.visionConfig, processor.configuration)
        }
        guard let loaded else { return generic }
        return await mediaReservation(
            request: request, vision: loaded.vision, processor: loaded.processor,
            defaultMaxTokens: defaultMaxTokens, contextLength: contextLength, generic: generic)
    }

    static func mediaReservation(
        request: OpenAIChatCompletionRequest, vision: GLM5NextVisionConfiguration,
        processor: GLM5NextProcessorConfiguration, defaultMaxTokens: Int, contextLength: Int,
        generic: Reservation, environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Reservation {
        if pricesGeometry(environment: environment), let shapes = await GLM5NextMediaShapes.probe(request),
            let priced = reservation(
                request: request, shapes: shapes, vision: vision, processor: processor,
                defaultMaxTokens: defaultMaxTokens, contextLength: contextLength)
        {
            return priced
        }
        let ceiling = reservation(
            request: request, vision: vision, processor: processor,
            defaultMaxTokens: defaultMaxTokens, contextLength: contextLength)
        return .init(
            bytes: saturating([generic.bytes, ceiling.bytes]),
            kvTokens: max(generic.kvTokens, ceiling.kvTokens))
    }

    /// Prices `shapes`, the request's media in order, from their own
    /// geometry. Bytes: the image decode the generic projection charges
    /// (stored pixels at the decode overhead), every item's encoded bytes
    /// and the larger video decode (videos decode one at a time: the kept
    /// sample at RGB8, twice for a second reader pass, plus the transient
    /// frames), three copies of the prepared patches (the processor's host
    /// values, its per-item arrays and their concatenation), the largest
    /// frame's tower working set, a fixed working allowance and every
    /// feature at FP32. Tokens: the prompt's text contents, tools JSON and a
    /// template allowance (`textTokens`; assistant tool calls and reasoning
    /// are not counted) plus every item's rendered tokens, within the context,
    /// plus output; the bridge admits the prompt's real token count again at
    /// submission. `nil` when an item is one the processor refuses.
    static func reservation(
        request: OpenAIChatCompletionRequest, shapes: GLM5NextMediaShapes,
        vision: GLM5NextVisionConfiguration, processor: GLM5NextProcessorConfiguration,
        defaultMaxTokens: Int, contextLength: Int
    ) -> Reservation? {
        var items: [GLM5NextMediaQuote] = []
        var encoded: UInt64 = 0
        for image in shapes.images {
            guard let quote = GLM5NextMediaQuote.image(image.size, processor: processor) else { return nil }
            items.append(quote)
            encoded = saturating([encoded, UInt64(image.encodedBytes)])
        }
        var videoDecode: UInt64 = 0
        for video in shapes.videos {
            guard let quote = GLM5NextMediaQuote.video(video, processor: processor) else { return nil }
            items.append(quote)
            let pixels = UInt64(video.sizes.map { $0.width * $0.height }.max() ?? 0)
            let sampled = UInt64(GLM5NextMediaQuote.sampledFrames(durationSeconds: video.durationSeconds))
            let kept = min(UInt64(processor.maximumDecodedBytes), sampled * pixels * 3)
            let transient = UInt64(videoDecodeTransientFrames) * pixels * 4
            videoDecode = max(videoDecode, saturating([saturating(kept, times: 2), transient]))
            encoded = saturating([encoded, UInt64(video.encodedBytes)])
        }
        let imagePixels = min(
            saturating(shapes.images.map { UInt64($0.size.width) * UInt64($0.size.height) }),
            UInt64(max(0, MediaIngest.maxRequestImagePixels)))
        let prepared = min(
            saturating(items.map { UInt64($0.preparedBytes) }), UInt64(processor.maximumPreparedBytes))
        let mediaTokens = saturating(items.map { UInt64($0.tokens) })
        let framePatches = min(items.map(\.framePatches).max() ?? 0, maximumFramePatches)
        let bytes = saturating([
            saturating(imagePixels, times: UInt64(4 * MediaIngest.decodeOverheadFactor)),
            encoded, videoDecode, saturating(prepared, times: 3),
            towerWorkingSetBytes(configuration: vision, patches: framePatches), fixedWorkingBytes,
            saturating(mediaTokens, times: UInt64(vision.outHiddenSize) * 4),
        ])
        var promptTokens = saturating([textTokens(request), mediaTokens])
        if contextLength > 0 { promptTokens = min(promptTokens, UInt64(contextLength)) }
        let output = UInt64(max(0, MediaIngest.resolveMaxOutputTokens(
            for: request, defaultMaxTokens: defaultMaxTokens)))
        let tokens = saturating([promptTokens, output])
        return .init(bytes: bytes, kvTokens: Int(clamping: tokens))
    }

    /// The prompt's text tokens: every text content and text part and the
    /// declared tools' JSON, at `textCharsPerToken` UTF-8 bytes a token (the
    /// generic estimate), plus an allowance for GLM's chat template.
    private static func textTokens(_ request: OpenAIChatCompletionRequest) -> UInt64 {
        var texts: [String] = []
        for message in request.messages {
            switch message.content {
            case .text(let text): texts.append(text)
            case .parts(let parts):
                for case .text(let text) in parts { texts.append(text) }
            case .null: continue
            }
        }
        let tools = request.tools.flatMap { try? JSONEncoder().encode($0) }?.count ?? 0
        let template = saturating(
            UInt64(request.messages.count), times: UInt64(templateTokensPerMessage))
        return saturating(
            texts.map { UInt64($0.utf8.count / MediaIngest.textCharsPerToken) }
                + [UInt64(tools / MediaIngest.textCharsPerToken), UInt64(templateTokens), template])
    }

    /// GLM's chat template beyond the text: role and think markers and, with
    /// tools, its ~80-token tool preamble. Measured: a one-turn image request
    /// renders 7 tokens more than its text at the generic rate.
    static let templateTokens = 64
    static let templateTokensPerMessage = 16

    private static func saturating(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }

    private static func saturating(_ value: UInt64, times factor: UInt64) -> UInt64 {
        let (product, overflow) = value.multipliedReportingOverflow(by: factor)
        return overflow ? .max : product
    }

    /// Features the processor's prepared-pixel cap admits across one request
    /// (28,532 at patch 14), within the video token budget.
    static func maximumPreparedFeatures(processor: GLM5NextProcessorConfiguration) -> Int {
        let featureBytes = 4 * 6 * processor.patchSize * processor.patchSize * MemoryLayout<Float>.size
        return min(processor.videoMaximumTokens, processor.maximumPreparedBytes / featureBytes)
    }

    /// UTF-8 bytes of the longest `%.1f seconds` timestamp up to `seconds`;
    /// byte-level BPE emits at most one token per byte.
    static func timestampBytes(seconds: Double) -> Int {
        String(format: "%.1f seconds", locale: Locale(identifier: "en_US_POSIX"), seconds).utf8.count
    }

    /// Upper bound on one video's rendered tokens: the processor's prepared-
    /// feature cap, plus per temporal pair its begin/end image tokens and
    /// `%.1f seconds` timestamp (byte-level BPE emits at most one token per
    /// UTF-8 byte), plus the video's own begin/end tokens. Frames are sampled
    /// at 2 FPS over at most the duration cap and 2048 frames, plus an even
    /// final pair and one second of track/asset duration slack.
    static func videoTokenCeiling(
        processor: GLM5NextProcessorConfiguration,
        maxDurationSeconds: Double = MediaIngest.maxVideoDurationSeconds
    ) -> Int {
        let features = maximumPreparedFeatures(processor: processor)
        let seconds = max(0, maxDurationSeconds)
        let pairs = min(features, Int(min(seconds, 1024).rounded(.up)) + 2)
        return features + pairs * (2 + timestampBytes(seconds: seconds + 1)) + 2
    }

    /// The processor's ceilings: prepared pixels and the decoded-frame cap
    /// in full, a full-size tower frame, and every image and video at its
    /// token cap. The generic projection's decode charge is added by the caller.
    static func reservation(
        request: OpenAIChatCompletionRequest, vision: GLM5NextVisionConfiguration,
        processor: GLM5NextProcessorConfiguration, defaultMaxTokens: Int, contextLength: Int
    ) -> Reservation {
        var images = 0
        var videos = 0
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                if case .imageURL = part { images += 1 }
                if case .videoURL = part { videos += 1 }
            }
        }
        // `projectedKVTokens` allots `visionTokensPerImage` per image and
        // `visionTokensPerVideo` per video; a GLM image renders begin/end
        // tokens around up to `imageMaximumTokens`, a video its token ceiling.
        let extraPerImage = max(0, processor.imageMaximumTokens + 2 - MediaIngest.visionTokensPerImage)
        let extraPerVideo = max(0, videoTokenCeiling(processor: processor) - MediaIngest.visionTokensPerVideo)
        let base = MediaIngest.projectedKVTokens(
            request, defaultMaxTokens: defaultMaxTokens, contextLength: contextLength)
        let (imageExtra, imageOverflow) = images.multipliedReportingOverflow(by: extraPerImage)
        let (videoExtra, videoOverflow) = videos.multipliedReportingOverflow(by: extraPerVideo)
        let (extra, extraOverflow) = imageExtra.addingReportingOverflow(videoExtra)
        var (tokens, overflow) = base.addingReportingOverflow(extra)
        if imageOverflow || videoOverflow || extraOverflow || overflow { tokens = .max }
        if contextLength > 0 {
            let output = max(0, MediaIngest.resolveMaxOutputTokens(
                for: request, defaultMaxTokens: defaultMaxTokens))
            let (ceiling, ceilingOverflow) = contextLength.addingReportingOverflow(output)
            if !ceilingOverflow { tokens = min(tokens, ceiling) }
        }
        // A video's decoded RGB8 frames stay live while its pairs are prepared.
        // Videos are decoded one at a time, so one cap covers any video count.
        let decodedBytes = videos > 0 ? UInt64(processor.maximumDecodedBytes) : 0
        let bytes = saturating([
            UInt64(processor.maximumPreparedBytes), towerWorkingSetBytes(configuration: vision),
            decodedBytes,
        ])
        return .init(bytes: bytes, kvTokens: tokens)
    }
}
