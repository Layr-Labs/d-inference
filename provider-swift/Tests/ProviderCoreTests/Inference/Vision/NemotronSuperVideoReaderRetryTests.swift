// Copyright © 2026 Eigen Labs.

@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Every failed reader pass, in order.
private final class FailedPasses: @unchecked Sendable {
    private let lock = NSLock()
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
        }
    }
}

/// Cancels the readers in `ending` (1 is the first reader the task opens)
/// before their read number `read`, on the reader's queue between two reads,
/// as the reader's own stop does. Each then ends `.cancelled` without having
/// been stopped, as a reader that fails partway ends `.failed`.
private final class ReaderEnder: @unchecked Sendable {
    private let lock = NSLock()
    private let ending: Set<Int>
    private let read: Int
    private var order: [ObjectIdentifier: (ordinal: Int, reads: Int)] = [:]
    private var endedCount = 0

    init(ending: Set<Int>, atRead read: Int) {
        self.ending = ending
        self.read = read
    }

    var ended: Int { lock.withLock { endedCount } }

    var hook: @Sendable (AVAssetReader) -> Void {
        { [self] reader in
            let end = lock.withLock { () -> Bool in
                let id = ObjectIdentifier(reader)
                var entry = order[id] ?? (ordinal: order.count + 1, reads: 0)
                entry.reads += 1
                order[id] = entry
                guard entry.reads == read, ending.contains(entry.ordinal) else { return false }
                endedCount += 1
                return true
            }
            if end { reader.cancelReading() }
        }
    }
}

/// The Super video reader over OpenRouter's MP4 readiness clip, with a reader
/// ended partway through `VideoReaderRetry`'s read hook: the timing pass, or
/// the frame reader that `Frames` replaces once.
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

    private static func inspect(_ data: Data) async throws -> Decode.Plan {
        try await Decode.inspect(NemotronSuperVideoClips.uri(data))
    }

    private static func frames(_ plan: Decode.Plan) async throws -> [[Float]] {
        let frames = try await Decode.Frames(plan)
        return try await frames.withCancellableReader {
            var all: [[Float]] = []
            while let frame = try frames.next() { all.append(frame) }
            return all
        }
    }

    private static func ending<Result>(_ ender: ReaderEnder, observing passes: FailedPasses,
                                       _ body: () async throws -> Result) async throws -> Result {
        try await VideoReaderRetry.$failedPassObserver.withValue(passes.observer) {
            try await VideoReaderRetry.$beforeReadForTesting.withValue(ender.hook, operation: body)
        }
    }

    @Test func aFailedTimingPassIsReadAgainWithTheSamePlan() async throws {
        let data = try Self.clip()
        let baseline = try await Self.inspect(data)
        let ender = ReaderEnder(ending: [1], atRead: 40)
        let passes = FailedPasses()
        let plan = try await Self.ending(ender, observing: passes) { try await Self.inspect(data) }
        #expect(ender.ended == 1)
        #expect(passes.retrying == [true])
        #expect(passes.failures.map(\.status) == [AVAssetReader.Status.cancelled.rawValue])
        #expect(plan.sourceFrames == baseline.sourceFrames && plan.sourceFPS == baseline.sourceFPS)
        #expect(plan.frameIndices == baseline.frameIndices && plan.labels == baseline.labels)
    }

    /// The frame reader ends partway: a new reader decodes from the first
    /// frame again and the sampled frames match an unfaulted decode.
    @Test func aFailedFrameReaderIsReplacedOnceWithTheSameFrames() async throws {
        let plan = try await Self.inspect(try Self.clip())
        let baseline = try await Self.frames(plan)
        let ender = ReaderEnder(ending: [1], atRead: 40)
        let passes = FailedPasses()
        let frames = try await Self.ending(ender, observing: passes) { try await Self.frames(plan) }
        #expect(ender.ended == 1)
        #expect(passes.retrying == [true])
        #expect(passes.failures.map(\.status) == [AVAssetReader.Status.cancelled.rawValue])
        #expect(frames == baseline)
    }

    @Test func aFrameReaderThatFailsAgainThrowsItsFailure() async throws {
        let plan = try await Self.inspect(try Self.clip())
        let ender = ReaderEnder(ending: [1, 2], atRead: 40)
        let passes = FailedPasses()
        await #expect(throws: VideoReaderFailure.self) {
            try await Self.ending(ender, observing: passes) { try await Self.frames(plan) }
        }
        #expect(ender.ended == 2)
        #expect(passes.retrying == [true, false])
        #expect(passes.failures.allSatisfy { !$0.isTransient })
    }
}
