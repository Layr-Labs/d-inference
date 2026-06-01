import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon

// Verifies the SLIDING-WINDOW batched path our SSD-KV-cache design
// actually uses for GPT-OSS-20B and Gemma-4 26B-A4B:
//
//   live BatchRotatingKVCache  --extract(row)-->  single-stream
//   RotatingKVCache (with full metaState)  --snapshot/restore-->
//   resume.
//
// We never serialize the BatchRotatingKVCache directly (its own
// metaState omits maxCacheSize/idx). Instead extract(idx)
// (BatchKVCache.swift:726) returns a RotatingKVCache whose state +
// metaState are fully populated — and the single-stream round-trip is
// already proven in RotatingKVCacheRestoreTests. These tests close the
// loop: (a) extraction isolates the right row, and (b) the extracted
// cache survives snapshot → restore → resume identically.

private let H = 1, D = 2

/// Build batched [B,H,T,D] K/V where rows[r][t] is the token value at
/// row r, position t. V = K + 100 so keys and values are distinguishable.
private func batched(_ rows: [[Float]]) -> (MLXArray, MLXArray) {
    let Bn = rows.count
    let T = rows[0].count
    var kf: [Float] = []
    var vf: [Float] = []
    for r in 0..<Bn {
        for t in 0..<T {
            for _ in 0..<D { kf.append(rows[r][t]) }
        }
    }
    for r in 0..<Bn {
        for t in 0..<T {
            for _ in 0..<D { vf.append(rows[r][t] + 100) }
        }
    }
    return (MLXArray(kf, [Bn, H, T, D]), MLXArray(vf, [Bn, H, T, D]))
}

/// Round-trip a single-stream RotatingKVCache through state + metaState
/// exactly as loadPromptCache would.
private func snapshotRestore(_ src: RotatingKVCache) -> RotatingKVCache {
    let s = src.state
    let m = src.metaState
    let dst = RotatingKVCache(maxSize: 1, keep: 0, step: 1)
    dst.state = s
    dst.metaState = m
    return dst
}

/// Feed `count` single-token steps; row r gets value base[r] + step.
private func feedBatchedSingles(_ cache: BatchRotatingKVCache, bases: [Float], count: Int) {
    for s in 0..<count {
        let rows = bases.map { [$0 + Float(s)] }
        let (k, v) = batched(rows)
        _ = cache.update(keys: k, values: v)
        eval(cache.innerState())
    }
}

@Test
func batchRotatingExtractIsolatesRow() {
    // Two rows; window 4; feed 10 single tokens each.
    // row 0 values: 0..9   → window holds 6,7,8,9
    // row 1 values: 1000..1009 → window holds 1006,1007,1008,1009
    let bc = BatchRotatingKVCache(maxSize: 4, leftPadding: [0, 0])
    feedBatchedSingles(bc, bases: [0, 1000], count: 10)

    let r0 = bc.extract(0)
    let r1 = bc.extract(1)
    let k0 = r0.state[0].asArray(Float.self)
    let k1 = r1.state[0].asArray(Float.self)

    #expect(k0.allSatisfy { $0 < 1000 }, "row 0 extract leaked row 1 tokens: \(k0)")
    #expect(k1.allSatisfy { $0 >= 1000 }, "row 1 extract leaked row 0 tokens: \(k1)")
    // Window size 4 → 4 tokens retained.
    #expect(r0.state[0].dim(2) == 4, "expected 4 windowed tokens, got \(r0.state[0].dim(2))")
}

@Test
func batchRotatingExtractThenRestoreThenMultiTokenMatches() {
    let cont: [Float] = [10, 11, 12]

    // Path A: extract then resume (no snapshot).
    let bcA = BatchRotatingKVCache(maxSize: 4, leftPadding: [0, 0])
    feedBatchedSingles(bcA, bases: [0, 1000], count: 10)
    let rcA = bcA.extract(0)
    let (kc, vc) = batched([cont])  // single row continuation
    let (kRef, vRef) = rcA.update(keys: kc, values: vc)
    eval(kRef, vRef)

    // Path B: extract, snapshot+restore, then resume.
    let bcB = BatchRotatingKVCache(maxSize: 4, leftPadding: [0, 0])
    feedBatchedSingles(bcB, bases: [0, 1000], count: 10)
    let rcB = snapshotRestore(bcB.extract(0))
    let (kc2, vc2) = batched([cont])
    let (kRes, vRes) = rcB.update(keys: kc2, values: vc2)
    eval(kRes, vRes)

    #expect(kRes.shape == kRef.shape, "shape \(kRes.shape) != \(kRef.shape)")
    #expect(kRes.asArray(Float.self) == kRef.asArray(Float.self),
            "restored keys diverged: \(kRes.asArray(Float.self)) vs \(kRef.asArray(Float.self))")
    #expect(vRes.asArray(Float.self) == vRef.asArray(Float.self),
            "restored values diverged")
}

