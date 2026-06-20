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

@discardableResult
func runCase(
    _ name: String,
    B: Int, nQ: Int, nKV: Int, L: Int, Lk: Int, D: Int,
    bits: Int, groupSize: Int, causal: Bool
) -> Bool {
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
    let ok = (kernelDiff / mag) < 0.02
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] \(name): kernel_vs_dequantRef maxAbs=\(String(format: "%.5f", kernelDiff)) rel=\(String(format: "%.4f", kernelDiff / mag)) | total_vs_fp16 maxAbs=\(String(format: "%.5f", totalDiff)) | meanAbs(ref)=\(String(format: "%.5f", mag))"
    )
    return ok
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
@discardableResult
func runMultiStepCacheTest(_ name: String, bits: Int, groupSize: Int) -> Bool {
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
    let ok = storageDiff < 1e-4
    let verdict = ok ? "OK  " : "FAIL"
    print("[\(verdict)] \(name): storage maxAbs=\(String(format: "%.6f", storageDiff)) | decode-attn vs fp16 maxAbs=\(String(format: "%.5f", attnDiff)) rel=\(String(format: "%.4f", attnDiff / mag))")
    return ok
}

// Folds the early kernel-correctness + multi-step-cache probes into the overall
// exit status (they previously printed [FAIL] but could not fail the binary).
var selfTestOk = true

print("== quantizedScaledDotProductAttention numerical self-test ==")
for bits in [8, 4] {
    print("-- bits=\(bits), groupSize=64 --")
    selfTestOk = runCase("MHA  no-mask ", B: 1, nQ: 4, nKV: 4, L: 16, Lk: 16, D: 128, bits: bits, groupSize: 64, causal: false) && selfTestOk
    selfTestOk = runCase("MHA  causal  ", B: 1, nQ: 4, nKV: 4, L: 16, Lk: 16, D: 128, bits: bits, groupSize: 64, causal: true) && selfTestOk
    selfTestOk = runCase("GQA  no-mask ", B: 1, nQ: 8, nKV: 2, L: 16, Lk: 16, D: 128, bits: bits, groupSize: 64, causal: false) && selfTestOk
    selfTestOk = runCase("GQA  causal  ", B: 1, nQ: 8, nKV: 2, L: 16, Lk: 16, D: 128, bits: bits, groupSize: 64, causal: true) && selfTestOk
    selfTestOk = runCase("GQA  decode  ", B: 1, nQ: 8, nKV: 2, L: 1, Lk: 16, D: 128, bits: bits, groupSize: 64, causal: false) && selfTestOk
}

print("== outlier quantization loss (causal, g32) ==")
for bits in [8, 4] {
    runOutlierCase("outlier x1   bits=\(bits)", bits: bits, groupSize: 32, scaleOutlier: 1)
    runOutlierCase("outlier x20  bits=\(bits)", bits: bits, groupSize: 32, scaleOutlier: 20)
    runOutlierCase("outlier x100 bits=\(bits)", bits: bits, groupSize: 32, scaleOutlier: 100)
}

print("== multi-step QuantizedKVCache (decode, crosses step=256) ==")
for bits in [8, 4] {
    selfTestOk = runMultiStepCacheTest("multistep bits=\(bits) g64", bits: bits, groupSize: 64) && selfTestOk
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

// MARK: - QuantizedBatchKVCache kernel + storage gate

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

func runKernelAdditiveArrayMaskCase(_ name: String, bits: Int, groupSize: Int) -> Bool {
    MLXRandom.seed(31416)
    let B = 4, nQ = 8, nKV = 2, L = 32, D = groupSize
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()
    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let (vwq, vs, vb) = quantized(v, groupSize: groupSize, bits: bits)
    let additiveMask = buildCausalAdditiveMask(L: L, Lk: L).reshaped([1, 1, L, L])
        + zeros([B, 1, 1, 1]).asType(.float32)

    let candidate = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: (kwq, ks, kb), quantizedValues: (vwq, vs, vb),
        scale: scale, mask: .array(additiveMask), groupSize: groupSize, bits: bits, mode: .affine)
    let dequantRef = MLXFast.scaledDotProductAttention(
        queries: q,
        keys: dequantized(kwq, scales: ks, biases: kb, groupSize: groupSize, bits: bits),
        values: dequantized(vwq, scales: vs, biases: vb, groupSize: groupSize, bits: bits),
        scale: scale, mask: additiveMask)
    let fp16Ref = MLXFast.scaledDotProductAttention(
        queries: q, keys: k, values: v, scale: scale, mask: additiveMask)
    eval(candidate, dequantRef, fp16Ref)
    let kernelRel = relL2(candidate, dequantRef)
    let quantLossRel = relL2(candidate, fp16Ref)
    let ok = kernelRel < 0.02
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] \(name): kernel_relL2=\(String(format: "%.5f", kernelRel)) quant_loss_relL2=\(String(format: "%.5f", quantLossRel))"
    )
    return ok
}

