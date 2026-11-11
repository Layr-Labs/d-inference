import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

/// Runs each test with MLX's freed-buffer cache bounded as a ready Qwen
/// tensor-parallel rank bounds it (1 GiB,
/// `QwenTensorParallelLaunch.freedBufferCacheBytes`), and empties the cache
/// after the test.
///
/// MLX's default cache limit is its memory limit, and it reuses a freed buffer
/// only for a request of about the same size. Prefill frames over a growing
/// history and the unquantized weights of a synthetic model free buffers that
/// no later request reuses, so the cache keeps them: on a 48 GiB CI Mac the
/// GLM-5.3 paged KV tests' process reached 18.5 GiB (run 42921272802), and the
/// cache of one test stays for the next. The cache is a reuse pool, so the
/// bound changes no result.
struct BoundedBufferCache: SuiteTrait, TestTrait, TestScoping {
    static var readyRankBytes: Int {
        QwenTensorParallelLaunch.freedBufferCacheBytes(allocatorHeadroomBytes: QwenDenseStageLoadPolicy.allocatorHeadroomBytes)
    }

    let bytes: Int

    /// Applied to a suite, the trait scopes each of its tests.
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        let previous = Memory.cacheLimit
        Memory.cacheLimit = min(previous, bytes)
        Memory.peakMemory = 0
        defer {
            let gib = Double(1 << 30)
            print("bounded-buffer-cache test=\(test.name) peak_active_gib="
                + String(format: "%.2f", Double(Memory.peakMemory) / gib)
                + " cache_gib=" + String(format: "%.2f", Double(Memory.cacheMemory) / gib))
            Memory.cacheLimit = previous
            Memory.clearCache()
        }
        try await function()
    }
}

extension Trait where Self == BoundedBufferCache {
    /// `BoundedBufferCache` at a ready rank's bound.
    static var boundedBufferCache: Self { Self(bytes: Self.readyRankBytes) }

    /// `BoundedBufferCache` at `gib` GiB.
    static func boundedBufferCache(gib: Int) -> Self { Self(bytes: gib << 30) }
}
