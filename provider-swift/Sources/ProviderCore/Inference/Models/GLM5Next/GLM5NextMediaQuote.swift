import CoreGraphics
import Foundation
import MLXLMCommon
import MLXLMServer
import MLXVLM

/// What one image or video costs GLM's media preparation, priced before any
/// decode from its header or container through the processor's own resize
/// plan (`GLM5NextMediaGeometry.resizePlan`).
struct GLM5NextMediaQuote: Equatable {
    /// Prompt tokens it renders: its features and begin/end tokens plus, for
    /// a video, each frame pair's begin/end tokens and timestamp.
    let tokens: Int
    /// Patches of its largest tower frame (a still image or one frame pair).
    let framePatches: Int
    /// FP32 patches the processor prepares for it.
    let preparedBytes: Int

    /// A still image of `width` x `height` stored pixels, in either display
    /// orientation, as `GLM5NextProcessor.prepareImage` renders it.
    static func image(
        width: Int, height: Int, processor: GLM5NextProcessorConfiguration
    ) -> GLM5NextMediaQuote? {
        var quote: GLM5NextMediaQuote?
        for (w, h) in [(width, height), (height, width)] {
            // Begin/end image tokens around its features.
            guard let plan = try? GLM5NextMediaGeometry.resizePlan(
                width: w, height: h, frames: 2, patchSize: processor.patchSize,
                minimumTokens: processor.imageMinimumTokens,
                maximumTokens: processor.imageMaximumTokens),
                let item = make(plan.grid, delimiters: 2, processor: processor)
            else { return nil }
            quote = quote.map { $0.covering(item) } ?? item
        }
        return quote
    }

    /// One clip, as the coordinator's `glmVideoTokens` prices it: the 2 FPS
    /// sample reads one second past the container's duration, so the frames
    /// the processor keeps (deduplicated, an odd count padded to a pair) are
    /// an even count no larger than `sampled`, whatever the track's frame rate. The 16-token minimum enlarges
    /// a small frame more when fewer frames share it, so tokens are not
    /// monotonic in the count: every even count and both display
    /// orientations of every coded size are priced, and the largest wins.
    /// `nil` for a clip the processor refuses (over the duration cap or the
    /// prepared-feature cap).
    static func video(
        _ shape: GLM5NextMediaShapes.Video, processor: GLM5NextProcessorConfiguration,
        maximumDurationSeconds: Double = MediaIngest.maxVideoDurationSeconds
    ) -> GLM5NextMediaQuote? {
        guard shape.durationSeconds <= maximumDurationSeconds else { return nil }
        let sampled = sampledFrames(durationSeconds: shape.durationSeconds)
        let timestampBytes = GLM5NextVisionBudget.timestampBytes(seconds: shape.durationSeconds + 1)
        let maximumFeatures = GLM5NextVisionBudget.maximumPreparedFeatures(processor: processor)
        var quote: GLM5NextMediaQuote?
        for size in shape.sizes {
            for (w, h) in [(size.width, size.height), (size.height, size.width)] {
                for frames in stride(from: 2, through: sampled, by: 2) {
                    // Per frame pair, begin/end image tokens and its timestamp;
                    // then the video's own begin/end tokens.
                    guard let plan = try? GLM5NextMediaGeometry.resizePlan(
                        width: w, height: h, frames: frames, patchSize: processor.patchSize,
                        minimumTokens: processor.videoMinimumTokens,
                        maximumTokens: processor.videoMaximumTokens),
                        let features = try? plan.grid.featureCount(), features <= maximumFeatures,
                        let item = make(
                            plan.grid, delimiters: plan.grid.temporal * (2 + timestampBytes) + 2,
                            processor: processor)
                    else { return nil }
                    quote = quote.map { $0.covering(item) } ?? item
                }
            }
        }
        return quote
    }

    /// The most frames the processor keeps of a clip this long: 2 FPS over
    /// one second past its duration, an even count, at most 2048.
    static func sampledFrames(durationSeconds: Double) -> Int {
        let frames = min((durationSeconds + 1) * 2, 2048).rounded(.down)
        return (Int(frames) + 1) / 2 * 2
    }

    private static func make(
        _ grid: GLM5NextVisionGrid, delimiters: Int, processor: GLM5NextProcessorConfiguration
    ) -> GLM5NextMediaQuote? {
        guard let patches = try? grid.patchCount(), let features = try? grid.featureCount()
        else { return nil }
        let p = processor.patchSize
        let (prepared, overflow) = patches.multipliedReportingOverflow(by: 6 * p * p * 4)
        guard !overflow else { return nil }
        return .init(
            tokens: features + delimiters, framePatches: grid.height * grid.width,
            preparedBytes: prepared)
    }

    private func covering(_ other: GLM5NextMediaQuote) -> GLM5NextMediaQuote {
        .init(
            tokens: max(tokens, other.tokens), framePatches: max(framePatches, other.framePatches),
            preparedBytes: max(preparedBytes, other.preparedBytes))
    }
}

/// The geometry of every image and video in one request, read before any
/// decode: an image's header and a video's container metadata.
struct GLM5NextMediaShapes {
    struct Image: Equatable {
        let width: Int
        let height: Int
    }

    struct Video: Equatable {
        /// The track's coded and natural sizes; the processor renders one.
        let sizes: [Image]
        let durationSeconds: Double
        /// Encoded bytes, held in memory while the request is prepared.
        let encodedBytes: Int
    }

    let images: [Image]
    let videos: [Video]

    /// `nil` when any part is not a readable inline image or single-track
    /// video, or is another kind of media: the request then keeps the
    /// processor's ceilings.
    static func probe(_ request: OpenAIChatCompletionRequest) async -> GLM5NextMediaShapes? {
        var images: [Image] = []
        var videos: [Video] = []
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                switch part {
                case .text: continue
                case .imageURL(let uri):
                    guard let image = image(uri) else { return nil }
                    images.append(image)
                case .videoURL(let uri):
                    guard let video = await video(uri) else { return nil }
                    videos.append(video)
                case .inputAudio, .unsupported: return nil
                }
            }
        }
        return .init(images: images, videos: videos)
    }

    private static func image(_ uri: String) -> Image? {
        guard uri.hasPrefix("data:"), let data = try? MediaIngest.dataFromDataURI(uri),
            let size = MediaIngest.imagePixelSize(data)
        else { return nil }
        return .init(width: size.width, height: size.height)
    }

    private static func video(_ uri: String) async -> Video? {
        guard uri.hasPrefix("data:"), let data = try? MediaIngest.dataFromDataURI(uri),
            let asset = try? MemoryBackedVideoAsset(videoData: data),
            let metadata = try? await MediaProcessing.metadata(for: asset),
            metadata.tracks.count == 1, let track = metadata.tracks.first
        else { return nil }
        let seconds = metadata.duration.seconds
        let sizes = (track.decodedFrameDimensions + [track.naturalSize].compactMap { $0 })
            .compactMap(pixelSize)
        guard seconds.isFinite, seconds > 0, !sizes.isEmpty else { return nil }
        return .init(sizes: sizes, durationSeconds: seconds, encodedBytes: data.count)
    }

    private static func pixelSize(_ size: CGSize) -> Image? {
        let width = abs(size.width).rounded(.up)
        let height = abs(size.height).rounded(.up)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
            width <= 65536, height <= 65536
        else { return nil }
        return .init(width: Int(width), height: Int(height))
    }
}
