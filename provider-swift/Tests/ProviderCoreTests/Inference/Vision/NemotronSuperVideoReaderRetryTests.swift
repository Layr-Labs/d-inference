// Copyright © 2026 Eigen Labs.

@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Every failed reader pass, in order. Disarms `fault` when a pass fails and a
/// second pass follows, so that pass reads every byte.
private final class FailedPasses: @unchecked Sendable {
    private let lock = NSLock()
    private let fault: VideoDataRequestFault?
    init(disarming fault: VideoDataRequestFault? = nil) { self.fault = fault }
    private var recorded: [VideoReaderFailure] = []
    private var retries: [Bool] = []
    var retrying: [Bool] { lock.withLock { retries } }
    var failures: [VideoReaderFailure] { lock.withLock { recorded } }
    var observer: VideoReaderRetry.Observer {
        { [self] failure, retrying in
            lock.withLock {
                recorded.append(failure)
                retries.append(retrying)
            }
            if retrying { fault?.disarm() }
        }
    }
}

/// Cancels each of the first `readers` readers before its read number `read`,
/// on the reader's queue, as the reader's own stop does. The reader then ends
/// in `.cancelled` without having been stopped.
private final class ReaderEnder: @unchecked Sendable {
    private let lock = NSLock()
    private let read: Int
    private var readers: Int
    private var reads: [ObjectIdentifier: Int] = [:]
    private var endedCount = 0
    var ended: Int { lock.withLock { endedCount } }

    init(readers: Int, atRead read: Int) {
        self.readers = readers
        self.read = read
    }

    var hook: @Sendable (AVAssetReader) -> Void {
        { [self] reader in
            let end = lock.withLock { () -> Bool in
                let id = ObjectIdentifier(reader)
                reads[id, default: 0] += 1
                guard reads[id] == read, readers > 0 else { return false }
                readers -= 1
                endedCount += 1
                return true
            }
            if end { reader.cancelReading() }
        }
    }
}

/// The Super video reader over OpenRouter's MP4 readiness clip, with data
/// requests of its in-memory loader failed partway through the clip. The clip
/// keeps `moov` after `mdat`, so its middle byte is sample data that only a
/// full reader pass requests: first the timing pass, then the frame reader.
/// AVFoundation requests a failed range again, so a pass fails only while the
/// fault stays armed. The frame reader reads bytes the timing pass already
/// loaded, so its tests end the reader itself partway instead.
struct NemotronSuperVideoReaderRetryTests {
    private typealias Decode = NemotronSuperVideoDecode

    private static func clip() throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent(
            "libs/mlx-swift-lm/Tests/MLXLMTests/Resources/MiMoOpenRouter/input-video-url.mp4"))
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            == "dc11648bd3546cd0a37ecc1077ccc426d42c409fe4822ece0354eb250804431e")
        return data
    }

    private static func fault(_ data: Data) -> VideoDataRequestFault {
        VideoDataRequestFault(offset: data.count / 2, error: MemoryBackedVideoAssetError.invalidRange)
    }

    private static func inspect(_ data: Data, _ fault: VideoDataRequestFault?) async throws -> Decode.Plan {
        try await VideoDataRequestFault.$current.withValue(fault) {
            try await Decode.inspect(NemotronSuperVideoClips.uri(data))
        }
    }

    private static func frames(_ plan: Decode.Plan, ending ender: ReaderEnder? = nil) async throws -> [[Float]] {
        let frames = try await Decode.$beforeReadForTesting.withValue(ender?.hook) {
            try await Decode.Frames(plan)
        }
        return try await frames.withCancellableReader {
            var all: [[Float]] = []
            while let frame = try frames.next() { all.append(frame) }
            return all
        }
    }

    private static func observing<Result>(_ passes: FailedPasses, _ body: () async throws -> Result)
        async throws -> Result {
        try await VideoReaderRetry.$failedPassObserver.withValue(passes.observer, operation: body)
    }

    @Test func aFailedTimingPassIsReadAgainWithTheSamePlan() async throws {
        let data = try Self.clip()
        let baseline = try await Self.inspect(data, nil)
        let fault = Self.fault(data)
        let passes = FailedPasses(disarming: fault)
        let plan = try await Self.observing(passes) { try await Self.inspect(data, fault) }
        #expect(fault.injected >= 1)
        #expect(passes.retrying == [true])
        #expect(plan.sourceFrames == baseline.sourceFrames && plan.sourceFPS == baseline.sourceFPS)
        #expect(plan.frameIndices == baseline.frameIndices && plan.labels == baseline.labels)
    }

    /// The frame reader ends partway: a new reader decodes from the first
    /// frame again and the sampled frames match an unfaulted decode.
    @Test func aFailedFrameReaderIsReplacedOnceWithTheSameFrames() async throws {
        let plan = try await Self.inspect(try Self.clip(), nil)
        let baseline = try await Self.frames(plan)
        let ender = ReaderEnder(readers: 1, atRead: 40)
        let passes = FailedPasses()
        let frames = try await Self.observing(passes) { try await Self.frames(plan, ending: ender) }
        #expect(ender.ended == 1)
        #expect(passes.retrying == [true])
        #expect(passes.failures.map(\.status) == [AVAssetReader.Status.cancelled.rawValue])
        #expect(frames == baseline)
    }

    @Test func aFrameReaderThatFailsAgainThrowsItsFailure() async throws {
        let plan = try await Self.inspect(try Self.clip(), nil)
        let ender = ReaderEnder(readers: 2, atRead: 40)
        let passes = FailedPasses()
        await #expect(throws: VideoReaderFailure.self) {
            try await Self.observing(passes) { try await Self.frames(plan, ending: ender) }
        }
        #expect(ender.ended == 2)
        #expect(passes.retrying == [true, false])
        #expect(passes.failures.allSatisfy { !$0.isTransient })
    }
}
