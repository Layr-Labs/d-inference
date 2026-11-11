import MLX
import Testing
@testable import DarkbloomClusterRuntime

/// Runs each test with MLX's freed-buffer cache bounded, never above the
/// limit already set, then restores that limit and empties the cache.
///
/// MLX's default cache limit is its memory limit, and it reuses a freed buffer
/// only for a request of about the same size. Prefill frames over a growing
/// history and the unquantized weights of a synthetic model free buffers that
/// no later request reuses, so the cache keeps them: on a 48 GiB CI Mac the
/// GLM-5.3 paged KV tests' process reached 18.5 GiB (run 42921272802), and the
/// cache of one test stays for the next. The cache is a reuse pool, so the
/// bound changes no result. The limit is process-wide: the suites that use
/// this trait are serialized, and CI runs each selection with
/// `--no-parallel`, so no test of another suite sees the bound.
struct BoundedBufferCache: SuiteTrait, TestTrait, TestScoping {
    let bytes: Int

    /// Applied to a suite, the trait scopes each of its tests.
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        let previous = Memory.cacheLimit
        Memory.cacheLimit = min(previous, bytes)
        defer { Memory.cacheLimit = previous; Memory.clearCache() }
        try await function()
    }
}

extension Trait where Self == BoundedBufferCache {
    /// The freed-buffer cache of a ready Qwen tensor-parallel rank (1 GiB,
    /// `QwenTensorParallelLaunch.freedBufferCacheBytes`).
    static var boundedBufferCache: Self {
        Self(bytes: QwenTensorParallelLaunch.freedBufferCacheBytes(
            allocatorHeadroomBytes: QwenDenseStageLoadPolicy.allocatorHeadroomBytes))
    }

    /// A bound of `gib` GiB. The GLM-5.3 paged KV, row invariance, depth
    /// invariance and window census tests and Qwen's prefix-depth test use
    /// 4, which holds one prefill frame's temporaries at their widths, so each
    /// layer reuses the buffers of the layer before. At 1 GiB the GLM-5.3
    /// paged KV test took 2.4 times as long (run 42926131340); at 4 GiB it
    /// took no longer than without a bound (run 42932309477).
    static func boundedBufferCache(gib: Int) -> Self { Self(bytes: gib << 30) }
}
