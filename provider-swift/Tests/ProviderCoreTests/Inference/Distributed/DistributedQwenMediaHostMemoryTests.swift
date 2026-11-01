import Testing
@testable import ProviderCore

@Suite("Qwen media preprocessing memory")
struct DistributedQwenMediaHostMemoryTests {
    @Test func imageAndVideoKeepTheirWholeRasterCharge() throws {
        let image = DistributedQwenMediaHostMemory.Item(kind: .image, decodedPixels: 1024, maximumPatches: 4)
        let video = DistributedQwenMediaHostMemory.Item(kind: .video, decodedPixels: 1024, maximumPatches: 16)
        // Four float32 patch buffers at width1536, plus all source rasters and
        // the bounded token/position host arrays. No tower charge is invented.
        #expect(try DistributedQwenMediaHostMemory.processingBytes([image], maximumPromptTokens: 32) == 116_736)
        #expect(try DistributedQwenMediaHostMemory.processingBytes([video], maximumPromptTokens: 32) == 526_336)
        #expect(try DistributedQwenMediaHostMemory.processingBytes([image, video], maximumPromptTokens: 32) == 641_024)
    }

    @Test func aggregateLimitsAreSeparateButNeitherIsBypassed() throws {
        let image = DistributedQwenMediaHostMemory.Item(kind: .image, decodedPixels: 96_000_000, maximumPatches: 4)
        let video = DistributedQwenMediaHostMemory.Item(kind: .video, decodedPixels: 96_000_000, maximumPatches: 16)
        _ = try DistributedQwenMediaHostMemory.processingBytes(Array(repeating: image, count: 4)
            + Array(repeating: video, count: 4), maximumPromptTokens: 32)
        #expect(throws: DistributedQwenMediaHostMemory.Failure.self) {
            try DistributedQwenMediaHostMemory.processingBytes(Array(repeating: image, count: 5), maximumPromptTokens: 32)
        }
        #expect(throws: DistributedQwenMediaHostMemory.Failure.self) {
            try DistributedQwenMediaHostMemory.processingBytes(Array(repeating: video, count: 5), maximumPromptTokens: 32)
        }
    }

    @Test(arguments: [-1, 0, 100_000_001, Int.max])
    func invalidSourceRasterCannotLowerAdmission(pixels: Int) {
        #expect(throws: DistributedQwenMediaHostMemory.Failure.self) {
            try DistributedQwenMediaHostMemory.processingBytes([
                .init(kind: .image, decodedPixels: pixels, maximumPatches: 4)], maximumPromptTokens: 32)
        }
    }

    @Test(arguments: [-1, 0, Int.max])
    func invalidOrOverflowingPatchBoundRefuses(patches: Int) {
        #expect(throws: DistributedQwenMediaHostMemory.Failure.self) {
            try DistributedQwenMediaHostMemory.processingBytes([
                .init(kind: .video, decodedPixels: 1024, maximumPatches: patches)], maximumPromptTokens: 32)
        }
    }

    @Test func itemAndPromptBoundsAreValidatedBeforeArithmetic() {
        #expect(throws: DistributedQwenMediaHostMemory.Failure.self) {
            try DistributedQwenMediaHostMemory.processingBytes([], maximumPromptTokens: 32)
        }
        for prompt in [-1, 0, 1_048_577, Int.max] {
            #expect(throws: DistributedQwenMediaHostMemory.Failure.self) {
                try DistributedQwenMediaHostMemory.processingBytes([
                    .init(kind: .image, decodedPixels: 1024, maximumPatches: 4)], maximumPromptTokens: prompt)
            }
        }
        #expect(throws: DistributedQwenMediaHostMemory.Failure.self) {
            try DistributedQwenMediaHostMemory.processingBytes(Array(repeating:
                .init(kind: .video, decodedPixels: 1024, maximumPatches: 16), count: 9), maximumPromptTokens: 32)
        }
    }
}