@Test
func batchRotatingExtractMatchesIndependentSingleStreamReference() {
    // XC-1: the other roundtrip tests use extract() on BOTH sides, so
    // they only prove snapshot/restore idempotency. This one builds the
    // reference WITHOUT extract(): an independent single-stream
    // RotatingKVCache fed exactly the tokens row 0 received, then
    // compares its resume against the batched-extract-then-resume. This
    // proves extract() produces a cache semantically equivalent to one
    // that never went through the batched path.
    let rowTokens: [Float] = Array(0...9).map { Float($0) }
    let cont: [Float] = [10, 11, 12]

    // Independent single-stream reference: feed row-0's tokens directly.
    let ref = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    for t in rowTokens {
        let (k, v) = batched([[t]])  // single row, single token
        _ = ref.update(keys: k, values: v)
        eval(ref.innerState())
    }
    let (kc, vc) = batched([cont])
    let (kRef, vRef) = ref.update(keys: kc, values: vc)
    eval(kRef, vRef)

    // Batched path: feed both rows, extract row 0, resume.
    let bc = BatchRotatingKVCache(maxSize: 4, leftPadding: [0, 0])
    feedBatchedSingles(bc, bases: [0, 1000], count: 10)
    let extracted = bc.extract(0)
    let (kc2, vc2) = batched([cont])
    let (kRes, vRes) = extracted.update(keys: kc2, values: vc2)
    eval(kRes, vRes)

    #expect(kRes.shape == kRef.shape,
            "batched-extract shape \(kRes.shape) != independent single-stream \(kRef.shape)")
    #expect(kRes.asArray(Float.self) == kRef.asArray(Float.self),
            "batched-extract keys diverged from independent single-stream reference")
    #expect(vRes.asArray(Float.self) == vRef.asArray(Float.self),
            "batched-extract values diverged from independent single-stream reference")
}

@Test
func batchRotatingFromSingleRowResumeMatchesIndependentReference() {
    // RESTORE-SIDE proof for the hybrid checkpoint tier: the full loop a
    // restored SSD checkpoint takes — extract(row) → snapshot/restore (as
    // KVCacheSerializer does) → fromSingleRow → decode as batch row 0 —
    // must match an independent single-stream RotatingKVCache that was fed
    // exactly row 0's tokens and never went through any batched/restore
    // path. This proves fromSingleRow is a correct inverse of extract.
    let rowTokens: [Float] = Array(0...9).map { Float($0) }
    let cont: [Float] = [10, 11, 12]

    // Independent reference: single-stream, fed row-0's tokens directly.
    let ref = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    for t in rowTokens {
        let (k, v) = batched([[t]])
        _ = ref.update(keys: k, values: v)
        eval(ref.innerState())
    }
    let (kc, vc) = batched([cont])
    let (kRef, vRef) = ref.update(keys: kc, values: vc)
    eval(kRef, vRef)

    // Restore path: batched → extract row 0 → snapshot/restore →
    // fromSingleRow (B=1 batched) → decode the same continuation.
    let bc = BatchRotatingKVCache(maxSize: 4, leftPadding: [0, 0])
    feedBatchedSingles(bc, bases: [0, 1000], count: 10)
    let restored = snapshotRestore(bc.extract(0))
    let b1 = BatchRotatingKVCache.fromSingleRow(restored)
    let (kc2, vc2) = batched([cont])
    let (kRes, vRes) = b1.update(keys: kc2, values: vc2)
    eval(kRes, vRes)

    #expect(kRes.shape == kRef.shape,
            "fromSingleRow shape \(kRes.shape) != independent reference \(kRef.shape)")
    #expect(kRes.asArray(Float.self) == kRef.asArray(Float.self),
            "fromSingleRow keys diverged from independent single-stream reference")
    #expect(vRes.asArray(Float.self) == vRef.asArray(Float.self),
            "fromSingleRow values diverged from independent single-stream reference")
}

@Test
func batchRotatingFromSingleRowPreWrapMatchesReference() {
    // Pre-wrap case: only 3 tokens into a window of 4 (no rotation yet),
    // so the restored cache is shorter than the window. fromSingleRow must
    // continue correctly from the partial fill.
    let rowTokens: [Float] = [0, 1, 2]
    let cont: [Float] = [3, 4]

    let ref = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    for t in rowTokens {
        let (k, v) = batched([[t]]); _ = ref.update(keys: k, values: v); eval(ref.innerState())
    }
    let (kc, vc) = batched([cont])
    let (kRef, vRef) = ref.update(keys: kc, values: vc); eval(kRef, vRef)

    let bc = BatchRotatingKVCache(maxSize: 4, leftPadding: [0])
    feedBatchedSingles(bc, bases: [0], count: 3)
    let b1 = BatchRotatingKVCache.fromSingleRow(snapshotRestore(bc.extract(0)))
    let (kc2, vc2) = batched([cont])
    let (kRes, vRes) = b1.update(keys: kc2, values: vc2); eval(kRes, vRes)

    #expect(kRes.asArray(Float.self) == kRef.asArray(Float.self),
            "pre-wrap fromSingleRow diverged from reference")
    #expect(vRes.asArray(Float.self) == vRef.asArray(Float.self))
}

@Test
func batchRotatingExtractThenRestoreThenSingleTokenMatches() {
    let bcA = BatchRotatingKVCache(maxSize: 4, leftPadding: [0, 0])
    feedBatchedSingles(bcA, bases: [0, 1000], count: 10)
    let rcA = bcA.extract(0)
    let (kc, vc) = batched([[10]])
    let (kRef, vRef) = rcA.update(keys: kc, values: vc)
    eval(kRef, vRef)

    let bcB = BatchRotatingKVCache(maxSize: 4, leftPadding: [0, 0])
    feedBatchedSingles(bcB, bases: [0, 1000], count: 10)
    let rcB = snapshotRestore(bcB.extract(0))
    let (kc2, vc2) = batched([[10]])
    let (kRes, vRes) = rcB.update(keys: kc2, values: vc2)
    eval(kRes, vRes)

    #expect(kRes.asArray(Float.self) == kRef.asArray(Float.self),
            "single-token decode after batched-extract restore diverged")
    #expect(vRes.asArray(Float.self) == vRef.asArray(Float.self))
}
