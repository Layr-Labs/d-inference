// Copyright © 2026 Eigen Labs.

@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MLXVLM

/// Inline MP4/QuickTime input of the Super video binding, sampled as NVIDIA's
/// reference serving samples it (vLLM's OpenCV loader at 2 fps, at most 256
/// frames): the source frame count and rate come from the complete
/// compressed-sample table, frames count in presentation order, and each
/// sampled frame is RGB8 with the track's rotation applied, then resized and
/// normalized exactly as an image at the SDK's frame grid. No plaintext file,
/// remote URL or HDR tone mapping. Follows the MiMo AVAssetReader sampler.
enum NemotronSuperVideoDecode {
    enum Failure: Error, Equatable {
        /// Not one readable video track, or AVFoundation refused the movie.
        case invalidVideo
        /// HDR transfer, a mirroring transform, frame sizes that change, or
        /// a decoded pixel layout other than BGRA.
        case unsupportedRepresentation
        /// Beyond the coded frame, frame grid, source frame or control-marker
        /// ceiling.
        case limit
        /// Decoded frames disagree with the inspected track.
        case inconsistentFrames
    }

    /// Ten minutes at 60 fps.
    static let maximumSourceFrames = 36_000
    static let maximumControlMarkers = 4_096

    struct Plan: Sendable {
        let sourceFrames: Int
        let sourceFPS: Double
        /// Sampled source frames, in presentation order.
        let frameIndices: [Int]
        /// One per tubelet, the exact upstream text.
        let labels: [String]
        let codedWidth: Int
        let codedHeight: Int
        /// Frame size after the track's rotation.
        let width: Int
        let height: Int
        let grid: NemotronSuperImagePreprocessing.Grid
        fileprivate let rotation: Rotation
        fileprivate let asset: NemotronSuperVideoAsset

        var codedPixels: Int { codedWidth * codedHeight }
        /// The retained decoded copy of the movie.
        var encodedBytes: Int { asset.byteCount }
        /// Frame pairs; an odd last frame is paired with itself.
        var tubelets: Int { (frameIndices.count + 1) / 2 }
    }

    /// The transforms the reference decoder honors: none and the three
    /// rotations. A mirroring transform is refused rather than ignored.
    fileprivate enum Rotation: Sendable {
        case none, half, clockwise, counterClockwise

        init(_ transform: CGAffineTransform) throws {
            func unit(_ value: CGFloat) -> Int? {
                guard abs(value) <= 1 else { return nil }
                let rounded = value.rounded()
                return abs(value - rounded) < 1e-6 ? Int(rounded) : nil
            }
            guard let a = unit(transform.a), let b = unit(transform.b),
                let c = unit(transform.c), let d = unit(transform.d)
            else { throw Failure.unsupportedRepresentation }
            switch (a, b, c, d) {
            case (1, 0, 0, 1): self = .none
            case (-1, 0, 0, -1): self = .half
            case (0, 1, -1, 0): self = .clockwise
            case (0, -1, 1, 0): self = .counterClockwise
            default: throw Failure.unsupportedRepresentation
            }
        }

        var swapsAxes: Bool { self == .clockwise || self == .counterClockwise }

        /// The coded pixel shown at (x, y) of the rotated frame.
        func source(x: Int, y: Int, width: Int, height: Int) -> (x: Int, y: Int) {
            switch self {
            case .none: return (x, y)
            case .half: return (width - 1 - x, height - 1 - y)
            case .clockwise: return (y, height - 1 - x)
            case .counterClockwise: return (width - 1 - y, x)
            }
        }
    }

