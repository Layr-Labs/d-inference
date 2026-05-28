import Foundation
import Testing
@testable import MLX
@testable import MLXLMCommon

// Empirical resolution of the SSD-KV-cache "rotating restore" hazard.
//
// Two agents disagreed on whether RotatingKVCache survives a
// snapshot → restore → resume cycle:
//   - investigator: works at an exact checkpoint
//   - adversary: temporalOrder() assumes the circular write-cursor
//     `idx` is consistent, which "breaks on restore + multi-token
//     prefill", silently scrambling token order.
//
// These tests settle it from runtime behaviour. The mechanism that
// decides it: `metaState` serializes [keep, maxCacheSize, step,
// offset, idx] (KVCache.swift:627) and the setter restores `idx`
// (line 652) and `offset` (651). So IF a caller restores BOTH
// `.state` and `.metaState`, the cache's internal invariant should be
// reconstructed exactly and temporalOrder should behave identically.
//
// Each token t is encoded as K=t, V=t+100 across all dims, so the
// returned (keys, values) reveal exactly which tokens are present and
// in what order — any scrambling shows up as a content mismatch.

private let B = 1, H = 1, D = 2

/// Single-token K/V for token value `t`, shape [B,H,1,D].
private func tok(_ t: Float) -> (MLXArray, MLXArray) {
    let k = MLXArray(Array(repeating: t, count: B * H * 1 * D), [B, H, 1, D])
    let v = MLXArray(Array(repeating: t + 100, count: B * H * 1 * D), [B, H, 1, D])
    return (k, v)
}

/// Multi-token K/V for `tokens`, shape [B,H,tokens.count,D].
private func toks(_ tokens: [Float]) -> (MLXArray, MLXArray) {
    var kf: [Float] = []
    var vf: [Float] = []
    for t in tokens {
        for _ in 0..<(B * H * D) { kf.append(t) }
        for _ in 0..<(B * H * D) { vf.append(t + 100) }
    }
    let k = MLXArray(kf, [B, H, tokens.count, D])
    let v = MLXArray(vf, [B, H, tokens.count, D])
    return (k, v)
}

/// Round-trip a cache's full serialized form (state + metaState),
/// mirroring exactly what loadPromptCache does.
private func snapshotRestore(_ src: RotatingKVCache) -> RotatingKVCache {
    let s = src.state
    let m = src.metaState
    // maxSize is overwritten by the metaState setter; pass a placeholder.
    let dst = RotatingKVCache(maxSize: 1, keep: 0, step: 1)
    dst.state = s
    dst.metaState = m
    return dst
}

private func feedSingles(_ cache: RotatingKVCache, _ tokens: [Float]) {
    for t in tokens {
        let (k, v) = tok(t)
        _ = cache.update(keys: k, values: v)
        eval(cache.innerState())
    }
}

@Test
func rotatingRestoreThenMultiTokenPrefillMatchesReference() {
    // maxSize 4 with 10 single-token updates forces the circular buffer
    // to wrap multiple times, so `idx` is mid-buffer (not 0) at snapshot
    // — precisely the state the adversary said breaks on restore.
    let prefix: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    let cont: [Float] = [10, 11, 12]  // multi-token → updateConcat path

    // Reference: never reset.
    let ref = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    feedSingles(ref, prefix)
    let (kc, vc) = toks(cont)
    let (kRef, vRef) = ref.update(keys: kc, values: vc)
    eval(kRef, vRef)

    // Restored: snapshot after the prefix, restore, then same multi-token update.
    let snap = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    feedSingles(snap, prefix)
    let restored = snapshotRestore(snap)
    let (kc2, vc2) = toks(cont)
    let (kRes, vRes) = restored.update(keys: kc2, values: vc2)
    eval(kRes, vRes)

    #expect(kRes.shape == kRef.shape, "restored key shape \(kRes.shape) != reference \(kRef.shape)")
    #expect(vRes.shape == vRef.shape, "restored value shape \(vRes.shape) != reference \(vRef.shape)")
    #expect(
        kRes.asArray(Float.self) == kRef.asArray(Float.self),
        "restored keys \(kRes.asArray(Float.self)) != reference \(kRef.asArray(Float.self)) — temporalOrder scrambled on restore"
    )
    #expect(
        vRes.asArray(Float.self) == vRef.asArray(Float.self),
        "restored values mismatch — temporalOrder scrambled on restore"
    )
}

@Test
func rotatingRestoreThenSingleTokenDecodeMatchesReference() {
    // The other update path: single-token decode after restore (updateInPlace).
    let prefix: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

    let ref = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    feedSingles(ref, prefix)
    let (kr, vr) = tok(10)
    let (kRef, vRef) = ref.update(keys: kr, values: vr)
    eval(kRef, vRef)

    let snap = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    feedSingles(snap, prefix)
    let restored = snapshotRestore(snap)
    let (kr2, vr2) = tok(10)
    let (kRes, vRes) = restored.update(keys: kr2, values: vr2)
    eval(kRes, vRes)

    #expect(kRes.shape == kRef.shape)
    #expect(kRes.asArray(Float.self) == kRef.asArray(Float.self),
            "single-token decode after restore diverged from reference")
    #expect(vRes.asArray(Float.self) == vRef.asArray(Float.self))
}

@Test
func rotatingRestoreBeforeWrapMatchesReference() {
    // Pre-wrap case: only 3 tokens into a window of 4 (no rotation yet).
    let prefix: [Float] = [0, 1, 2]
    let cont: [Float] = [3, 4]

    let ref = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    feedSingles(ref, prefix)
    let (kc, vc) = toks(cont)
    let (kRef, vRef) = ref.update(keys: kc, values: vc)
    eval(kRef, vRef)

    let snap = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    feedSingles(snap, prefix)
    let restored = snapshotRestore(snap)
    let (kc2, vc2) = toks(cont)
    let (kRes, vRes) = restored.update(keys: kc2, values: vc2)
    eval(kRes, vRes)

    #expect(kRes.asArray(Float.self) == kRef.asArray(Float.self),
            "pre-wrap restore diverged from reference")
    #expect(vRes.asArray(Float.self) == vRef.asArray(Float.self))
}

@Test
func omittingMetaStateOnRestoreCorruptsOrder() {
    // Contract check: restoring .state WITHOUT .metaState leaves idx/offset
    // at their init values (0). This SHOULD corrupt the post-wrap result,
    // proving idx-restore is load-bearing — i.e. the adversary's failure
    // mode is real, but only under misuse (state without metaState).
    let prefix: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    let cont: [Float] = [10, 11, 12]

    let ref = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    feedSingles(ref, prefix)
    let (kc, vc) = toks(cont)
    let (kRef, _) = ref.update(keys: kc, values: vc)
    eval(kRef)

    let snap = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    feedSingles(snap, prefix)
    // Restore state ONLY — deliberately skip metaState.
    let broken = RotatingKVCache(maxSize: 4, keep: 0, step: 4)
    broken.state = snap.state
    let (kc2, vc2) = toks(cont)
    let (kBroken, _) = broken.update(keys: kc2, values: vc2)
    eval(kBroken)

    // With idx/offset unrestored, the result should differ from reference
    // (shape and/or content). If it somehow matches, the invariant wasn't
    // actually load-bearing for this case — surface that.
    let mismatch =
        kBroken.shape != kRef.shape
        || kBroken.asArray(Float.self) != kRef.asArray(Float.self)
    #expect(mismatch, "expected corruption when metaState (idx/offset) is not restored")
}