func runKernelFullyMaskedNoSinkCase(_ name: String, bits: Int, groupSize: Int) -> Bool {
    MLXRandom.seed(31417)
    let B = 2, nQ = 8, nKV = 2, L = 16, D = groupSize
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()
    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let (vwq, vs, vb) = quantized(v, groupSize: groupSize, bits: bits)

    var maskValues: [Int32] = []
    maskValues.reserveCapacity(B * L * L)
    for b in 0..<B {
        for qPos in 0..<L {
            for kPos in 0..<L {
                let allowed = !(b == 0 && qPos == 0) && kPos <= qPos
                maskValues.append(allowed ? 1 : 0)
            }
        }
    }
    let boolMask = MLXArray(maskValues).reshaped([B, 1, L, L]) .== MLXArray(Int32(1))
    let additiveMask = MLX.where(
        boolMask, MLXArray(Float(0)), MLXArray(-Float.greatestFiniteMagnitude))
    let candidate = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: (kwq, ks, kb), quantizedValues: (vwq, vs, vb),
        scale: scale, mask: .array(boolMask), groupSize: groupSize, bits: bits, mode: .affine)
    let dequantRef = MLXFast.scaledDotProductAttention(
        queries: q,
        keys: dequantized(kwq, scales: ks, biases: kb, groupSize: groupSize, bits: bits),
        values: dequantized(vwq, scales: vs, biases: vb, groupSize: groupSize, bits: bits),
        scale: scale, mask: additiveMask)
    eval(candidate, dequantRef)
    var validRows: [Int32] = []
    validRows.reserveCapacity(B * L)
    for b in 0..<B {
        for qPos in 0..<L {
            validRows.append((b == 0 && qPos == 0) ? 0 : 1)
        }
    }
    let valid = (MLXArray(validRows).reshaped([B, 1, L, 1]) .== MLXArray(Int32(1)))
    let candidateValid = MLX.where(valid, candidate, MLXArray(Float(0)))
    let dequantValid = MLX.where(valid, dequantRef, MLXArray(Float(0)))
    let rel = relL2(candidateValid, dequantValid)
    let maskedAbs = abs(candidate[0..<1, 0..., 0..<1, 0...]).max().item(Float.self)
    let ok = rel < 0.02 && maskedAbs < 1e-6
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] \(name): valid_rows_relL2=\(String(format: "%.5f", rel)) fully_masked_abs=\(String(format: "%.6f", maskedAbs))"
    )
    return ok
}

print("== QuantizedBatchKVCache kernel correctness ==")
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
    // B>1 GQA with an array mask: the concurrency path. The 5D GQA score tensor
    // must accept a [B,1,L,kL] mask — this crashed before the 4D-collapse fix.
    dar314Ok = runQuantizedBatchKernelCase(
        "case5 batched GQA B=4", B: 4, nQ: 8, nKV: 2, L: 32, D: 64,
        bits: bits, groupSize: 64) && dar314Ok
}

// Live Gemma scheme: K8V8 g128 kernel. Keep this outside the 4-bit loop so the
// production K/V path is proven directly and kernel error is reported separately
// from quantization loss.
dar314Ok = runQuantizedBatchKernelCase(
    "live Gemma k8v8:g128 B=4 GQA bool-array", B: 4, nQ: 8, nKV: 2, L: 32, D: 128,
    bits: 8, groupSize: 128) && dar314Ok
dar314Ok = runKernelAdditiveArrayMaskCase(
    "live Gemma k8v8:g128 B=4 GQA additive-array", bits: 8, groupSize: 128) && dar314Ok
dar314Ok = runKernelFullyMaskedNoSinkCase(
    "live Gemma k8v8:g128 fully-masked no-sink", bits: 8, groupSize: 128) && dar314Ok

print("== QuantizedBatchKVCache storage round-trip ==")
for bits in [8, 4] {
    dar314Ok = runQuantizedBatchStorageCheck(bits: bits, groupSize: 64) && dar314Ok
}

