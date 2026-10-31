import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GPT-OSS demand-grown paged KV (CPU)")
struct GPTOSSPagedKVTests {
    private func rows(_ count: Int, start: Int, dtype: DType = .float32) -> (MLXArray, MLXArray) {
        let values = (0..<(2 * count * 4)).map { Float(($0 + start * 7) % 107 - 53) / 16 }
        let keys = MLXArray(values).reshaped([1, 2, count, 4]).asType(dtype)
        return (keys, (keys * 0.5).asType(dtype))
    }

    private func equal(_ a: MLXArray, _ b: MLXArray) {
        eval(a, b)
        #expect(a.shape == b.shape && a.dtype == b.dtype)
        #expect(a.asData().data == b.asData().data)
    }

    private func equalMask(_ a: MLXFast.ScaledDotProductAttentionMaskMode,
                           _ b: MLXFast.ScaledDotProductAttentionMaskMode) {
        switch (a, b) {
        case (.none, .none), (.causal, .causal): break
        case (.array(let a), .array(let b)): equal(a, b)
        default: Issue.record("Paged mask differs from SDK cache mask")
        }
    }

    @Test func fullAndSlidingRowsMasksAndSinksMatchTheRealSDKCaches() {
        Device.withDefaultDevice(.cpu) {
            for window: Int? in [nil, 128] {
                for dtype in [DType.float32, .bfloat16] {
                    for chunks in [[1] + Array(repeating: 1, count: 260),
                                   [64, 65, 1, 1, 130, 1, 3, 64, 1],
                                   [512] + Array(repeating: 1, count: 131) + [2, 129, 1]] {
                        let actual = GPTOSSPagedKVCache(window: window)
                        let oracle: any KVCache = if let window { RotatingKVCache(maxSize: window, keep: 0) } else { StandardKVCache() }
                        for count in chunks {
                            let position = actual.offset
                            let mask = actual.makeMask(n: count, windowSize: window, returnArray: false)
                            let referenceMask = oracle.makeMask(n: count, windowSize: window, returnArray: false)
                            equalMask(mask, referenceMask)
                            equalMask(actual.makeMask(n: count, windowSize: window, returnArray: true),
                                      oracle.makeMask(n: count, windowSize: window, returnArray: true))
                            let (keys, values) = rows(count, start: position, dtype: dtype)
                            let current = actual.update(keys: keys, values: values)
                            let expected = oracle.update(keys: keys, values: values)
                            equal(current.0, expected.0); equal(current.1, expected.1)
                            equal(actual.state[0], oracle.state[0]); equal(actual.state[1], oracle.state[1])
                            #expect(actual.offset == oracle.offset && actual.maxSize == oracle.maxSize)
                            #expect(actual.isTrimmable == oracle.isTrimmable)
                            if window != nil { #expect(actual.metaState == oracle.metaState) }
                            // Same SDPA, including denominator-only learned sinks.
                            // Small selected frames keep this a bounded CPU check.
                            if dtype == .float32 && count <= 3 && position % 31 == 0 {
                                let q = MLXArray((0..<(4 * count * 4)).map { Float($0 % 19 - 9) / 8 })
                                    .reshaped([1, 4, count, 4])
                                let sinks = MLXArray([Float(-1), 0, 0.5, 2])
                                equal(MLXFast.scaledDotProductAttention(queries: q, keys: current.0, values: current.1,
                                    scale: 0.5, mask: mask, sinks: sinks),
                                      MLXFast.scaledDotProductAttention(queries: q, keys: expected.0, values: expected.1,
                                    scale: 0.5, mask: referenceMask, sinks: sinks))
                            }
                            let retained = current.0.dim(2)
                            #expect(actual.pageCount == (retained + 63) / 64)
                            #expect(actual.allocatedBytes == actual.pageCount * 64 * 2 * 4 * 2 * dtype.size)
                            eval(actual.innerState())
                        }
                    }
                }
            }
        }
    }

    @Test func pagesAreDemandGrownAndCopiesTrimWithoutChangingTheirParent() {
        Device.withDefaultDevice(.cpu) {
            for window: Int? in [nil, 128] {
                let original = GPTOSSPagedKVCache(window: window)
                #expect(original.pageCount == 0 && original.allocatedBytes == 0)
                let first = rows(63, start: 0)
                _ = original.update(keys: first.0, values: first.1)
                eval(original.innerState())
                #expect(original.pageCount == 1)
                let saved = original.state.map { $0.asData().data }
                let child = original.copy()
                #expect(child.trim(7) == 7 && child.offset == 56)
                let addition = rows(10, start: 100)
                _ = child.update(keys: addition.0, values: addition.1)
                eval(child.innerState())
                #expect(original.offset == 63 && original.state.map { $0.asData().data } == saved)
                let restored = GPTOSSPagedKVCache(window: window)
                restored.state = child.state; restored.metaState = child.metaState
                let next = rows(1, start: 200)
                let a = child.update(keys: next.0, values: next.1)
                let b = restored.update(keys: next.0, values: next.1)
                equal(a.0, b.0); equal(a.1, b.1)
                #expect(child.offset == restored.offset)
            }
        }
    }

    @Test func aWrappedSlidingRingCopiesAndRestoresItsAbsolutePositionAndPhysicalOrder() {
        Device.withDefaultDevice(.cpu) {
            let original = GPTOSSPagedKVCache(window: 128)
            let oracle = RotatingKVCache(maxSize: 128, keep: 0)
            for count in [512] + Array(repeating: 1, count: 65) {
                let input = rows(count, start: original.offset)
                _ = original.update(keys: input.0, values: input.1)
                _ = oracle.update(keys: input.0, values: input.1)
                eval(original.innerState() + oracle.innerState())
            }
            let saved = original.state.map { $0.asData().data }
            let copy = original.copy(), expected = oracle.copy()
            let restored = GPTOSSPagedKVCache(window: 128)
            restored.state = original.state; restored.metaState = original.metaState
            for count in [1, 64, 1, 129, 1] {
                let input = rows(count, start: expected.offset)
                equalMask(restored.makeMask(n: count, windowSize: 128, returnArray: false),
                    expected.makeMask(n: count, windowSize: 128, returnArray: false))
                let a = copy.update(keys: input.0, values: input.1)
                let b = restored.update(keys: input.0, values: input.1)
                let c = expected.update(keys: input.0, values: input.1)
                equal(a.0, c.0); equal(a.1, c.1); equal(b.0, c.0); equal(b.1, c.1)
                #expect(copy.offset == expected.offset && restored.metaState == expected.metaState)
                eval(copy.innerState() + restored.innerState())
            }
            #expect(original.offset == 577 && original.state.map { $0.asData().data } == saved)
        }
    }

    @Test func slidingPagesStayBoundedAndRequestRetirementDropsEveryOwner() {
        Device.withDefaultDevice(.cpu) {
            weak var released: GPTOSSPagedKVCache?
            autoreleasepool {
                let cache = GPTOSSPagedKVCache(window: 128)
                released = cache
                for n in [512, 512, 1] + Array(repeating: 1, count: 128) {
                    let input = rows(n, start: cache.offset)
                    _ = cache.update(keys: input.0, values: input.1)
                    eval(cache.innerState())
                }
                #expect(cache.offset == 1153 && cache.pageCount == 2)
                #expect(!cache.isTrimmable && cache.trim(1) == 0)
            }
            #expect(released == nil)
        }
    }
}
