import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon

/// Cache-layer unit tests that don't load any model. We feed synthetic
/// `[B, kvHeads, T, D]` MLXArrays into BatchKVCache and verify the
/// cache invariants:
///
///   * update() returns the right (k, v) shape and content
///   * batchOffset advances by stepCount per update
///   * filter() keeps the right rows and shifts left padding
///   * extend() right-justifies and concatenates correctly
///   * extract() round-trips a single row through KVCacheSimple
///   * merge() builds a batched cache from singles with right-justified data
///   * mask blocks left-padded slots and is causal
///
/// These tests are the foundation that the iterator + scheduler layer
/// builds on. If they pass and the model dispatch is wired correctly via
/// `applyRotaryPosition`, the whole continuous-batching pipeline is built
/// on solid ground.
@Suite("BatchKVCache continuous-batching cache")
struct BatchKVCacheTests {

    /// Ensure mlx.metallib is colocated next to the test bundle's binary
    /// before any `MLXArray` op runs. Without this, MLX's dladdr lookup
    /// can't find the metallib and any GPU op crashes with `Failed to
    /// load the default metallib`.
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }


    // MARK: - construction

    @Test("init with leftPadding sets per-row offsets to -leftPadding")
    func initSetsNegativeOffsets() {
        let cache = BatchKVCache(leftPadding: [1, 3, 0])

        let off = cache.batchOffset.asArray(Int32.self)
        #expect(off == [-1, -3, 0])

        let lp = cache.leftPadding.asArray(Int32.self)
        #expect(lp == [1, 3, 0])

        #expect(cache.size() == 0)
        #expect(cache.isEmpty())
    }

    // MARK: - update_and_fetch

    @Test("first update sizes storage and writes data")
    func firstUpdateSizesStorage() {
        let cache = BatchKVCache(leftPadding: [0, 0])
        let B = 2
        let H = 1
        let T = 3
        let D = 4
        let k = MLXArray.ones([B, H, T, D])
        let v = MLXArray.ones([B, H, T, D]) * Float32(2)

        let (rk, rv) = cache.update(keys: k, values: v)
        eval(rk, rv)

        #expect(rk.shape == [B, H, T, D])
        #expect(rv.shape == [B, H, T, D])
        #expect(cache.size() == T)

        let off = cache.batchOffset.asArray(Int32.self)
        #expect(off == [Int32(T), Int32(T)])

        // Returned data must equal what we wrote.
        let kArr = rk.asArray(Float.self)
        #expect(kArr.allSatisfy { $0 == 1.0 })
        let vArr = rv.asArray(Float.self)
        #expect(vArr.allSatisfy { $0 == 2.0 })
    }

    @Test("second update grows the cache and advances offsets per row")
    func secondUpdateAdvances() {
        let cache = BatchKVCache(leftPadding: [0, 0])
        let B = 2, H = 1, D = 4
        let k1 = MLXArray.ones([B, H, 2, D])
        let v1 = MLXArray.ones([B, H, 2, D])
        _ = cache.update(keys: k1, values: v1)

        // Advance: write 1 more token.
        let k2 = MLXArray.ones([B, H, 1, D]) * Float32(7)
        let v2 = MLXArray.ones([B, H, 1, D]) * Float32(9)
        let (rk, rv) = cache.update(keys: k2, values: v2)
        eval(rk, rv)

        #expect(rk.shape == [B, H, 3, D])
        #expect(cache.size() == 3)
        let off = cache.batchOffset.asArray(Int32.self)
        #expect(off == [3, 3])

        // Position 2 along axis=2 should be the new value.
        let lastK = rk[.ellipsis, 2 ..< 3, 0...].asArray(Float.self)
        #expect(lastK.allSatisfy { $0 == 7.0 })
        let lastV = rv[.ellipsis, 2 ..< 3, 0...].asArray(Float.self)
        #expect(lastV.allSatisfy { $0 == 9.0 })
    }

    // MARK: - leftPadding semantics

    @Test("offsets respect per-row leftPadding")
    func offsetsRespectLeftPadding() {
        // Three rows, leftPadding [2, 0, 1]. Their effective starting
        // offsets must be [-2, 0, -1] respectively. After we update with
        // T=3 tokens, the per-row offsets should be [1, 3, 2].
        let cache = BatchKVCache(leftPadding: [2, 0, 1])
        let B = 3, H = 1, T = 3, D = 4
        _ = cache.update(
            keys: MLXArray.zeros([B, H, T, D]),
            values: MLXArray.zeros([B, H, T, D])
        )

        let off = cache.batchOffset.asArray(Int32.self)
        #expect(off == [1, 3, 2])

        // size() returns the rightmost edge across all rows.
        #expect(cache.size() == T)
    }

    // MARK: - filter (eviction)

    @Test("filter keeps only the requested rows and shifts left-padding")
    func filterKeepsRowsAndShifts() {
        // 4 rows with leftPadding [3, 0, 1, 2]. After 3 updates of 1 token
        // each, the per-row offsets are [0, 3, 2, 1], _idx = 3.
        let cache = BatchKVCache(leftPadding: [3, 0, 1, 2])
        let B = 4, H = 1, D = 4
        for _ in 0 ..< 3 {
            _ = cache.update(
                keys: MLXArray.zeros([B, H, 1, D]),
                values: MLXArray.zeros([B, H, 1, D])
            )
        }

        // Keep rows 1 and 2. After filter, leftPadding becomes [0, 1].
        // min-leftPad shift drops 0, no shift happens.
        cache.filter(batchIndices: MLXArray([Int32(1), Int32(2)]))
        #expect(cache.batchOffset.asArray(Int32.self) == [3, 2])
        #expect(cache.leftPadding.asArray(Int32.self) == [0, 1])
        #expect(cache.size() == 3)

        // Now keep just row 1 (which had leftPadding 1) -- that becomes the
        // only retained row, so min-leftPad shift kicks in and shaves 1.
        cache.filter(batchIndices: MLXArray([Int32(1)]))
        #expect(cache.batchOffset.asArray(Int32.self) == [2])
        #expect(cache.leftPadding.asArray(Int32.self) == [0])
        #expect(cache.size() == 2)
    }

    // MARK: - extend (admission)

    @Test("extend on two empty caches concatenates metadata")
    func extendEmptyCaches() {
        let a = BatchKVCache(leftPadding: [0, 1])
        let b = BatchKVCache(leftPadding: [2])
        a.extend(b)
        #expect(a.batchOffset.asArray(Int32.self) == [0, -1, -2])
        #expect(a.leftPadding.asArray(Int32.self) == [0, 1, 2])
        #expect(a.size() == 0)
    }

    @Test("extend right-justifies before concatenating")
    func extendRightJustifies() {
        // a: 2 rows, ran 4 update steps with no leftPadding.
        // b: 1 row, ran 2 update steps with no leftPadding.
        // After extend, a should have 3 rows; b's row gets 2 left-padding.
        let a = BatchKVCache(leftPadding: [0, 0])
        let H = 1, D = 4
        for _ in 0 ..< 4 {
            _ = a.update(
                keys: MLXArray.ones([2, H, 1, D]),
                values: MLXArray.ones([2, H, 1, D])
            )
        }
        let b = BatchKVCache(leftPadding: [0])
        for _ in 0 ..< 2 {
            _ = b.update(
                keys: MLXArray.ones([1, H, 1, D]) * Float32(5),
                values: MLXArray.ones([1, H, 1, D]) * Float32(5)
            )
        }

        a.extend(b)
        #expect(a.batchOffset.asArray(Int32.self) == [4, 4, 2])
        #expect(a.leftPadding.asArray(Int32.self) == [0, 0, 2])
        #expect(a.size() == 4)
        // After extend, all rows are in one tensor with batch dim = 3 and
        // head dim H. The time dim is the max storage size of the two
        // caches (both pre-allocate in BatchKVCache.allocationStep = 256
        // chunks), not the meaningful _idx. The meaningful invariant is
        // that the rightmost _idx slots are the actual data.
        #expect(a.keys?.dim(0) == 3)
        #expect(a.keys?.dim(1) == H)
        #expect(a.keys?.dim(3) == D)
        // size() above already asserts _idx; keys.dim(2) should be at least _idx
        // and a multiple of the allocation step (or the equal of it for
        // homogeneous storage like here).
        #expect(a.keys!.dim(2) >= a.size())
    }

    // MARK: - extract

    @Test("extract pulls a single row out as KVCacheSimple")
    func extractSingleRow() {
        let cache = BatchKVCache(leftPadding: [1, 0])
        let H = 1, D = 4
        _ = cache.update(
            keys: MLXArray(0 ..< Int32(2 * H * 3 * D))
                .asType(.float32)
                .reshaped([2, H, 3, D]),
            values: MLXArray.ones([2, H, 3, D])
        )

        let extracted = cache.extract(0)
        // Row 0 had leftPadding 1, so its real data lives at axis-2 indices
        // [1, 3). extracted.offset reports the real length (= 2).
        #expect(extracted.offset == 2)
        let (rk, _) = extracted.update(
            keys: MLXArray.zeros([1, H, 0, D]),
            values: MLXArray.zeros([1, H, 0, D])
        )
        eval(rk)
        #expect(rk.shape == [1, H, 2, D])
    }

    // MARK: - merge

    @Test("merge builds a batched cache from singles with right-justification")
    func mergeFromSingleCaches() {
        let H = 1, D = 4
        // Three single-row caches with offsets 4, 1, 3.
        let s0 = KVCacheSimple()
        _ = s0.update(
            keys: MLXArray.ones([1, H, 4, D]),
            values: MLXArray.ones([1, H, 4, D])
        )
        let s1 = KVCacheSimple()
        _ = s1.update(
            keys: MLXArray.ones([1, H, 1, D]) * Float32(2),
            values: MLXArray.ones([1, H, 1, D]) * Float32(2)
        )
        let s2 = KVCacheSimple()
        _ = s2.update(
            keys: MLXArray.ones([1, H, 3, D]) * Float32(3),
            values: MLXArray.ones([1, H, 3, D]) * Float32(3)
        )

        let merged = BatchKVCache.merge([s0, s1, s2])
        #expect(merged.size() == 4)
        #expect(merged.batchOffset.asArray(Int32.self) == [4, 1, 3])
        #expect(merged.leftPadding.asArray(Int32.self) == [0, 3, 1])
        #expect(merged.keys?.shape == [3, H, 4, D])
    }

    // MARK: - mask

    @Test("mask blocks left-padded slots and is causal")
    func maskBlocksLeftPadded() {
        // Two rows: row 0 has leftPadding=2, row 1 has leftPadding=0.
        // After running 1 update of T=3, _idx=3.
        // For an n=1 next-step query the mask must be shape [B,1,1,4]
        // (offset+n = 3+1) and:
        //   row 0: positions [0,1] blocked (leftPadding), [2,3] visible
        //   row 1: all positions [0..3] visible
        let cache = BatchKVCache(leftPadding: [2, 0])
        _ = cache.update(
            keys: MLXArray.zeros([2, 1, 3, 4]),
            values: MLXArray.zeros([2, 1, 3, 4])
        )

        let mask = cache.makeMask(n: 1, windowSize: nil, returnArray: true)
        guard case .array(let arr) = mask else {
            Issue.record("expected .array mask, got \(mask)")
            return
        }
        eval(arr)
        // The exact mask shape is [B, 1, 1, 4].
        #expect(arr.dim(0) == 2)
        // Row 0: first two slots must be false (blocked), last two true.
        let row0 = arr[0 ..< 1, 0..., 0..., 0...].squeezed().asArray(Bool.self)
        #expect(row0.count == 4)
        #expect(row0[0] == false)
        #expect(row0[1] == false)
        #expect(row0[2] == true)
        #expect(row0[3] == true)
        // Row 1: all four slots must be true (causally visible).
        let row1 = arr[1 ..< 2, 0..., 0..., 0...].squeezed().asArray(Bool.self)
        #expect(row1 == [true, true, true, true])
    }

    @Test("single-token decode with no left padding emits no explicit mask")
    func decodeNoPaddingReturnsNoneMask() {
        // MLX #3384 workaround: a decode step (n=1) over a batch with zero
        // left padding must NOT inject an explicit boolean mask, because the
        // fast-attention kernel's explicit-mask path numerically diverges on
        // 4-bit Gemma 4 and traps generation in repetition loops. Every stored
        // key is a real token here, so the unmasked causal path is correct.
        let cache = BatchKVCache(leftPadding: [0, 0])
        _ = cache.update(
            keys: MLXArray.zeros([2, 1, 5, 4]),
            values: MLXArray.zeros([2, 1, 5, 4])
        )

        let mask = cache.makeMask(n: 1, windowSize: nil, returnArray: true)
        guard case .none = mask else {
            Issue.record("expected .none mask for unpadded n=1 decode, got \(mask)")
            return
        }

        // But a padded row at n=1 still needs the explicit mask to block its
        // padding slots — the workaround must not weaken correctness there.
        let padded = BatchKVCache(leftPadding: [1, 0])
        _ = padded.update(
            keys: MLXArray.zeros([2, 1, 5, 4]),
            values: MLXArray.zeros([2, 1, 5, 4])
        )
        guard case .array = padded.makeMask(n: 1, windowSize: nil, returnArray: true) else {
            Issue.record("expected .array mask when any row is left-padded")
            return
        }
    }

    // MARK: - dynamicRoll helper

    @Test("dynamicRoll shifts each row by its own amount along axis")
    func dynamicRollPerRow() {
        // x shape [3, 5], shifts [1, 0, 2] applied along axis=1.
        // Expected: row 0 shifts right by 1, row 1 unchanged, row 2 shifts by 2.
        let x = MLXArray(0 ..< Int32(15)).reshaped([3, 5]).asType(.float32)
        let shifts = MLXArray([Int32(1), Int32(0), Int32(2)])[0..., .newAxis]
        let rolled = dynamicRoll(x, shifts: shifts, axis: 1)
        eval(rolled)

        let result = rolled.asArray(Float.self)
        // Row 0 (originally [0,1,2,3,4]) shifted by 1: [4,0,1,2,3]
        #expect(Array(result[0 ..< 5]) == [4, 0, 1, 2, 3])
        // Row 1 (originally [5,6,7,8,9]) unchanged
        #expect(Array(result[5 ..< 10]) == [5, 6, 7, 8, 9])
        // Row 2 (originally [10,11,12,13,14]) shifted by 2: [13,14,10,11,12]
        #expect(Array(result[10 ..< 15]) == [13, 14, 10, 11, 12])
    }

    // MARK: - protocol conformance

    @Test("conforms to BatchPositionedKVCache for RoPE dispatch")
    func conformsToBatchPositionedKVCache() {
        let cache: KVCache = BatchKVCache(leftPadding: [1, 2, 3])
        // Cast must succeed -- this is what models check at every layer.
        let batched = cache as? BatchPositionedKVCache
        #expect(batched != nil)
        #expect(batched?.batchOffset.dim(0) == 3)
    }
}
