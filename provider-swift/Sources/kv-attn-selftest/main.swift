import Foundation
import MLX
import MLXFast
import MLXLMCommon
import MLXRandom
import ProviderCore

// Deterministic numerical correctness probe for `quantizedScaledDotProductAttention`.
//
// First-principles isolation: we quantize K/V, then compare
//   candidate = quantizedScaledDotProductAttention(Q, qK, qV)         (the kernel under test)
//   reference = scaledDotProductAttention(Q, dequant(qK), dequant(qV)) (same data, trusted path)
// Because both consume the SAME quantized data, any large difference is a KERNEL bug
// (layout/GQA/scale/mask), NOT quantization loss. At 8-bit the two must match closely.
// We also report candidate-vs-fp16 to show the (separate) quantization loss.

func maxAbsDiff(_ a: MLXArray, _ b: MLXArray) -> Float {
    abs(a - b).max().item(Float.self)
}

func meanAbs(_ a: MLXArray) -> Float {
    abs(a).mean().item(Float.self)
}

func buildCausalAdditiveMask(L: Int, Lk: Int) -> MLXArray {
    let qIdx = MLXArray((0..<L).map { Int32($0) }).reshaped([L, 1]) + MLXArray(Int32(Lk - L))
    let kIdx = MLXArray((0..<Lk).map { Int32($0) }).reshaped([1, Lk])
    let allowed = qIdx .>= kIdx
    return MLX.where(allowed, MLXArray(Float(0)), MLXArray(-Float.greatestFiniteMagnitude))
}

func runCase(
    _ name: String,
    B: Int, nQ: Int, nKV: Int, L: Int, Lk: Int, D: Int,
    bits: Int, groupSize: Int, causal: Bool
) {
    MLXRandom.seed(1234)
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, Lk, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, Lk, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()

    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let (vwq, vs, vb) = quantized(v, groupSize: groupSize, bits: bits)
    let kdq = dequantized(kwq, scales: ks, biases: kb, groupSize: groupSize, bits: bits)
    let vdq = dequantized(vwq, scales: vs, biases: vb, groupSize: groupSize, bits: bits)

    let additiveMask: MLXArray? = causal ? buildCausalAdditiveMask(L: L, Lk: Lk) : nil
    let dequantRef = MLXFast.scaledDotProductAttention(
        queries: q, keys: kdq, values: vdq, scale: scale, mask: additiveMask)
    let fp16Ref = MLXFast.scaledDotProductAttention(
        queries: q, keys: k, values: v, scale: scale, mask: additiveMask)

    let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = causal ? .causal : .none
    let candidate = quantizedScaledDotProductAttention(
        queries: q,
        quantizedKeys: (kwq, ks, kb),
        quantizedValues: (vwq, vs, vb),
        scale: scale,
        mask: maskMode,
        groupSize: groupSize,
        bits: bits,
        mode: .affine)

    eval(dequantRef, fp16Ref, candidate)

    let kernelDiff = maxAbsDiff(candidate, dequantRef)
    let totalDiff = maxAbsDiff(candidate, fp16Ref)
    let mag = max(meanAbs(dequantRef), 1e-9)
    let verdict = (kernelDiff / mag) < 0.02 ? "OK  " : "FAIL"
    print(
        "[\(verdict)] \(name): kernel_vs_dequantRef maxAbs=\(String(format: "%.5f", kernelDiff)) rel=\(String(format: "%.4f", kernelDiff / mag)) | total_vs_fp16 maxAbs=\(String(format: "%.5f", totalDiff)) | meanAbs(ref)=\(String(format: "%.5f", mag))"
    )
}

