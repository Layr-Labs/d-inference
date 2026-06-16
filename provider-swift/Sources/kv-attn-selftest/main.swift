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