// Live Gemma cache mutation parameters (K8V8 g128). These exercise the same
// continuously-batched quantized cache family the engine selects for Gemma.
// They fold into the kernel+storage gate below (not the later g64 follow-up, whose
// `followUpOk` is declared further down and would otherwise discard these).
dar314Ok = runFinalizeBatchedCase(
    "finalize ragged live g128", bits: 8, groupSize: 128) && dar314Ok
dar314Ok = runExtendBatchedCase(
    "extend empty live g128", bits: 8, groupSize: 128) && dar314Ok
dar314Ok = runFilterBatchedCase(
    "filter drop-row live g128", bits: 8, groupSize: 128) && dar314Ok

if dar314Ok {
    print("kernel+storage gate: ALL OK")
} else {
    print("kernel+storage gate: FAILED")
}

// MARK: - batched-cache follow-up: batched cache paths not covered by the kernel gate

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

print("== QuantizedBatchKVCache finalize/extend/filter ==")
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
    print("batched-cache follow-up: ALL OK")
} else {
    print("batched-cache follow-up: FAILED")
}

// MARK: - DequantBatchKVCache regular-attention path

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

func runLiveGPTOSSDequantCase() -> Bool {
    MLXRandom.seed(32364)
    let B = 4, nQ = 8, nKV = 2, L = 32, D = 64
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let sinks = MLXRandom.normal([nQ]).asType(.float32) * 2.0
    let scale = 1.0 / Float(D).squareRoot()
    let groupSize = 64
    let bits = 8

    let cache = DequantBatchKVCache(
        leftPadding: [Int](repeating: 0, count: B),
        groupSize: groupSize, bits: bits, mode: .affine)
    let (dqK, dqV) = cache.update(keys: k, values: v)

    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let (vwq, vs, vb) = quantized(v, groupSize: groupSize, bits: bits)
    let directDQK = dequantized(kwq, scales: ks, biases: kb, groupSize: groupSize, bits: bits)
    let directDQV = dequantized(vwq, scales: vs, biases: vb, groupSize: groupSize, bits: bits)
    let cacheKRel = relL2(dqK, directDQK)
    let cacheVRel = relL2(dqV, directDQV)

    let boolMask = materializedCausalBoolMask(B: B, L: L)
    let additiveMask = MLX.where(
        boolMask, MLXArray(Float(0)), MLXArray(-Float.greatestFiniteMagnitude))
    let candidate = MLXFast.scaledDotProductAttention(
        queries: q, keys: dqK, values: dqV, scale: scale, mask: additiveMask, sinks: sinks)
    let directDequantRef = MLXFast.scaledDotProductAttention(
        queries: q, keys: directDQK, values: directDQV, scale: scale, mask: additiveMask, sinks: sinks)
    let fp16Ref = MLXFast.scaledDotProductAttention(
        queries: q, keys: k, values: v, scale: scale, mask: additiveMask, sinks: sinks)
    eval(candidate, directDequantRef, fp16Ref)

    let implRel = relL2(candidate, directDequantRef)
    let quantLossRel = relL2(directDequantRef, fp16Ref)
    let ok = max(cacheKRel, cacheVRel) < 1e-6 && implRel < 1e-6 && quantLossRel < 0.02
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] live GPT-OSS k8v8:g64:dequant B=4 GQA+sinks: cache_K_rel=\(String(format: "%.6f", cacheKRel)) cache_V_rel=\(String(format: "%.6f", cacheVRel)) impl_rel=\(String(format: "%.6f", implRel)) quant_loss_rel=\(String(format: "%.5f", quantLossRel))"
    )
    return ok
}

print("== DequantBatchKVCache regular-attention path ==")
var dar322Ok = true
dar322Ok = runDequantBatchCacheCase(
    "dequant g64 D=64", B: 1, nQ: 8, nKV: 2, L: 16, D: 64) && dar322Ok
dar322Ok = runLiveGPTOSSDequantCase() && dar322Ok

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
    print("dequant-attention gate: ALL OK")
} else {
    print("dequant-attention gate: FAILED")
}

// MARK: - sink-aware quantized attention (GPT-OSS kernel path)
//
// First-principles isolation for attention sinks. An attention sink is a learned
// per-(query)head logit that joins the softmax denominator as a valueless virtual
// key. We prove the quantized kernel handles it by comparing against MLX's own
// `scaledDotProductAttention(..., sinks:)` fed the SAME dequantized K/V and the
// SAME sinks — any large gap is a kernel/GQA/convention bug, not quant loss.
// D=64 mirrors GPT-OSS's head_dim (group must be <= 64).