// Quantize K/V with injected outlier channels (mimics real LLM activation/RoPE
// outliers) and report attention error vs fp16. Isolates "is per-group affine
// quant lossy on realistic data?" from kernel correctness.
func runOutlierCase(_ name: String, bits: Int, groupSize: Int, scaleOutlier: Float) {
    MLXRandom.seed(7)
    let B = 1, nQ = 8, nKV = 2, L = 64, D = 128
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    var k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    var v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    // Inject a few large outlier channels (common in real K/V).
    var kMul = MLXArray.ones([D]).asType(.float32)
    kMul[3] = MLXArray(scaleOutlier)
    kMul[70] = MLXArray(scaleOutlier)
    k = k * kMul
    v = v * kMul
    let scale = 1.0 / Float(D).squareRoot()

    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let (vwq, vs, vb) = quantized(v, groupSize: groupSize, bits: bits)
    let mask = buildCausalAdditiveMask(L: L, Lk: L)
    let fp16Ref = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: mask)
    let candidate = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: (kwq, ks, kb), quantizedValues: (vwq, vs, vb),
        scale: scale, mask: .causal, groupSize: groupSize, bits: bits, mode: .affine)
    eval(fp16Ref, candidate)
    let diff = maxAbsDiff(candidate, fp16Ref)
    let mag = max(meanAbs(fp16Ref), 1e-9)
    print("[quant-loss] \(name): maxAbs=\(String(format: "%.5f", diff)) rel=\(String(format: "%.4f", diff / mag))")
}

// Multi-step decode through the ACTUAL QuantizedKVCache (exercises step/expand/trim).
func runMultiStepCacheTest(_ name: String, bits: Int, groupSize: Int) {
    MLXRandom.seed(99)
    let B = 1, nQ = 8, nKV = 2, L = 300, D = 128  // >256 to cross the step boundary
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()

    let cache = QuantizedKVCache(groupSize: groupSize, bits: bits)
    var lastQK: (MLXArray, MLXArray, MLXArray?) = (k, k, nil)
    var lastQV: (MLXArray, MLXArray, MLXArray?) = (v, v, nil)
    for t in 0..<L {
        let kt = k[0..., 0..., t..<(t + 1), 0...]
        let vt = v[0..., 0..., t..<(t + 1), 0...]
        (lastQK, lastQV) = cache.updateQuantized(keys: kt, values: vt)
    }
    // Storage correctness: dequantize the cache's full state, compare to one-shot quantize+dequantize.
    let dqK = dequantized(lastQK.0, scales: lastQK.1, biases: lastQK.2, groupSize: groupSize, bits: bits)
    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let dqKRef = dequantized(kwq, scales: ks, biases: kb, groupSize: groupSize, bits: bits)
    eval(dqK, dqKRef)
    let storageDiff = maxAbsDiff(dqK, dqKRef)

    // Attention for the last query against the full cached state vs fp16 reference.
    let qLast = q[0..., 0..., (L - 1)..<L, 0...]
    let cand = quantizedScaledDotProductAttention(
        queries: qLast, quantizedKeys: lastQK, quantizedValues: lastQV,
        scale: scale, mask: .none, groupSize: groupSize, bits: bits, mode: .affine)
    let ref = MLXFast.scaledDotProductAttention(queries: qLast, keys: k, values: v, scale: scale, mask: nil)
    eval(cand, ref)
    let attnDiff = maxAbsDiff(cand, ref)
    let mag = max(meanAbs(ref), 1e-9)
    let verdict = storageDiff < 1e-4 ? "OK  " : "FAIL"
    print("[\(verdict)] \(name): storage maxAbs=\(String(format: "%.6f", storageDiff)) | decode-attn vs fp16 maxAbs=\(String(format: "%.5f", attnDiff)) rel=\(String(format: "%.4f", attnDiff / mag))")
}

print("== quantizedScaledDotProductAttention numerical self-test ==")
for bits in [8, 4] {
    print("-- bits=\(bits), groupSize=64 --")
    runCase("MHA  no-mask ", B: 1, nQ: 4, nKV: 4, L: 16, Lk: 16, D: 128, bits: bits, groupSize: 64, causal: false)
    runCase("MHA  causal  ", B: 1, nQ: 4, nKV: 4, L: 16, Lk: 16, D: 128, bits: bits, groupSize: 64, causal: true)
    runCase("GQA  no-mask ", B: 1, nQ: 8, nKV: 2, L: 16, Lk: 16, D: 128, bits: bits, groupSize: 64, causal: false)
    runCase("GQA  causal  ", B: 1, nQ: 8, nKV: 2, L: 16, Lk: 16, D: 128, bits: bits, groupSize: 64, causal: true)
    runCase("GQA  decode  ", B: 1, nQ: 8, nKV: 2, L: 1, Lk: 16, D: 128, bits: bits, groupSize: 64, causal: false)
}

