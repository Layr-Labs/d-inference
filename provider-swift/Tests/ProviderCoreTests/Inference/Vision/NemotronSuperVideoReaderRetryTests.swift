// Copyright © 2026 Eigen Labs.

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

/// The Super video reader over OpenRouter's MP4 readiness clip, with data
/// requests of its in-memory loader failed partway through the clip. The clip
/// keeps `moov` after `mdat`, so its middle byte is sample data that only a
/// full reader pass requests: first the timing pass, then the frame reader.
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

    private static func fault(_ data: Data, failures: Int, skipping: Int = 0) -> VideoDataRequestFault {
        VideoDataRequestFault(offset: data.count / 2, failures: failures, skipping: skipping,
                              error: MemoryBackedVideoAssetError.invalidRange)
    }

    private static func inspect(_ data: Data, _ fault: VideoDataRequestFault?) async throws -> Decode.Plan {
        try await VideoDataRequestFault.$current.withValue(fault) {
            try await Decode.inspect(NemotronSuperVideoClips.uri(data))
        }
    }

    private static func frames(_ plan: Decode.Plan) async throws -> [[Float]] {
        let frames = try await Decode.Frames(plan)
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
        let fault = Self.fault(data, failures: 1)
        let passes = FailedPasses()
        let plan = try await Self.observing(passes) { try await Self.inspect(data, fault) }
        #expect(fault.injected == 1)
        #expect(passes.retrying == [true])
        #expect(plan.sourceFrames == baseline.sourceFrames && plan.sourceFPS == baseline.sourceFPS)
        #expect(plan.frameIndices == baseline.frameIndices && plan.labels == baseline.labels)
    }

    /// The frame reader fails partway: a new reader decodes from the first
    /// frame again and the sampled frames match an unfaulted decode.
    @Test func aFailedFrameReaderIsReplacedOnceWithTheSameFrames() async throws {
        let data = try Self.clip()
        let baseline = try await Self.frames(Self.inspect(data, nil))
        let fault = Self.fault(data, failures: 1, skipping: 1)
        let passes = FailedPasses()
        let plan = try await Self.observing(passes) { try await Self.inspect(data, fault) }
        #expect(passes.retrying.isEmpty, "the timing pass met the fault")
        let frames = try await Self.observing(passes) { try await Self.frames(plan) }
        #expect(fault.injected == 1)
        #expect(passes.retrying == [true])
        #expect(passes.failures.allSatisfy { !$0.codes.isEmpty })
        #expect(frames == baseline)
    }

    @Test func aFrameReaderThatFailsAgainThrowsItsFailure() async throws {
        let data = try Self.clip()
        let fault = Self.fault(data, failures: .max, skipping: 1)
        let passes = FailedPasses()
        let plan = try await Self.observing(passes) { try await Self.inspect(data, fault) }
        await #expect(throws: VideoReaderFailure.self) {
            try await Self.observing(passes) { try await Self.frames(plan) }
        }
        #expect(passes.retrying == [true, false])
        #expect(passes.failures.allSatisfy { !$0.isTransient })
    }
}
