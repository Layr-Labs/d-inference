import Foundation
import XCTest
import MLXLMCommon
@testable import MLXVLM
@testable import ProviderCore

final class MiMoMediaDecodeMemoryTests: XCTestCase {
    func testMultipleImagesKeepAllRGBAndOnlyLargestScratch() throws {
        var memory = MiMoV26MediaDecodeMemory(hostBytes: 1234)
        for pixels in [1920 * 1080, 3840 * 2160, 640 * 480] {
            try memory.includeVisual(.image(pixels: pixels))
        }
        let totalPixels: Int = 2_073_600 + 8_294_400 + 307_200
        XCTAssertEqual(memory.retainedBytes, 1234 + UInt64(totalPixels * 12))
        XCTAssertEqual(memory.transientBytes, UInt64(3840 * 2160 * 20 + (1 << 20)))
        try memory.includeRetained(4096) // existing audio allowance stays fully charged
        XCTAssertEqual(try memory.peakBytes, memory.retainedBytes + memory.transientBytes)
    }

    func testMixedVideoImagesAndOverflowKeepConservativeLifetimeCharge() throws {
        var memory = MiMoV26MediaDecodeMemory(hostBytes: 4096)
        let video = try MiMoV26VisualDecodeMemory.video(encodedBytes: 8192, sourceFrames: 300,
            sampledFrames: 20, pixels: 1920 * 1080, maximumControlMarkers: 4096)
        let image = try MiMoV26VisualDecodeMemory.image(pixels: 640 * 480)
        try memory.includeVisual(video)
        try memory.includeVisual(image)
        XCTAssertEqual(memory.retainedBytes, UInt64(video.retainedBytes + image.retainedBytes) + 4096)
        XCTAssertEqual(memory.transientBytes, UInt64(video.transientBytes))
        XCTAssertThrowsError(try memory.includeRetained(UInt64.max))
        var overflow = MiMoV26MediaDecodeMemory(hostBytes: UInt64.max - 12)
        try overflow.includeVisual(.image(pixels: 1))
        XCTAssertThrowsError(try overflow.peakBytes)
    }

    func testRealH264LongSourceUsesSampledRetentionAndTightDecodeBudget() async throws {
        let limits = MiMoV26EncodedVisualDecoder.Limits(maximumPixels: 4096,
            maximumWorkingBytes: 4 << 20, maximumSourceFrames: 300, maximumSampledFrames: 20)
        let sampling = try MiMoV26EncodedVisualDecoder.Sampling(fps: 2, minimumFrames: 2, maximumFrames: 20)
        var results: [(encoded: Int, bound: Int)] = []
        for (frames, fps) in [(30, Int32(3)), (300, Int32(30))] {
            let data = try await MiMoEncodedMediaFixtures.video(frames: frames, fps: fps)
            let owner = try MemoryBackedVideoAsset(videoData: data)
            let plan = try await MiMoV26EncodedVisualDecoder.inspectVideo(owner, sampling: sampling, limits: limits)
            XCTAssertEqual(plan.sourceFrameCount, frames)
            XCTAssertEqual(plan.sampledIndices.count, 20)
            XCTAssertEqual(plan.sampledIndices.first, 0)
            XCTAssertEqual(plan.sampledIndices.last, frames - 1)
            let bound = try plan.decodeWorkingByteBound()
            XCTAssertLessThan(bound, 4 << 20)
            let exact = MiMoV26EncodedVisualDecoder.Limits(maximumPixels: 4096,
                maximumWorkingBytes: bound, maximumSourceFrames: 300, maximumSampledFrames: 20)
            let decoded = try await MiMoV26EncodedVisualDecoder.silentVideo(plan, limits: exact)
            XCTAssertEqual(decoded.frames.count, 20)
            XCTAssertEqual(decoded.timestamps, plan.timestamps)
            XCTAssertTrue(decoded.frames.allSatisfy { $0.planarRGB.count == 64 * 48 * 3 })
            results.append((data.count, bound))
            do {
                _ = try await MiMoV26EncodedVisualDecoder.silentVideo(plan,
                    limits: .init(maximumPixels:4096, maximumWorkingBytes:bound - 1,
                        maximumSourceFrames:300, maximumSampledFrames:20))
                XCTFail("accepted a grant below the exact decode bound")
            } catch { XCTAssertEqual(error as? MiMoV26EncodedVisualDecoder.Failure, .limit) }
        }
        XCTAssertEqual(results[1].bound - results[0].bound,
            results[1].encoded - results[0].encoded + (300 - 30) * 64)
    }
}