print("== outlier quantization loss (causal, g32) ==")
for bits in [8, 4] {
    runOutlierCase("outlier x1   bits=\(bits)", bits: bits, groupSize: 32, scaleOutlier: 1)
    runOutlierCase("outlier x20  bits=\(bits)", bits: bits, groupSize: 32, scaleOutlier: 20)
    runOutlierCase("outlier x100 bits=\(bits)", bits: bits, groupSize: 32, scaleOutlier: 100)
}

print("== multi-step QuantizedKVCache (decode, crosses step=256) ==")
for bits in [8, 4] {
    runMultiStepCacheTest("multistep bits=\(bits) g64", bits: bits, groupSize: 64)
}

// Per-channel key quantization (KIVI-style): scale/bias per head_dim channel,
// computed across the token axis, so an outlier channel gets its own scale.
// Returns dequantized keys to measure the SCHEME's quality (memory/kernel
// fusion handled separately later).
func perChannelDequant(_ x: MLXArray, bits: Int) -> MLXArray {
    // x: [B, H, L, D] -> per-channel along D, stats across L (axis 2)
    let levels = Float((1 << bits) - 1)
    let minv = x.min(axis: 2, keepDims: true)
    let maxv = x.max(axis: 2, keepDims: true)
    let scale = (maxv - minv) / levels
    let safeScale = MLX.where(scale .> 0, scale, MLXArray(Float(1)))
    let q = MLX.round((x - minv) / safeScale)
    let qc = clip(q, min: MLXArray(Float(0)), max: MLXArray(levels))
    return qc * safeScale + minv
}

func relL2(_ a: MLXArray, _ b: MLXArray) -> Float {
    let num = ((a - b) * (a - b)).sum().item(Float.self)
    let den = (b * b).sum().item(Float.self)
    return (num / max(den, 1e-12)).squareRoot()
}

func cosSim(_ a: MLXArray, _ b: MLXArray) -> Float {
    let dot = (a * b).sum().item(Float.self)
    let na = (a * a).sum().item(Float.self).squareRoot()
    let nb = (b * b).sum().item(Float.self).squareRoot()
    return dot / max(na * nb, 1e-12)
}

func perGroupDequant(_ x: MLXArray, bits: Int, groupSize: Int) -> MLXArray {
    let (wq, s, b) = quantized(x, groupSize: groupSize, bits: bits)
    return dequantized(wq, scales: s, biases: b, groupSize: groupSize, bits: bits)
}

// Isolate KEYS: V stays fp16, vary only the K scheme. Outliers injected into K only.
func runKScheme(_ label: String, kScheme: (MLXArray) -> MLXArray, scaleOutlier: Float) {
    MLXRandom.seed(7)
    let B = 1, nQ = 8, nKV = 2, L = 256, D = 128
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    var k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let kMul = MLXArray.ones([D]).asType(.float32)
    kMul[3] = MLXArray(scaleOutlier)
    kMul[70] = MLXArray(scaleOutlier)
    k = k * kMul
    let scale = 1.0 / Float(D).squareRoot()
    let mask = buildCausalAdditiveMask(L: L, Lk: L)

    let ref = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: scale, mask: mask)
    let cand = MLXFast.scaledDotProductAttention(queries: q, keys: kScheme(k), values: v, scale: scale, mask: mask)
    eval(ref, cand)
    print("  \(label): relL2=\(String(format: "%.4f", relL2(cand, ref)))  cos=\(String(format: "%.5f", cosSim(cand, ref)))")
}

print("== scorer mechanism probe (single-forward vs incremental, start-delay) ==")
print(KVQuantCacheProbe.run())

print("== KEY-ONLY isolation (V=fp16); per-group vs per-channel under outliers ==")
for s: Float in [1, 20, 100] {
    print("- outlier x\(Int(s)):")
    runKScheme("K8 per-group g32 ", kScheme: { perGroupDequant($0, bits: 8, groupSize: 32) }, scaleOutlier: s)
    runKScheme("K8 per-channel   ", kScheme: { perChannelDequant($0, bits: 8) }, scaleOutlier: s)
    runKScheme("K4 per-group g32 ", kScheme: { perGroupDequant($0, bits: 4, groupSize: 32) }, scaleOutlier: s)
    runKScheme("K4 per-channel   ", kScheme: { perChannelDequant($0, bits: 4) }, scaleOutlier: s)
}