func runSinkCase(
    _ name: String,
    B: Int, nQ: Int, nKV: Int, L: Int, Lk: Int, D: Int,
    bits: Int, groupSize: Int, causal: Bool
) -> Bool {
    MLXRandom.seed(2024)
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, Lk, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, Lk, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()
    // Nonzero, distinct per-head sink logits (range similar to trained sinks).
    let sinks = MLXRandom.normal([nQ]).asType(.float32) * 2.0

    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let (vwq, vs, vb) = quantized(v, groupSize: groupSize, bits: bits)
    let kdq = dequantized(kwq, scales: ks, biases: kb, groupSize: groupSize, bits: bits)
    let vdq = dequantized(vwq, scales: vs, biases: vb, groupSize: groupSize, bits: bits)

    let additiveMask: MLXArray? = causal ? buildCausalAdditiveMask(L: L, Lk: Lk) : nil
    let maskMode: MLXFast.ScaledDotProductAttentionMaskMode = causal ? .causal : .none

    let dequantRef = MLXFast.scaledDotProductAttention(
        queries: q, keys: kdq, values: vdq, scale: scale, mask: additiveMask, sinks: sinks)
    let fp16Ref = MLXFast.scaledDotProductAttention(
        queries: q, keys: k, values: v, scale: scale, mask: additiveMask, sinks: sinks)
    let candidate = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: (kwq, ks, kb), quantizedValues: (vwq, vs, vb),
        scale: scale, mask: maskMode, groupSize: groupSize, bits: bits, mode: .affine,
        sinks: sinks)

    eval(dequantRef, fp16Ref, candidate)
    let kernelRel = relL2(candidate, dequantRef)
    let totalRel = relL2(candidate, fp16Ref)
    let ok = kernelRel < 0.02
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] \(name) bits=\(bits): kernel_vs_MLXsinks relL2=\(String(format: "%.5f", kernelRel)) | total_vs_fp16 relL2=\(String(format: "%.5f", totalRel))"
    )
    return ok
}

// Encodes the corrected sink semantics:
//   (a) sinks: nil  == legacy no-sink kernel (the sink -> -inf limit), bit-exact.
//   (b) sinks: 0    is a REAL sink (adds exp(0-m) to the denominator), so it must
//       DIFFER from nil, and must match MLX SDPA fed an explicit zero-sinks array.
func runSinkSemanticsCase(bits: Int, groupSize: Int) -> Bool {
    MLXRandom.seed(4242)
    let B = 1, nQ = 8, nKV = 2, L = 16, D = 64
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()
    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let (vwq, vs, vb) = quantized(v, groupSize: groupSize, bits: bits)

    func cand(_ sinks: MLXArray?) -> MLXArray {
        quantizedScaledDotProductAttention(
            queries: q, quantizedKeys: (kwq, ks, kb), quantizedValues: (vwq, vs, vb),
            scale: scale, mask: .causal, groupSize: groupSize, bits: bits, mode: .affine,
            sinks: sinks)
    }
    let zeroSinks = (MLXRandom.normal([nQ]) * 0).asType(.float32)
    let nilOut = cand(nil)
    let zeroOut = cand(zeroSinks)
    // Legacy path == calling with the default (no sinks argument at all).
    let legacy = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: (kwq, ks, kb), quantizedValues: (vwq, vs, vb),
        scale: scale, mask: .causal, groupSize: groupSize, bits: bits, mode: .affine)
    let kdq = dequantized(kwq, scales: ks, biases: kb, groupSize: groupSize, bits: bits)
    let vdq = dequantized(vwq, scales: vs, biases: vb, groupSize: groupSize, bits: bits)
    let mask = buildCausalAdditiveMask(L: L, Lk: L)
    let mlxZero = MLXFast.scaledDotProductAttention(
        queries: q, keys: kdq, values: vdq, scale: scale, mask: mask, sinks: zeroSinks)

    eval(nilOut, zeroOut, legacy, mlxZero)
    let nilRel = relL2(nilOut, legacy)         // (a) must be ~0
    let zeroVsNil = relL2(zeroOut, nilOut)     // (b) must be > 0
    let zeroMatch = relL2(zeroOut, mlxZero)    // (b) must be ~quant tolerance

    let ok = nilRel < 1e-6 && zeroVsNil > 1e-3 && zeroMatch < 0.02
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] sink-semantics bits=\(bits): nil==legacy relL2=\(String(format: "%.6f", nilRel)) | zero!=nil relL2=\(String(format: "%.5f", zeroVsNil)) (>0) | zero==MLX(zero) relL2=\(String(format: "%.5f", zeroMatch))"
    )
    return ok
}

