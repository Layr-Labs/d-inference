import Foundation
import MLX
import MLXLMCommon

/// Deterministic, model-free probes that validate cache mechanics used by the
/// gate's scorers — so we verify the mechanism cheaply instead of inferring it
/// from expensive 26B runs.
public enum KVQuantCacheProbe {
    private static func maxAbsDiff(_ a: MLXArray, _ b: MLXArray) -> Float {
        abs(a - b).max().item(Float.self)
    }

    /// Validates the core reason the PPL/logits scorer had to switch to
    /// incremental decoding:
    ///   - A START-DELAYED cache (VOnly start>seq) returns fp16 on a single
    ///     one-shot update (quantization never engages) → diff ≈ 0.
    ///   - The SAME cache fed token-by-token DOES quantize past the start token
    ///     → diff > 0.
    /// If single-forward and incremental did NOT diverge, the scorer fix would be
    /// pointless; this asserts they do.
    public static func run() -> String {
        var lines: [String] = []
        let B = 1, H = 2, L = 8, D = 64
        let start = 4

        let kFull = MLXArray.ones([B, H, L, D]).asType(.float16)
        // Values with structure so quantization is observable.
        let vFull = (MLXArray(0..<(B * H * L * D)).reshaped([B, H, L, D]).asType(.float16)) / MLXArray(Float16(7))

        // One-shot: single update with all L tokens.
        let oneShot = VOnlyQuantizedKVCache(groupSize: 64, bits: 4, startToken: start, mode: .affine)
        let (_, vOneShot) = oneShot.update(keys: kFull, values: vFull)
        eval(vOneShot)
        let oneShotDiff = maxAbsDiff(vOneShot, vFull)

        // Incremental: feed one token at a time through a fresh cache.
        let incremental = VOnlyQuantizedKVCache(groupSize: 64, bits: 4, startToken: start, mode: .affine)
        var lastV = vFull
        for t in 0..<L {
            let kt = kFull[0..., 0..., t..<(t + 1), 0...]
            let vt = vFull[0..., 0..., t..<(t + 1), 0...]
            (_, lastV) = incremental.update(keys: kt, values: vt)
        }
        eval(lastV)
        let incDiff = maxAbsDiff(lastV, vFull)

        lines.append("VOnly start=\(start) seq=\(L): one-shot diff=\(String(format: "%.5f", oneShotDiff)) (expect ~0, fp16) | incremental diff=\(String(format: "%.5f", incDiff)) (expect >0, quantized)")
        let mechanismOK = oneShotDiff < 1e-4 && incDiff > 1e-3
        lines.append(mechanismOK
            ? "[OK] single-forward hides start-delayed quantization; incremental exposes it → scorer fix is necessary and effective."
            : "[WARN] mechanism not as expected (oneShot=\(oneShotDiff), inc=\(incDiff)).")

        // ProtocolSafe quantizes from token 0, so even one-shot shows quantization.
        let ps = ProtocolSafeQuantizedKVCache(groupSize: 64, bits: 8, mode: .affine)
        let (_, vPS) = ps.update(keys: kFull, values: vFull)
        eval(vPS)
        lines.append("ProtocolSafe start=0 one-shot diff=\(String(format: "%.5f", maxAbsDiff(vPS, vFull))) (expect >0, quantized from token 0)")

        return lines.joined(separator: "\n")
    }
}