// MARK: - DAR-314: QuantizedBatchKVCache kernel + storage gate

func dequantTuple(_ q: (MLXArray, MLXArray, MLXArray?), groupSize: Int, bits: Int) -> MLXArray {
    dequantized(q.0, scales: q.1, biases: q.2, groupSize: groupSize, bits: bits)
}

func runQuantizedBatchKernelCase(
    _ name: String,
    B: Int, nQ: Int, nKV: Int, L: Int, D: Int,
    leftPadding: [Int]? = nil,
    bits: Int, groupSize: Int,
    incremental: Bool = false
) -> Bool {
    let leftPadding = leftPadding ?? [Int](repeating: 0, count: B)
    MLXRandom.seed(31415)
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()

    // Zero out left-padded slots so the cache and reference agree on padding.
    for (b, pad) in leftPadding.enumerated() where pad > 0 {
        k[b, 0..., 0..<pad, 0...] = MLXArray(Float(0))
        v[b, 0..., 0..<pad, 0...] = MLXArray(Float(0))
    }

    let cache = QuantizedBatchKVCache(
        leftPadding: leftPadding,
        groupSize: groupSize,
        bits: bits,
        mode: .affine)

    // Build the mask *before* updating, matching real model usage.
    let maskMode = cache.makeMask(n: L, windowSize: nil, returnArray: true)
    let maskArray: MLXArray
    switch maskMode {
    case .array(let m): maskArray = m
    default:
        maskArray = createCausalMask(
            n: L, offset: cache.offset, windowSize: nil, leftPadding: cache.leftPadding)
    }
    let additiveMask = MLX.where(
        maskArray, MLXArray(Float(0)), MLXArray(-Float.greatestFiniteMagnitude))

    let (qk, qv): (
        (MLXArray, MLXArray, MLXArray?), (MLXArray, MLXArray, MLXArray?)
    )
    if incremental {
        var lastK: (MLXArray, MLXArray, MLXArray?) = (
            k, k, nil
        )
        var lastV: (MLXArray, MLXArray, MLXArray?) = (
            v, v, nil
        )
        for t in 0..<L {
            let kt = k[0..., 0..., t..<(t + 1), 0...]
            let vt = v[0..., 0..., t..<(t + 1), 0...]
            (lastK, lastV) = cache.updateQuantized(keys: kt, values: vt)
        }
        (qk, qv) = (lastK, lastV)
    } else {
        (qk, qv) = cache.updateQuantized(keys: k, values: v)
    }

    let candidate = quantizedScaledDotProductAttention(
        queries: q,
        quantizedKeys: qk,
        quantizedValues: qv,
        scale: scale,
        mask: maskMode,
        groupSize: groupSize,
        bits: bits,
        mode: .affine)

    let reference = MLXFast.scaledDotProductAttention(
        queries: q,
        keys: dequantTuple(qk, groupSize: groupSize, bits: bits),
        values: dequantTuple(qv, groupSize: groupSize, bits: bits),
        scale: scale,
        mask: additiveMask)

    let fp16Reference = MLXFast.scaledDotProductAttention(
        queries: q, keys: k, values: v, scale: scale, mask: additiveMask)

    eval(candidate, reference, fp16Reference)

    // Mask out left-padded query positions before comparing; the model does
    // not compute logits for those slots and the causal mask yields NaN there.
    let qPositions = MLXArray((0..<L).map { Int32($0) }).reshaped([1, 1, L])
    let validQuery = (qPositions .>= cache.leftPadding.reshaped([B, 1, 1]))
        .reshaped([B, 1, L, 1])
    let candidateMasked = MLX.where(validQuery, candidate, MLXArray(Float(0)))
    let referenceMasked = MLX.where(validQuery, reference, MLXArray(Float(0)))
    let fp16RefMasked = MLX.where(validQuery, fp16Reference, MLXArray(Float(0)))

    let kernelRel = relL2(candidateMasked, referenceMasked)
    let quantLossRel = relL2(candidateMasked, fp16RefMasked)
    let ok = kernelRel < 0.02
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] \(name) bits=\(bits): kernel_relL2=\(String(format: "%.5f", kernelRel)) quant_loss_relL2=\(String(format: "%.5f", quantLossRel))"
    )
    return ok
}