// The concurrency crash scenario: B>1, GQA, an explicit [B,1,L,kL] additive
// array mask (as the batched engine passes), and nonzero sinks. Compared against
// MLX SDPA with the same sinks on the dequantized K/V.
func runSinkBatchedArrayMaskCase(bits: Int, groupSize: Int) -> Bool {
    MLXRandom.seed(2025)
    let B = 4, nQ = 8, nKV = 2, L = 32, D = 64
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()
    let sinks = MLXRandom.normal([nQ]).asType(.float32) * 2.0

    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let (vwq, vs, vb) = quantized(v, groupSize: groupSize, bits: bits)
    let kdq = dequantized(kwq, scales: ks, biases: kb, groupSize: groupSize, bits: bits)
    let vdq = dequantized(vwq, scales: vs, biases: vb, groupSize: groupSize, bits: bits)

    // Materialize a real [B, 1, L, kL] additive mask (not a leading-1 broadcast).
    let mask4 = buildCausalAdditiveMask(L: L, Lk: L).reshaped([1, 1, L, L])
        + zeros([B, 1, 1, 1]).asType(.float32)

    let candidate = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: (kwq, ks, kb), quantizedValues: (vwq, vs, vb),
        scale: scale, mask: .array(mask4), groupSize: groupSize, bits: bits, mode: .affine,
        sinks: sinks)
    let dequantRef = MLXFast.scaledDotProductAttention(
        queries: q, keys: kdq, values: vdq, scale: scale, mask: mask4, sinks: sinks)
    eval(candidate, dequantRef)
    let rel = relL2(candidate, dequantRef)
    let ok = rel < 0.02
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] batched GQA array-mask+sinks B=\(B) bits=\(bits): kernel_vs_MLXsinks relL2=\(String(format: "%.5f", rel))"
    )
    return ok
}

func materializedCausalBoolMask(B: Int, L: Int) -> MLXArray {
    var values: [Int32] = []
    values.reserveCapacity(B * L * L)
    for _ in 0..<B {
        for q in 0..<L {
            for k in 0..<L {
                values.append(k <= q ? 1 : 0)
            }
        }
    }
    return MLXArray(values).reshaped([B, 1, L, L]) .== MLXArray(Int32(1))
}

// Same B>1/GQA/sinks shape, but exercises the `.arrays` mask case with a real
// materialized boolean [B,1,L,kL] mask. The implementation intentionally consumes
// only the first mask array today; this locks that behavior to MLX SDPA's result
// for the same first mask.
func runSinkBatchedArraysBoolMaskCase(bits: Int, groupSize: Int) -> Bool {
    MLXRandom.seed(2026)
    let B = 3, nQ = 8, nKV = 2, L = 24, D = 64
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()
    let sinks = MLXRandom.normal([nQ]).asType(.float32) * 2.0

    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let (vwq, vs, vb) = quantized(v, groupSize: groupSize, bits: bits)
    let kdq = dequantized(kwq, scales: ks, biases: kb, groupSize: groupSize, bits: bits)
    let vdq = dequantized(vwq, scales: vs, biases: vb, groupSize: groupSize, bits: bits)
    let boolMask = materializedCausalBoolMask(B: B, L: L)
    let additiveMask = MLX.where(
        boolMask, MLXArray(Float(0)), MLXArray(-Float.greatestFiniteMagnitude))

    let candidate = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: (kwq, ks, kb), quantizedValues: (vwq, vs, vb),
        scale: scale, mask: .arrays([boolMask]), groupSize: groupSize, bits: bits,
        mode: .affine, sinks: sinks)
    let dequantRef = MLXFast.scaledDotProductAttention(
        queries: q, keys: kdq, values: vdq, scale: scale, mask: additiveMask, sinks: sinks)
    eval(candidate, dequantRef)
    let rel = relL2(candidate, dequantRef)
    let ok = rel < 0.02
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] batched GQA arrays-bool-mask+sinks B=\(B) bits=\(bits): kernel_vs_MLXsinks relL2=\(String(format: "%.5f", rel))"
    )
    return ok
}