    /// The shared inline ingest first (data URI label, decoded byte cap,
    /// container shape, duration and coded frame size), then the frame plan
    /// from the compressed samples alone; nothing is decoded here.
    static func inspect(_ uri: String) async throws -> Plan {
        let pixelCap = min(MediaIngest.maxImagePixels, NemotronSuperServingPolicy.maximumVideoFramePixels)
        _ = try await MediaIngest.decodeVideo(uri, maxFramePixels: pixelCap)
        let asset = try NemotronSuperVideoAsset(videoData: try MediaIngest.dataFromDataURI(uri))
        return try await reading {
            try await asset.withAsset { (movie: AVURLAsset) async throws -> Plan in
                let track = try await videoTrack(movie)
                var coded: (width: Int, height: Int)?
                for description in try await track.load(.formatDescriptions) {
                    let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any]
                    let transfer = extensions?[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                    guard transfer != (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String),
                        transfer != (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
                    else { throw Failure.unsupportedRepresentation }
                    let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                    let size = (width: Int(dimensions.width), height: Int(dimensions.height))
                    guard size.width > 0, size.height > 0 else { throw Failure.invalidVideo }
                    if let coded, coded.width != size.width || coded.height != size.height {
                        throw Failure.unsupportedRepresentation
                    }
                    coded = size
                }
                guard let coded else { throw Failure.invalidVideo }
                let (pixels, overflow) = coded.width.multipliedReportingOverflow(by: coded.height)
                guard !overflow, pixels <= pixelCap else { throw Failure.limit }
                let rotation = try Rotation(try await track.load(.preferredTransform))
                let timing = try sampleTiming(movie, track: track)
                let indices = try NemotronSuperVideoPreprocessing.sampledFrameIndices(
                    totalFrames: timing.frames, sourceFPS: timing.fps)
                let width = rotation.swapsAxes ? coded.height : coded.width
                let height = rotation.swapsAxes ? coded.width : coded.height
                let grid = try NemotronSuperVideoPreprocessing.frameGrid(width: width, height: height)
                guard grid.widthPatches * grid.heightPatches <= NemotronSuperServingPolicy.maximumVideoGridPatches
                else { throw Failure.limit }
                return Plan(sourceFrames: timing.frames, sourceFPS: timing.fps, frameIndices: indices,
                    labels: NemotronSuperVideoPreprocessing.tubeletLabels(frameIndices: indices,
                                                                          sourceFPS: timing.fps),
                    codedWidth: coded.width, codedHeight: coded.height, width: width, height: height,
                    grid: grid, rotation: rotation, asset: asset)
            }
        }
    }

    /// AVFoundation errors may describe the media; they leave as `invalidVideo`.
    fileprivate static func reading<Result>(_ body: () async throws -> Result) async throws -> Result {
        do {
            return try await body()
        } catch let error as Failure {
            throw error
        } catch let error as NemotronSuperVideoPreprocessing.Failure {
            throw error
        } catch let error as NemotronSuperImagePreprocessing.Failure {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.invalidVideo
        }
    }

    fileprivate static func videoTrack(_ movie: AVAsset) async throws -> AVAssetTrack {
        try Task.checkCancellation()
        let tracks = try await movie.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { throw Failure.unsupportedRepresentation }
        return track
    }

    /// The stream metadata vLLM's OpenCV loader reads from FFmpeg: the sample
    /// count, and the rate as that count over the summed sample durations
    /// (`avg_frame_rate`). One division of the exact rational keeps an
    /// integral rate exact, so `int(1000 / fps)` steps match. Like FFmpeg's
    /// demuxer, a zero-duration last sample counts as a frame and adds no
    /// time; a zero duration anywhere else is refused.
    private static func sampleTiming(_ movie: AVAsset, track: AVAssetTrack) throws -> (frames: Int, fps: Double) {
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        // Samples are only read, never modified in place.
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.invalidVideo }
        reader.add(output)
        guard reader.startReading() else { throw Failure.invalidVideo }
        defer { reader.cancelReading() }
        var frames = 0
        var markers = 0
        var duration = CMTime.zero
        var sawZeroDuration = false
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let sample = output.copyNextSampleBuffer() else { return false }
            try Task.checkCancellation()
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else {
                markers += 1
                guard markers <= maximumControlMarkers else { throw Failure.limit }
                return true
            }
            let span = CMSampleBufferGetDuration(sample)
            guard !sawZeroDuration, span.isNumeric, span >= .zero else { throw Failure.invalidVideo }
            sawZeroDuration = span == .zero
            frames += count
            guard frames <= maximumSourceFrames else { throw Failure.limit }
            duration = CMTimeAdd(duration, span)
            guard duration.isNumeric else { throw Failure.invalidVideo }
            return true
        }) {}
        guard reader.status == .completed, frames > 0, duration.value > 0, duration.timescale > 0 else {
            throw Failure.invalidVideo
        }
        let fps = Double(frames) * Double(duration.timescale) / Double(duration.value)
        guard fps.isFinite, fps > 0 else { throw Failure.invalidVideo }
        return (frames, fps)
    }

    /// The plan's sampled frames in order, normalized CHW at its grid; after
    /// an odd count the last frame repeats once to complete its tubelet.
    /// Each frame decodes on the caller's thread when it is pulled, so only
    /// the frame in hand and the caller's batch are resident.
    final class Frames {
        let plan: Plan
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private var index = 0
        private var markers = 0
        private var lastPresentation: CMTime?
        private var produced = 0
        private var last: [Float]?

        init(_ plan: Plan) async throws {
            let movie = plan.asset.retainedAsset
            let (reader, output) = try await NemotronSuperVideoDecode.reading {
                () async throws -> (AVAssetReader, AVAssetReaderTrackOutput) in
                let track = try await NemotronSuperVideoDecode.videoTrack(movie)
                let reader = try AVAssetReader(asset: movie)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                ])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw Failure.invalidVideo }
                reader.add(output)
                guard reader.startReading() else { throw Failure.invalidVideo }
                return (reader, output)
            }
            self.plan = plan
            self.reader = reader
            self.output = output
        }

        deinit { reader.cancelReading() }

        /// The next normalized frame; nil after the last.
        func next() throws -> [Float]? {
            let sampled = plan.frameIndices.count
            if produced >= sampled {
                guard produced == sampled, let last else { return nil }
                self.last = nil
                produced += 1
                return last
            }
            while true {
                try Task.checkCancellation()
                let frame = try autoreleasepool { () throws -> [Float]? in
                    // A reader that stops early has failed or lost frames.
                    guard let sample = output.copyNextSampleBuffer() else { throw Failure.inconsistentFrames }
                    let count = CMSampleBufferGetNumSamples(sample)
                    guard count > 0 else {
                        markers += 1
                        guard markers <= NemotronSuperVideoDecode.maximumControlMarkers else { throw Failure.limit }
                        return nil
                    }
                    guard count == 1, index < plan.sourceFrames else { throw Failure.inconsistentFrames }
                    let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard presentation.isNumeric, lastPresentation.map({ presentation > $0 }) ?? true else {
                        throw Failure.inconsistentFrames
                    }
                    lastPresentation = presentation
                    defer { index += 1 }
                    guard index == plan.frameIndices[produced] else { return nil }
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure.invalidVideo }
                    return try normalized(buffer)
                }
                guard let frame else { continue }
                produced += 1
                if produced == sampled, sampled % 2 == 1 { last = frame }
                return frame
            }
        }

        private func normalized(_ buffer: CVPixelBuffer) throws -> [Float] {
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
                throw Failure.unsupportedRepresentation
            }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            guard width == plan.codedWidth, height == plan.codedHeight, stride >= width * 4 else {
                throw Failure.inconsistentFrames
            }
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                throw Failure.invalidVideo
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.invalidVideo }
            let source = base.assumingMemoryBound(to: UInt8.self)
            let outWidth = plan.width
            let outHeight = plan.height
            let rotation = plan.rotation
            var rgb = [UInt8](repeating: 0, count: outWidth * outHeight * 3)
            try rgb.withUnsafeMutableBufferPointer { destination in
                for y in 0 ..< outHeight {
                    if y.isMultiple(of: 64) { try Task.checkCancellation() }
                    for x in 0 ..< outWidth {
                        let pixel = rotation.source(x: x, y: y, width: width, height: height)
                        let from = pixel.y * stride + pixel.x * 4
                        let to = (y * outWidth + x) * 3
                        destination[to] = source[from + 2]
                        destination[to + 1] = source[from + 1]
                        destination[to + 2] = source[from]
                    }
                }
            }
            return try NemotronSuperImagePreprocessing.normalizeRGB(rgb, width: outWidth, height: outHeight,
                targetWidth: plan.grid.width, targetHeight: plan.grid.height)
        }
    }
}