func runQuantizedBatchStorageCheck(bits: Int, groupSize: Int) -> Bool {
    MLXRandom.seed(27182)
    let B = 1, nKV = 2, L = 64, D = 128
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)

    let qCache = QuantizedBatchKVCache(
        leftPadding: [0], groupSize: groupSize, bits: bits, mode: .affine)
    let fpCache = BatchKVCache(leftPadding: [0])

    _ = qCache.update(keys: k, values: v)
    let (fpK, fpV) = fpCache.update(keys: k, values: v)

    guard let (qk, qv) = qCache.getQuantizedState() else {
        print("[FAIL] storage bits=\(bits): empty quantized state")
        return false
    }
    let dqK = dequantTuple(qk, groupSize: groupSize, bits: bits)
    let dqV = dequantTuple(qv, groupSize: groupSize, bits: bits)

    eval(dqK, dqV, fpK, fpV)
    let kRel = relL2(dqK, fpK)
    let vRel = relL2(dqV, fpV)
    let threshold: Float = bits == 8 ? 0.02 : 0.20
    let ok = max(kRel, vRel) < threshold
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] storage bits=\(bits): K_relL2=\(String(format: "%.5f", kRel)) V_relL2=\(String(format: "%.5f", vRel))"
    )
    return ok
}

print("== QuantizedBatchKVCache kernel correctness (DAR-314) ==")
var dar314Ok = true
for bits in [8, 4] {
    dar314Ok = runQuantizedBatchKernelCase(
        "case1 single-row", B: 1, nQ: 4, nKV: 4, L: 16, D: 128,
        bits: bits, groupSize: 64) && dar314Ok
    dar314Ok = runQuantizedBatchKernelCase(
        "case2 left-padding", B: 2, nQ: 4, nKV: 4, L: 16, D: 128,
        leftPadding: [0, 2], bits: bits, groupSize: 64) && dar314Ok
    dar314Ok = runQuantizedBatchKernelCase(
        "case3 GQA", B: 1, nQ: 8, nKV: 2, L: 16, D: 128,
        bits: bits, groupSize: 64) && dar314Ok
    dar314Ok = runQuantizedBatchKernelCase(
        "case4 growth >256", B: 1, nQ: 4, nKV: 4, L: 300, D: 128,
        bits: bits, groupSize: 64, incremental: true) && dar314Ok
}

print("== QuantizedBatchKVCache storage round-trip (DAR-314) ==")
for bits in [8, 4] {
    dar314Ok = runQuantizedBatchStorageCheck(bits: bits, groupSize: 64) && dar314Ok
}

if dar314Ok {
    print("DAR-314 gate: ALL OK")
} else {
    print("DAR-314 gate: FAILED")
}

// MARK: - DAR-314 follow-up: batched cache paths not covered by the kernel gate

func maskAndAdditiveMask(for cache: QuantizedBatchKVCache, n: Int)
    -> (MLXFast.ScaledDotProductAttentionMaskMode, MLXArray)
{
    // Build the mask against the already-materialized cache (offset 0 so the
    // key length equals the cache length). This matches how we compare
    // post-operation states in the follow-up tests.
    let arr = createCausalMask(
        n: n, offset: 0, windowSize: nil, leftPadding: cache.leftPadding)
    let additive = MLX.where(
        arr, MLXArray(Float(0)), MLXArray(-Float.greatestFiniteMagnitude))
    return (.array(arr), additive)
}

