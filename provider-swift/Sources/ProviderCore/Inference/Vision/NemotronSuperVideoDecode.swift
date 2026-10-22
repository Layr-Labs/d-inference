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
        /// HDR transfer, a codec outside `admittedCodecs`, a mirroring
        /// transform, frame sizes that change, or a decoded pixel layout
        /// other than BGRA.
        case unsupportedRepresentation
        /// Beyond the coded frame, frame grid, source frame, control-marker
        /// or decoded-pixel ceiling, or a decoder that outlasted its
        /// `decodeAllowance`.
        case limit
        /// Decoded frames disagree with the inspected track.
        case inconsistentFrames
    }

    /// Ten minutes at 60 fps.
    static let maximumSourceFrames = 36_000
    static let maximumControlMarkers = 4_096
    /// Every frame up to the last sampled one is decoded and converted to
    /// BGRA, sampled or not, so this bounds the decoder's work: ten minutes
    /// of 30 fps 1080p (18,000 frames of 1,920 x 1,088 coded pixels). A
    /// 4096 x 2160 movie may decode 4,250 frames (2 min 21 s at 30 fps).
    static let maximumDecodedPixels = 18_000 * 1_920 * 1_088
    /// H.264 (`avc1`) and HEVC (`hvc1`), which Apple silicon decodes in
    /// hardware. The in-band parameter-set entries (`avc3`, `hev1`) are
    /// refused with every other codec before a frame decodes: AVFoundation
    /// does not decode them here, and in-band parameter sets could change a
    /// frame's size after inspection.
    static let admittedCodecs: Set<FourCharCode> = [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC]

    /// The wall time `Frames` may spend waiting on the decoder for `frames`
    /// frames of `codedPixels`: five seconds, then 2 ms a frame and 4 ns a
    /// coded pixel (ten times the 0.2 ms a frame and 0.4 ns a pixel an M3
    /// Ultra measured decoding H.264 and HEVC to BGRA), two minutes at most.
    /// Normalization and the tower do not count.
    static func decodeAllowance(frames: Int, codedPixels: Int) -> Duration {
        let perFrame = Duration.milliseconds(2) + .nanoseconds(4) * codedPixels
        return min(.seconds(120), .seconds(5) + perFrame * frames)
    }

    /// Tests only: runs once for each reader, right after it is cancelled,
    /// with that reader, so a test can count stops and watch the reader be
    /// released. Read when the reader is set up.
    @TaskLocal static var readerCancelledForTesting: (@Sendable (AVAssetReader) -> Void)?

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
        /// Frames the decoder produces: every one up to the last sampled.
        var decodedFrames: Int { frameIndices[frameIndices.count - 1] + 1 }
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
    /// from the compressed samples alone; nothing is decoded here. A plan
    /// whose decoded frames hold more than `decodedPixelBudget` pixels is
    /// refused.
    static func inspect(_ uri: String, decodedPixelBudget: Int = maximumDecodedPixels) async throws -> Plan {
        let pixelCap = min(MediaIngest.maxImagePixels, NemotronSuperServingPolicy.maximumVideoFramePixels)
        _ = try await MediaIngest.decodeVideo(uri, maxFramePixels: pixelCap)
        let asset = try NemotronSuperVideoAsset(videoData: try MediaIngest.dataFromDataURI(uri))
        return try await reading {
            try await asset.withAsset { (movie: AVURLAsset) async throws -> Plan in
                let track = try await videoTrack(movie)
                var coded: (width: Int, height: Int)?
                for description in try await track.load(.formatDescriptions) {
                    guard admittedCodecs.contains(CMFormatDescriptionGetMediaSubType(description)) else {
                        throw Failure.unsupportedRepresentation
                    }
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
                let timing = try await sampleTiming(movie, track: track, source: asset)
                let indices = try NemotronSuperVideoPreprocessing.sampledFrameIndices(
                    totalFrames: timing.frames, sourceFPS: timing.fps)
                let width = rotation.swapsAxes ? coded.height : coded.width
                let height = rotation.swapsAxes ? coded.width : coded.height
                let grid = try NemotronSuperVideoPreprocessing.frameGrid(width: width, height: height)
                guard grid.widthPatches * grid.heightPatches <= NemotronSuperServingPolicy.maximumVideoGridPatches
                else { throw Failure.limit }
                let plan = Plan(sourceFrames: timing.frames, sourceFPS: timing.fps, frameIndices: indices,
                    labels: NemotronSuperVideoPreprocessing.tubeletLabels(frameIndices: indices,
                                                                          sourceFPS: timing.fps),
                    codedWidth: coded.width, codedHeight: coded.height, width: width, height: height,
                    grid: grid, rotation: rotation, asset: asset)
                let (decodedPixels, decodedOverflow) = plan.decodedFrames.multipliedReportingOverflow(by: pixels)
                guard !decodedOverflow, decodedPixels <= decodedPixelBudget else { throw Failure.limit }
                return plan
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
    private static func sampleTiming(_ movie: AVAsset, track: AVAssetTrack, source: NemotronSuperVideoAsset)
        async throws -> (frames: Int, fps: Double) {
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        // Samples are only read, never modified in place.
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.invalidVideo }
        reader.add(output)
        guard reader.startReading() else { throw Failure.invalidVideo }
        let samples = SerialReader(reader, output: output, source: source)
        var frames = 0
        var markers = 0
        var duration = CMTime.zero
        var sawZeroDuration = false
        try await samples.cancellable {
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let sample = samples.nextSample() else { return false }
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
        }
        // Cancellation stops the reader early; it is not a malformed movie.
        try Task.checkCancellation()
        guard samples.completed, frames > 0, duration.value > 0, duration.timescale > 0 else {
            throw Failure.invalidVideo
        }
        let fps = Double(frames) * Double(duration.timescale) / Double(duration.value)
        guard fps.isFinite, fps > 0 else { throw Failure.invalidVideo }
        return (frames, fps)
    }

    /// Every decoded frame, sampled or not, must be the inspected coded size
    /// in BGRA, its rows within the 32 bytes a coded pixel and 1 MiB that
    /// the media charge holds for them (part of
    /// `NemotronSuperServingPolicy.videoDecodeBytesPerCodedPixel` and
    /// `videoDecodeAllowanceBytes`): an in-band parameter set could change
    /// any frame.
    static func validateDecodedFrame(_ buffer: CVPixelBuffer, codedWidth: Int, codedHeight: Int) throws {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw Failure.unsupportedRepresentation
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let (bytes, overflow) = stride.multipliedReportingOverflow(by: height)
        guard width == codedWidth, height == codedHeight, stride >= width * 4,
            !overflow, bytes <= width * height * 32 + (1 << 20)
        else { throw Failure.inconsistentFrames }
    }

    /// The plan's sampled frames in order, normalized CHW at its grid; after
    /// an odd count the last frame repeats once to complete its tubelet.
    /// Each frame decodes on the reader's queue while the pulling thread
    /// waits for it, so only the frame in hand and the caller's batch are
    /// resident (and, after a pull gives up, the one read still finishing).
    /// The time spent waiting on the decoder is bounded by `decodeAllowance`;
    /// pull frames inside `withCancellableReader` so cancellation ends a
    /// blocked wait.
    final class Frames {
        let plan: Plan
        private let reader: SerialReader
        private var index = 0
        private var markers = 0
        private var lastPresentation: CMTime?
        private var produced = 0
        private var last: [Float]?

        /// Tests only: runs as each sampled frame starts decoding, on the
        /// pulling thread, so a test can hold a decode in progress.
        @TaskLocal static var beforeFrameDecodeForTesting: (@Sendable () -> Void)?

        /// `decodeAllowance` replaces the plan's
        /// `NemotronSuperVideoDecode.decodeAllowance`.
        init(_ plan: Plan, decodeAllowance: Duration? = nil) async throws {
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
            self.reader = SerialReader(reader, output: output, source: plan.asset, allowance: decodeAllowance
                ?? NemotronSuperVideoDecode.decodeAllowance(frames: plan.decodedFrames,
                                                            codedPixels: plan.codedPixels))
        }

        /// Runs `body`, which pulls frames, with a pull waiting on the
        /// decoder released and the reader stopped as soon as the task is
        /// cancelled, so a slow decode holds neither the media slot nor a
        /// draining owner.
        func withCancellableReader<Result>(_ body: () throws -> Result) async throws -> Result {
            try await reader.cancellable(body)
        }

        /// The next normalized frame; nil after the last.
        func next() throws -> [Float]? {
            let sampled = plan.frameIndices.count
            if produced >= sampled {
                guard produced == sampled, let last else { return nil }
                self.last = nil
                produced += 1
                return last
            }
            Self.beforeFrameDecodeForTesting?()
            // Only the wait for decoded frames counts against the allowance.
            reader.startCharging()
            defer { reader.stopCharging() }
            while true {
                try Task.checkCancellation()
                let frame = try autoreleasepool { () throws -> [Float]? in
                    guard let sample = reader.nextSample() else { throw reader.earlyEnd }
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
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw Failure.invalidVideo }
                    try NemotronSuperVideoDecode.validateDecodedFrame(buffer, codedWidth: plan.codedWidth,
                                                                     codedHeight: plan.codedHeight)
                    guard index == plan.frameIndices[produced] else { return nil }
                    reader.stopCharging()
                    return try normalized(buffer)
                }
                guard let frame else { continue }
                produced += 1
                if produced == sampled, sampled % 2 == 1 { last = frame }
                return frame
            }
        }

        /// The validated frame as RGB8 with the track's rotation, normalized
        /// at the plan's grid.
        private func normalized(_ buffer: CVPixelBuffer) throws -> [Float] {
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                throw Failure.invalidVideo
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.invalidVideo }
            let source = base.assumingMemoryBound(to: UInt8.self)
            let width = plan.codedWidth
            let height = plan.codedHeight
            let stride = CVPixelBufferGetBytesPerRow(buffer)
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

/// Owns one reader's reads and its stop. Cancelling an AVAssetReader while a
/// `copyNextSampleBuffer()` is blocked tears down the state that read waits
/// on, so every copy and the reader's one `cancelReading()` run in order on
/// the reader's serial queue, never concurrently. The pulling thread waits
/// for each sample instead: while charged, at most the decoder allowance
/// left, and only until the task is cancelled. A wait given up on returns at
/// once; its read finishes on the queue, its sample is dropped, and only then
/// is the reader cancelled. Each queued block keeps this owner, and with it
/// the reader, its output and the asset serving the bytes, alive.
private final class SerialReader: @unchecked Sendable {
    /// One copy handed from the queue to the waiting thread. Its state is
    /// guarded by the owner's lock.
    private final class Read: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var delivered = false
        var abandoned = false
        var sample: CMSampleBuffer?
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    /// The in-memory asset the reader loads through; its resource loader
    /// holds the delegate serving the bytes only weakly.
    private let source: NemotronSuperVideoAsset
    private let queue = DispatchQueue(label: "ai.darkbloom.super-video.reader", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
    private let cancelledForTesting: (@Sendable (AVAssetReader) -> Void)?
    private let lock = NSLock()
    /// Nanoseconds of decoder wait left; nil without an allowance.
    private var remaining: UInt64?
    /// Uptime when the current wait began.
    private var chargedSince: UInt64?
    /// The read the pulling thread waits on, which cancellation wakes.
    private var waiting: Read?
    /// No read starts once the reader is stopped; its cancellation is queued.
    private var stopped = false
    private var expired = false

    init(_ reader: AVAssetReader, output: AVAssetReaderOutput, source: NemotronSuperVideoAsset,
         allowance: Duration? = nil) {
        self.reader = reader
        self.output = output
        self.source = source
        cancelledForTesting = NemotronSuperVideoDecode.readerCancelledForTesting
        remaining = allowance.map(Self.nanoseconds)
    }

    /// Queued blocks retain the owner, so none is queued here and the reader
    /// can be cancelled inline.
    deinit {
        guard !stopped else { return }
        reader.cancelReading()
        cancelledForTesting?(reader)
    }

    /// Whole nanoseconds of `duration`, saturating; zero when not positive
    /// (a negative duration under a second has zero seconds but negative
    /// attoseconds).
    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        guard duration > .zero else { return 0 }
        let (seconds, attoseconds) = duration.components
        let (whole, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let (total, carry) = whole.addingReportingOverflow(UInt64(attoseconds / 1_000_000_000))
        return overflow || carry ? .max : total
    }

    /// Runs `body` with a wait for a sample given up, and the reader
    /// stopped, as soon as the task is cancelled.
    func cancellable<Result>(_ body: () throws -> Result) async throws -> Result {
        try await withTaskCancellationHandler(operation: body) {
            self.lock.withLock { () -> Read? in
                self.stop()
                return self.waiting
            }?.done.signal()
        }
    }

    /// Decoder wait from here until `stopCharging()` runs down the
    /// allowance; once it is spent the reader is stopped.
    func startCharging() {
        lock.withLock {
            guard remaining != nil, chargedSince == nil else { return }
            chargedSince = DispatchTime.now().uptimeNanoseconds
        }
    }

    func stopCharging() {
        lock.withLock {
            guard let since = chargedSince, let remaining else { return }
            let waited = DispatchTime.now().uptimeNanoseconds - since
            self.remaining = remaining > waited ? remaining - waited : 0
            chargedSince = nil
        }
    }

    /// The next sample; nil once the reader ends or is stopped, because the
    /// task was cancelled or the charged wait outlasted the allowance.
    func nextSample() -> CMSampleBuffer? {
        let read = Read()
        let deadline = lock.withLock { () -> DispatchTime? in
            guard !stopped else { return nil }
            var deadline = DispatchTime.distantFuture
            if let remaining, let chargedSince {
                let spent = DispatchTime.now().uptimeNanoseconds - chargedSince
                guard remaining > spent else {
                    expire()
                    return nil
                }
                deadline = .now() + .nanoseconds(Int(clamping: remaining - spent))
            }
            waiting = read
            return deadline
        }
        guard let deadline else { return nil }
        queue.async { [self] in
            let sample = autoreleasepool { output.copyNextSampleBuffer() }
            let delivered = lock.withLock { () -> Bool in
                guard !read.abandoned else { return false }
                read.sample = sample
                read.delivered = true
                return true
            }
            if delivered { read.done.signal() }
        }
        _ = read.done.wait(timeout: deadline)
        return lock.withLock { () -> CMSampleBuffer? in
            waiting = nil
            if read.delivered { return read.sample }
            // Cancelled, or out of allowance: the read finishes on the queue
            // ahead of the reader's cancellation, and its sample is dropped.
            read.abandoned = true
            if !stopped { expire() }
            return nil
        }
    }

    /// Whether the reader read to its end, asked on its queue.
    var completed: Bool { queue.sync { reader.status == .completed } }

    /// Why the reader returned no sample before the plan's last frame: the
    /// task was cancelled, the allowance ran out, or the reader failed or
    /// lost frames.
    var earlyEnd: any Error {
        if Task.isCancelled { return CancellationError() }
        return lock.withLock { expired }
            ? NemotronSuperVideoDecode.Failure.limit : NemotronSuperVideoDecode.Failure.inconsistentFrames
    }

    /// Under the lock.
    private func expire() {
        expired = true
        stop()
    }

    /// Under the lock: no read starts after this, and the reader is
    /// cancelled on its queue once any read in flight returns.
    private func stop() {
        guard !stopped else { return }
        stopped = true
        queue.async { [self] in
            reader.cancelReading()
            cancelledForTesting?(reader)
        }
    }
}