// Fully masked rows must not turn into uniform attention over masked tokens when
// sinks are active. The sink logit absorbs all probability mass, so the returned
// value row should match MLX SDPA and remain finite.
func runSinkFullyMaskedRowCase(bits: Int, groupSize: Int) -> Bool {
    MLXRandom.seed(2027)
    let B = 2, nQ = 8, nKV = 2, L = 16, D = 64
    let q = MLXRandom.normal([B, nQ, L, D]).asType(.float32)
    let k = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let v = MLXRandom.normal([B, nKV, L, D]).asType(.float32)
    let scale = 1.0 / Float(D).squareRoot()
    let sinks = MLXRandom.normal([nQ]).asType(.float32) * 2.0

    let (kwq, ks, kb) = quantized(k, groupSize: groupSize, bits: bits)
    let (vwq, vs, vb) = quantized(v, groupSize: groupSize, bits: bits)
    let kdq = dequantized(kwq, scales: ks, biases: kb, groupSize: groupSize, bits: bits)
    let vdq = dequantized(vwq, scales: vs, biases: vb, groupSize: groupSize, bits: bits)

    var maskValues: [Int32] = []
    maskValues.reserveCapacity(B * L * L)
    for b in 0..<B {
        for qPos in 0..<L {
            for kPos in 0..<L {
                let allowed = !(b == 0 && qPos == 0) && kPos <= qPos
                maskValues.append(allowed ? 1 : 0)
            }
        }
    }
    let boolMask = MLXArray(maskValues).reshaped([B, 1, L, L]) .== MLXArray(Int32(1))
    let additiveMask = MLX.where(
        boolMask, MLXArray(Float(0)), MLXArray(-Float.greatestFiniteMagnitude))

    let candidate = quantizedScaledDotProductAttention(
        queries: q, quantizedKeys: (kwq, ks, kb), quantizedValues: (vwq, vs, vb),
        scale: scale, mask: .array(boolMask), groupSize: groupSize, bits: bits,
        mode: .affine, sinks: sinks)
    let dequantRef = MLXFast.scaledDotProductAttention(
        queries: q, keys: kdq, values: vdq, scale: scale, mask: additiveMask, sinks: sinks)
    eval(candidate, dequantRef)
    let rel = relL2(candidate, dequantRef)
    let ok = rel < 0.02
    let verdict = ok ? "OK  " : "FAIL"
    print(
        "[\(verdict)] fully-masked-row+sinks bits=\(bits): kernel_vs_MLXsinks relL2=\(String(format: "%.5f", rel))"
    )
    return ok
}

print("== sink-aware quantized attention ==")
var dar323Ok = true
for bits in [8, 4] {
    dar323Ok = runSinkCase(
        "GQA  causal D=64 ", B: 1, nQ: 8, nKV: 2, L: 16, Lk: 16, D: 64,
        bits: bits, groupSize: 64, causal: true) && dar323Ok
    dar323Ok = runSinkBatchedArrayMaskCase(bits: bits, groupSize: 64) && dar323Ok
    dar323Ok = runSinkBatchedArraysBoolMaskCase(bits: bits, groupSize: 64) && dar323Ok
    dar323Ok = runSinkFullyMaskedRowCase(bits: bits, groupSize: 64) && dar323Ok
    dar323Ok = runSinkCase(
        "GQA  causal D=128", B: 1, nQ: 8, nKV: 2, L: 16, Lk: 16, D: 128,
        bits: bits, groupSize: 64, causal: true) && dar323Ok
    dar323Ok = runSinkCase(
        "MHA  causal D=64 ", B: 1, nQ: 4, nKV: 4, L: 16, Lk: 16, D: 64,
        bits: bits, groupSize: 64, causal: true) && dar323Ok
    dar323Ok = runSinkCase(
        "GQA  decode D=64 ", B: 1, nQ: 8, nKV: 2, L: 1, Lk: 16, D: 64,
        bits: bits, groupSize: 64, causal: false) && dar323Ok
    dar323Ok = runSinkSemanticsCase(bits: bits, groupSize: 64) && dar323Ok
}
if dar323Ok {
    print("sink-attention gate: ALL OK")
} else {
    print("sink-attention gate: FAILED")
}

// MARK: - Overall exit status
//
// Each DAR gate prints its own "ALL OK"/"FAILED" summary above, but as a
// top-level executable, falling off the end of the file always exits 0 — so CI
// would treat a failing correctness gate as success. Combine every gate result
// and exit nonzero if any gate failed.
let allOK = selfTestOk && dar314Ok && followUpOk && dar322Ok && dar323Ok
print("== self-test summary: \(allOK ? "ALL GATES OK" : "ONE OR MORE GATES FAILED") ==")
exit(allOK ? 0 : 1)