func runFinalizeBatchedCase(_ name: String, bits: Int, groupSize: Int) -> Bool {
    MLXRandom.seed(314159)
    let B = 2, nQ = 4, nKV = 4, D = 128
    let lengths = [3, 5]
    let maxLength = lengths.max()!
    let rightPadding = lengths.map { maxLength - $0 }
    let q = MLXRandom.normal([B, nQ, maxLength, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, maxLength, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, maxLength, D]).asType(.float32)
    for (b, len) in lengths.enumerated() {
        k[b, 0..., len..<maxLength, 0...] = MLXArray(Float(0))
        v[b, 0..., len..<maxLength, 0...] = MLXArray(Float(0))
    }
    let scale = 1.0 / Float(D).squareRoot()

    let qCache = QuantizedBatchKVCache(
        leftPadding: [Int](repeating: 0, count: B),
        groupSize: groupSize, bits: bits, mode: .affine)
    qCache.prepareBatched(
        leftPadding: nil, lengths: lengths, rightPadding: rightPadding)
    _ = qCache.updateQuantized(keys: k, values: v)
    qCache.finalizeBatched()
    guard let (qk, qv) = qCache.getQuantizedState() else {
        print("[FAIL] \(name): empty quantized state after finalize")
        return false
    }

    let fpCache = BatchKVCache(leftPadding: [Int](repeating: 0, count: B))
    fpCache.prepareBatched(
        leftPadding: nil, lengths: lengths, rightPadding: rightPadding)
    _ = fpCache.update(keys: k, values: v)
    fpCache.finalizeBatched()
    let fpK = fpCache.keys![.ellipsis, ..<fpCache.offset, 0...]
    let fpV = fpCache.values![.ellipsis, ..<fpCache.offset, 0...]

    let (maskMode, additiveMask) = maskAndAdditiveMask(for: qCache, n: maxLength)

    let candidate = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: qk, quantizedValues: qv,
        scale: scale, mask: maskMode, groupSize: groupSize,
        bits: bits, mode: .affine)
    let dequantRef = MLXFast.scaledDotProductAttention(
        queries: q,
        keys: dequantTuple(qk, groupSize: groupSize, bits: bits),
        values: dequantTuple(qv, groupSize: groupSize, bits: bits),
        scale: scale, mask: additiveMask)
    let fp16Ref = MLXFast.scaledDotProductAttention(
        queries: q, keys: fpK, values: fpV,
        scale: scale, mask: additiveMask)

    eval(candidate, dequantRef, fp16Ref)

    let qPositions = MLXArray((0..<maxLength).map { Int32($0) }).reshaped([1, 1, maxLength])
    let validQuery = (qPositions .>= qCache.leftPadding.reshaped([B, 1, 1]))
        .reshaped([B, 1, maxLength, 1])
    let candM = MLX.where(validQuery, candidate, MLXArray(Float(0)))
    let deqM = MLX.where(validQuery, dequantRef, MLXArray(Float(0)))
    let fpM = MLX.where(validQuery, fp16Ref, MLXArray(Float(0)))

    let kernelRel = relL2(candM, deqM)
    let layoutRel = relL2(candM, fpM)
    let layoutThreshold: Float = bits == 8 ? 0.02 : 0.20
    let ok = kernelRel < 0.02 && layoutRel < layoutThreshold
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] \(name): kernel_relL2=\(String(format: "%.5f", kernelRel)) layout_relL2=\(String(format: "%.5f", layoutRel))"
    )
    return ok
}

