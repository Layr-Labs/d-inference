// Copyright © 2026 Eigen Labs.
@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import ProviderCore

/// The Super video decoder's bounds and refusals on synthesized clips: the
/// decoded-pixel budget, the codec allowlist, track and timing refusals,
/// per-frame validation, the decode allowance, cancellation of the reader,
/// and the container type hint.
struct NemotronSuperVideoDecodeTests {
    private typealias Decode = NemotronSuperVideoDecode
    private typealias Clips = NemotronSuperVideoClips

    /// The budget admits ten minutes of 30 fps 1080p or 60 fps 720p, not ten
    /// minutes of 4096 x 2160 frames; a clip one pixel over is refused while
    /// it is inspected, before any frame decodes.
    @Test func decodedPixelBudgetRefusesBeforeDecoding() async throws {
        #expect(18_000 * 1_920 * 1_080 <= Decode.maximumDecodedPixels)
        #expect(36_000 * 1_280 * 720 <= Decode.maximumDecodedPixels)
        #expect(4_250 * NemotronSuperServingPolicy.maximumVideoFramePixels == Decode.maximumDecodedPixels)
        #expect(Decode.maximumSourceFrames * NemotronSuperServingPolicy.maximumVideoFramePixels
            > Decode.maximumDecodedPixels)
        // 30 frames at 30 fps sample frames 0 and 29, so all 30 decode.
        let uri = Clips.uri(try await Clips.movie(frames: 30, fps: 30))
        let plan = try await Decode.inspect(uri, decodedPixelBudget: 30 * 64 * 64)
        #expect(plan.frameIndices == [0, 29] && plan.decodedFrames == 30)
        await #expect(throws: Decode.Failure.limit) {
            try await Decode.inspect(uri, decodedPixelBudget: 30 * 64 * 64 - 1)
        }
    }

    /// H.264 and HEVC are admitted; any other codec (Motion JPEG here) is
    /// refused while the movie is inspected.
    @Test func onlyH264AndHEVCAreAdmitted() async throws {
        for codec in [AVVideoCodecType.h264, .hevc] {
            let movie = try await Clips.movie(frames: 4, fps: 2, width: 128, height: 128, codec: codec)
            #expect(try await Decode.inspect(Clips.uri(movie)).frameIndices == [0, 1, 2, 3], "\(codec.rawValue)")
        }
        let jpeg = try await Clips.movie(frames: 4, fps: 2, fileType: .mov, codec: .jpeg)
        await #expect(throws: Decode.Failure.unsupportedRepresentation) {
            try await Decode.inspect(Clips.uri(jpeg, quickTime: true))
        }
    }

    @Test func aSecondVideoTrackIsRefused() async throws {
        let uri = Clips.uri(try await Clips.twoTracks(frames: 4, fps: 2))
        await #expect(throws: Decode.Failure.unsupportedRepresentation) { try await Decode.inspect(uri) }
    }

    /// As in FFmpeg's demuxer only the last frame may have zero duration.
    @Test func zeroDurationBeforeTheLastFrameIsRefused() async throws {
        // Durations 2, 1, 2, ...: the last run covers the final two frames.
        let movie = try await Clips.movie(frames: 8, fps: 30, durations: [2, 1])
        #expect(try await Decode.inspect(Clips.uri(movie)).sourceFrames == 8)
        let zeroed = try Clips.zeroingLastDurationRun(movie)
        await #expect(throws: Decode.Failure.invalidVideo) { try await Decode.inspect(Clips.uri(zeroed)) }
    }

    /// Each decoded frame, sampled or not, must be the inspected size in
    /// BGRA with rows inside the charged 32 bytes a pixel and 1 MiB.
    @Test func decodedFramesAreValidated() throws {
        func buffer(_ width: Int, _ height: Int,
                    format: OSType = kCVPixelFormatType_32BGRA) throws -> CVPixelBuffer {
            var value: CVPixelBuffer?
            try #require(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, nil, &value)
                == kCVReturnSuccess)
            return try #require(value)
        }
        try Decode.validateDecodedFrame(try buffer(64, 48), codedWidth: 64, codedHeight: 48)
        #expect(throws: Decode.Failure.unsupportedRepresentation) {
            try Decode.validateDecodedFrame(try buffer(64, 48, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                            codedWidth: 64, codedHeight: 48)
        }
        for (width, height) in [(64, 64), (48, 48), (64, 47)] {
            #expect(throws: Decode.Failure.inconsistentFrames, "\(width) x \(height)") {
                try Decode.validateDecodedFrame(try buffer(width, height), codedWidth: 64, codedHeight: 48)
            }
        }
        let limit = 64 * 48 * 32 + (1 << 20)
        for (stride, admitted) in [(limit / 48, true), (limit / 48 + 1, false)] {
            let storage = UnsafeMutableRawPointer.allocate(byteCount: stride * 48, alignment: 64)
            defer { storage.deallocate() }
            var value: CVPixelBuffer?
            try #require(CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
                storage, stride, nil, nil, nil, &value) == kCVReturnSuccess)
            let padded = try #require(value)
            try #require(CVPixelBufferGetBytesPerRow(padded) == stride)
            if admitted {
                try Decode.validateDecodedFrame(padded, codedWidth: 64, codedHeight: 48)
            } else {
                #expect(throws: Decode.Failure.inconsistentFrames) {
                    try Decode.validateDecodedFrame(padded, codedWidth: 64, codedHeight: 48)
                }
            }
        }
    }

    /// A spent allowance ends the pull's wait on the decoder at once and
    /// fails it as a limit; the reader stops behind the read in flight.
    @Test(.timeLimit(.minutes(2))) func decodeAllowanceStopsTheReader() async throws {
        // 240 frames at 60 fps: 8 sampled, every frame up to 239 decodes.
        let plan = try await Decode.inspect(Clips.uri(try await Clips.movie(frames: 240, fps: 60)))
        try #require(plan.frameIndices.count == 8 && plan.decodedFrames == 240)
        let spent = try await Decode.Frames(plan, decodeAllowance: .zero)
        #expect(throws: Decode.Failure.limit) { try spent.next() }
        // A negative allowance is spent too, under a second (zero seconds,
        // negative attoseconds) as beyond it.
        for allowance in [Duration.milliseconds(-500), .seconds(-2)] {
            let negative = try await Decode.Frames(plan, decodeAllowance: allowance)
            #expect(throws: Decode.Failure.limit) { try negative.next() }
        }
        let short = try await Decode.Frames(plan, decodeAllowance: .microseconds(100))
        #expect(throws: Decode.Failure.limit) { while try short.next() != nil {} }
        let planned = try await Decode.Frames(plan)
        var count = 0
        while try planned.next() != nil { count += 1 }
        #expect(count == 2 * plan.tubelets)
        // Five seconds, then 2 ms a frame and 4 ns a coded pixel, at most two minutes.
        #expect(Decode.decodeAllowance(frames: 240, codedPixels: 64 * 64)
            == .seconds(5) + .nanoseconds(240 * (2_000_000 + 4 * 64 * 64)))
        #expect(Decode.decodeAllowance(frames: 18_000, codedPixels: 1_920 * 1_088) == .seconds(120))
        #expect(Decode.decodeAllowance(frames: Decode.maximumSourceFrames,
                                       codedPixels: NemotronSuperServingPolicy.maximumVideoFramePixels)
            == .seconds(120))
    }

    /// Cancelling the task stops the reader itself, not only the task, so a
    /// pull waiting on the decoder returns instead of holding the owner.
    @Test func cancellationStopsTheReader() async throws {
        let plan = try await Decode.inspect(Clips.uri(try await Clips.movie(frames: 60, fps: 30)))
        let frames = SendableFrames(try await Decode.Frames(plan))
        let pull = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await frames.value.withCancellableReader { try frames.value.next() }
        }
        await #expect(throws: CancellationError.self) { try await pull.value }
        // An uncancelled pull finds the reader stopped.
        #expect(throws: Decode.Failure.inconsistentFrames) { try frames.value.next() }
    }

    /// A pull given up on, for a spent allowance or a cancelled task, fails
    /// at once while its read finishes on the reader's queue; only then is
    /// the reader cancelled, once, and released. Cancelling a reader under a
    /// blocked read crashes in AVFoundation, so the stops are repeated at
    /// varying points of the decode.
    @Test(.timeLimit(.minutes(3))) func givingUpOnAReadNeverRacesTheReader() async throws {
        // 600 frames at 30 fps: 40 sampled frames, far more decoding than
        // any allowance or cancellation delay below.
        let plan = try await Decode.inspect(Clips.uri(try await Clips.movie(frames: 600, fps: 30)))
        let readers = CancelledReaders()
        let iterations = 50
        try await Decode.$readerCancelledForTesting.withValue({ readers.record($0) }) {
            for iteration in 0 ..< iterations {
                if iteration.isMultiple(of: 2) {
                    let short = try await Decode.Frames(plan,
                                                        decodeAllowance: .microseconds(10 * (iteration % 20 + 1)))
                    #expect(throws: Decode.Failure.limit) { while try short.next() != nil {} }
                } else {
                    try await Self.cancelMidDecode(plan, afterMicroseconds: 100 * (iteration % 10))
                }
            }
        }
        let settled = await readers.settled(count: iterations)
        #expect(settled.cancelled == iterations && settled.alive == 0, "\(settled)")
    }

    /// Cancels, from another thread, a pull of every frame `delay` after its
    /// first sampled frame starts decoding.
    private static func cancelMidDecode(_ plan: Decode.Plan, afterMicroseconds delay: Int) async throws {
        let frames = SendableFrames(try await Decode.Frames(plan))
        let started = DispatchSemaphore(value: 0)
        let pull = Decode.Frames.$beforeFrameDecodeForTesting.withValue({ _ = started.signal() }) {
            Task { try await frames.value.withCancellableReader { while try frames.value.next() != nil {} } }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            started.wait()
            Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000)
            pull.cancel()
        }
        await #expect(throws: CancellationError.self) { try await pull.value }
        #expect(throws: Decode.Failure.inconsistentFrames) { try frames.value.next() }
    }

    /// The type hint follows the SDK container rule `MediaIngest` applied, so
    /// a legacy QuickTime movie without `ftyp` is read as QuickTime.
    @Test func containerTypeFollowsTheSharedIngestRule() async throws {
        typealias Asset = NemotronSuperVideoAsset
        func atom(_ type: String, _ payload: [UInt8] = [], size: UInt32? = nil) -> Data {
            var data = Data()
            withUnsafeBytes(of: (size ?? UInt32(8 + payload.count)).bigEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: Array(type.utf8))
            data.append(contentsOf: payload)
            return data
        }
        let quickTime = Array("qt  ".utf8) + [0, 0, 0, 0]
        let iso = Array("isom".utf8) + [0, 0, 2, 0]
        #expect(try Asset.contentType(of: atom("ftyp", quickTime) + atom("moov") + atom("mdat")) == .mov)
        #expect(try Asset.contentType(of: atom("ftyp", iso) + atom("moov") + atom("mdat")) == .mp4)
        #expect(try Asset.contentType(of: atom("wide") + atom("mdat") + atom("moov")) == .mov)
        // An ftyp after another atom, or with a 64-bit size, still decides.
        #expect(try Asset.contentType(of: atom("free") + atom("ftyp", quickTime) + atom("moov")) == .mov)
        let extended = atom("ftyp", [0, 0, 0, 0, 0, 0, 0, 24] + quickTime, size: 1)
        #expect(try Asset.contentType(of: extended + atom("mdat")) == .mov)
        let invalid = [Data(), atom("moov"), atom("ftyp", quickTime) + atom("ftyp", iso), atom("moov").dropLast(),
                       atom("mdat") + Data([0, 0, 0]), atom("moov", size: 9)]
        for data in invalid {
            #expect(throws: Decode.Failure.invalidVideo, "\(Array(data))") { try Asset.contentType(of: data) }
        }
        // A real movie without its ftyp plans as the original does.
        let movie = try await Clips.movie(frames: 6, fps: 2, fileType: .mov)
        let legacy = try Clips.withoutFileType(movie)
        #expect(try Asset(videoData: movie).contentType == .mov)
        #expect(try Asset(videoData: legacy).contentType == .mov)
        let original = try await Decode.inspect(Clips.uri(movie, quickTime: true))
        let plan = try await Decode.inspect(Clips.uri(legacy, quickTime: true))
        #expect(plan.sourceFrames == original.sourceFrames && plan.frameIndices == original.frameIndices
            && plan.labels == original.labels)
    }
}

/// Moves one frame source into a child task; the test uses it only after
/// that task ends.
private final class SendableFrames: @unchecked Sendable {
    let value: NemotronSuperVideoDecode.Frames
    init(_ value: NemotronSuperVideoDecode.Frames) { self.value = value }
}

/// The readers the decoder cancels, each held weakly to see it released.
private final class CancelledReaders: @unchecked Sendable {
    private struct Entry { weak var reader: AVAssetReader? }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(_ reader: AVAssetReader) { lock.withLock { entries.append(Entry(reader: reader)) } }

    /// Readers cancelled and still alive, once `count` are cancelled and
    /// none is alive, or after thirty seconds.
    func settled(count: Int) async -> (cancelled: Int, alive: Int) {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            let current = snapshot()
            if (current.cancelled >= count && current.alive == 0) || ContinuousClock.now >= deadline { return current }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func snapshot() -> (cancelled: Int, alive: Int) {
        lock.withLock { (entries.count, entries.filter { $0.reader != nil }.count) }
    }
}