func runExtendBatchedCase(_ name: String, bits: Int, groupSize: Int) -> Bool {
    MLXRandom.seed(271828)
    let nQ = 4, nKV = 4, D = 128, L = 8
    let totalLength = 2 * L
    let scale = 1.0 / Float(D).squareRoot()

    let kSrc = MLXRandom.normal([1, nKV, L, D]).asType(.float32)
    let vSrc = MLXRandom.normal([1, nKV, L, D]).asType(.float32)
    let kStep = MLXRandom.normal([2, nKV, L, D]).asType(.float32)
    let vStep = MLXRandom.normal([2, nKV, L, D]).asType(.float32)

    let srcQ = QuantizedBatchKVCache(
        leftPadding: [0], groupSize: groupSize, bits: bits, mode: .affine)
    _ = srcQ.updateQuantized(keys: kSrc, values: vSrc)

    // Empty destination cache: this exercises the empty-cache branch of extend().
    let dstQ = QuantizedBatchKVCache(
        leftPadding: [0], groupSize: groupSize, bits: bits, mode: .affine)
    dstQ.extendBatched(srcQ)
    let (qk, qv) = dstQ.updateQuantized(keys: kStep, values: vStep)
    let q = MLXRandom.normal([2, nQ, totalLength, D]).asType(.float32)

    let srcFp = BatchKVCache(leftPadding: [0])
    _ = srcFp.update(keys: kSrc, values: vSrc)
    let dstFp = BatchKVCache(leftPadding: [0])
    dstFp.extendBatched(srcFp)
    _ = dstFp.update(keys: kStep, values: vStep)
    let fpK = dstFp.keys![.ellipsis, ..<dstFp.offset, 0...]
    let fpV = dstFp.values![.ellipsis, ..<dstFp.offset, 0...]

    let (maskMode, additiveMask) = maskAndAdditiveMask(for: dstQ, n: totalLength)

    let candidate = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: qk, quantizedValues: qv,
        scale: scale, mask: maskMode, groupSize: groupSize,
        bits: bits, mode: .affine)
    let dequantRef = MLXFast.scaledDotProductAttention(
        queries: q,
        keys: dequantTuple(qk, groupSize: groupSize, bits: bits),
        values: dequantTuple(qv, groupSize: groupSize, bits: bits),
        scale: scale, mask: additiveMask)
    let fp16Ref = MLXFast.scaledDotProductAttention(
        queries: q, keys: fpK, values: fpV,
        scale: scale, mask: additiveMask)

    eval(candidate, dequantRef, fp16Ref)

    // The admitted empty row starts with L positions of padding; mask those
    // query positions out the same way the model skips them.
    let qPositions = MLXArray((0..<totalLength).map { Int32($0) }).reshaped([1, 1, totalLength])
    let validQuery = (qPositions .>= dstQ.leftPadding.reshaped([2, 1, 1]))
        .reshaped([2, 1, totalLength, 1])
    let candM = MLX.where(validQuery, candidate, MLXArray(Float(0)))
    let deqM = MLX.where(validQuery, dequantRef, MLXArray(Float(0)))
    let fpM = MLX.where(validQuery, fp16Ref, MLXArray(Float(0)))

    let kernelRel = relL2(candM, deqM)
    let layoutRel = relL2(candM, fpM)
    let layoutThreshold: Float = bits == 8 ? 0.02 : 0.20
    let ok = kernelRel < 0.02 && layoutRel < layoutThreshold
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] \(name): kernel_relL2=\(String(format: "%.5f", kernelRel)) layout_relL2=\(String(format: "%.5f", layoutRel))"
    )
    return ok
}

func runFilterBatchedCase(_ name: String, bits: Int, groupSize: Int) -> Bool {
    MLXRandom.seed(123456)
    let B = 2, nQ = 4, nKV = 4, L = 16, D = 128
    let scale = 1.0 / Float(D).squareRoot()
    let q = MLXRandom.normal([1, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)

    let qCache = QuantizedBatchKVCache(
        leftPadding: [0, 0], groupSize: groupSize, bits: bits, mode: .affine)
    _ = qCache.updateQuantized(keys: k, values: v)
    qCache.filterBatched(batchIndices: MLXArray([Int32(1)]))
    guard let (qk, qv) = qCache.getQuantizedState() else {
        print("[FAIL] \(name): empty quantized state after filter")
        return false
    }

    let fpCache = BatchKVCache(leftPadding: [0, 0])
    _ = fpCache.update(keys: k, values: v)
    fpCache.filterBatched(batchIndices: MLXArray([Int32(1)]))
    let fpK = fpCache.keys![.ellipsis, ..<fpCache.offset, 0...]
    let fpV = fpCache.values![.ellipsis, ..<fpCache.offset, 0...]

    let (maskMode, additiveMask) = maskAndAdditiveMask(for: qCache, n: L)

    let candidate = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: qk, quantizedValues: qv,
        scale: scale, mask: maskMode, groupSize: groupSize,
        bits: bits, mode: .affine)
    let dequantRef = MLXFast.scaledDotProductAttention(
        queries: q,
        keys: dequantTuple(qk, groupSize: groupSize, bits: bits),
        values: dequantTuple(qv, groupSize: groupSize, bits: bits),
        scale: scale, mask: additiveMask)
    let fp16Ref = MLXFast.scaledDotProductAttention(
        queries: q, keys: fpK, values: fpV,
        scale: scale, mask: additiveMask)

    eval(candidate, dequantRef, fp16Ref)

    let kernelRel = relL2(candidate, dequantRef)
    let layoutRel = relL2(candidate, fp16Ref)
    let layoutThreshold: Float = bits == 8 ? 0.02 : 0.20
    let ok = kernelRel < 0.02 && layoutRel < layoutThreshold
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] \(name): kernel_relL2=\(String(format: "%.5f", kernelRel)) layout_relL2=\(String(format: "%.5f", layoutRel))"
    )
    return ok
}

print("== QuantizedBatchKVCache finalize/extend/filter (DAR-314 follow-up) ==")
var followUpOk = true
for bits in [8, 4] {
    followUpOk = runFinalizeBatchedCase(
        "finalize ragged bits=\(bits)", bits: bits, groupSize: 64) && followUpOk
    followUpOk = runExtendBatchedCase(
        "extend empty bits=\(bits)", bits: bits, groupSize: 64) && followUpOk
    followUpOk = runFilterBatchedCase(
        "filter drop-row bits=\(bits)", bits: bits, groupSize: 64) && followUpOk
}
if followUpOk {
    print("DAR-314 follow-up: ALL OK")
} else {
    print("DAR-314 follow-up: FAILED")
}

// MARK: - DAR-322: DequantBatchKVCache regular-attention path

func runDequantBatchCacheCase(
    _ name: String,
    B: Int, nQ: Int, nKV: Int, L: Int, D: Int
) -> Bool {
    MLXRandom.seed(322)
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()

    let dequantCache = DequantBatchKVCache(
        leftPadding: [Int](repeating: 0, count: B),
        groupSize: 64,
        bits: 8,
        mode: .affine)
    let (dqK, dqV) = dequantCache.update(keys: k, values: v)

    let fpCache = BatchKVCache(leftPadding: [Int](repeating: 0, count: B))
    let (fpK, fpV) = fpCache.update(keys: k, values: v)

    let arr = createCausalMask(
        n: L, offset: 0, windowSize: nil, leftPadding: dequantCache.leftPadding)
    let additive = MLX.where(
        arr, MLXArray(Float(0)), MLXArray(-Float.greatestFiniteMagnitude))

    let candidate = MLXFast.scaledDotProductAttention(
        queries: q, keys: dqK, values: dqV, scale: scale, mask: additive)
    let reference = MLXFast.scaledDotProductAttention(
        queries: q, keys: fpK, values: fpV, scale: scale, mask: additive)

    eval(candidate, reference)

    let diff = relL2(candidate, reference)
    let ok = diff < 0.02
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] \(name): relL2=\(String(format: "%.5f", diff))"
    )
    return ok
}

print("== DequantBatchKVCache regular-attention path (DAR-322) ==")
var dar322Ok = true
dar322Ok = runDequantBatchCacheCase(
    "dequant g64 D=64", B: 1, nQ: 8, nKV: 2, L: 16, D: 64) && dar322Ok

let dequantAsProtocol = DequantBatchKVCache(
    leftPadding: [0], groupSize: 64, bits: 8, mode: .affine
) as? QuantizedKVCacheProtocol
let kernelAsProtocol = QuantizedBatchKVCache(
    leftPadding: [0], groupSize: 64, bits: 8, mode: .affine
) as? QuantizedKVCacheProtocol
print(
    "[\(dequantAsProtocol == nil ? "OK  " : "FAIL")] DequantBatchKVCache does NOT conform to QuantizedKVCacheProtocol"
)
print(
    "[\(kernelAsProtocol != nil ? "OK  " : "FAIL")] QuantizedBatchKVCache conforms to QuantizedKVCacheProtocol"
)
dar322Ok = (dequantAsProtocol == nil) && (kernelAsProtocol != nil) && dar322Ok

if dar322Ok {
    print("DAR-322 gate: ALL OK")
} else {
    print("DAR-322 gate: FAILED")
}
