// Copyright © 2026 Eigen Labs.
//
// P1 INVESTIGATION PROBE (temporary, operator-run), part 2: is the paged
// decode kernel LESS ACCURATE than the contiguous path, or merely DIFFERENT?
//
// The model-level probe (PagedDivergenceProbeTests) establishes that gemma-4's
// paged PREFILL is bit-identical to contiguous and its first DECODE step is
// not. That leaves two readings of the same observation:
//
//   DRIFT — both backends are equally-valid low-precision evaluations of the
//           same function, disagreeing at the ULP level, and 30 layers of
//           top-8-of-128 MoE routing turn that into a visible logit shift.
//   BUG   — the paged kernel computes something materially wrong.
//
// The existing differential oracle (CBv2PagedKernelTests) cannot tell these
// apart: it compares the two backends to each other at rtol 1e-2, which a 0.9%
// systematic error passes.
//
// This probe adds the missing third point — an fp32 reference over the SAME
// stored values — and asks which arm is closer to it. Both arms store the same
// numbers (bf16 -> fp16 and bf16 -> fp32 are exact for gemma-4's measured
// |K| <= 1.66, |V| <= 16.9), so the reference is the exact answer both are
// approximating and "closer to the reference" is a meaningful ranking.
//
// No model weights. Run with:
//   DARKBLOOM_PAGED_DIVERGENCE_PROBE=1 \
//     swift test --filter PagedDecodeAccuracyProbeTests

import Foundation
import MLX
import MLXLMCommon
import MLXRandom
import Testing

@testable import ProviderCore

@Suite("paged decode accuracy probe", .serialized)
struct PagedDecodeAccuracyProbeTests {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["DARKBLOOM_PAGED_DIVERGENCE_PROBE"] != nil
    }

    private struct Shape {
        let name: String
        let headDim: Int
        let kvHeads: Int
        let queryHeads: Int
        let window: Int?
        /// gemma-4 uses 1.0 (the scale is folded into the learned q_norm);
        /// gpt-oss uses 1/sqrt(headDim).
        let scale: Float
    }

    private static let shapes: [Shape] = [
        Shape(
            name: "gemma4 sliding", headDim: 256, kvHeads: 8, queryHeads: 16, window: 1024,
            scale: 1.0),
        Shape(
            name: "gemma4 full   ", headDim: 512, kvHeads: 2, queryHeads: 16, window: nil,
            scale: 1.0),
        Shape(
            name: "gptoss sliding", headDim: 64, kvHeads: 8, queryHeads: 64, window: 128,
            scale: 1.0 / 8.0),
        Shape(
            name: "gptoss full   ", headDim: 64, kvHeads: 8, queryHeads: 64, window: nil,
            scale: 1.0 / 8.0),
        // Same tensors as gemma4 sliding, only the scale changes: isolates how
        // much of gemma-4's error is the missing 1/sqrt(d).
        Shape(
            name: "gemma4 sl @1/√d", headDim: 256, kvHeads: 8, queryHeads: 16, window: 1024,
            scale: 1.0 / 16.0),
    ]

    private func relativeError(_ got: MLXArray, _ want: MLXArray) -> (rel: Float, abs: Float) {
        let g = got.asType(.float32)
        let w = want.asType(.float32)
        let absErr = MLX.max(MLX.abs(g - w)).item(Float.self)
        let denom = max(MLX.max(MLX.abs(w)).item(Float.self), 1e-20)
        return (absErr / denom, absErr)
    }

    @Test("decode attention error vs an fp32 reference, per backend")
    func decodeAccuracy() throws {
        guard Self.enabled else { return }
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        MLXRandom.seed(0x5EED_1234)

        print(
            "[acc] shape            H     relErr(paged)  relErr(contig)  relErr(p vs c)"
                + "   ratio p/c   PLANTED-BUG")
        for shape in Self.shapes {
            let kind = CBv2LayerKind(
                attention: shape.window.map { .slidingWindow($0) } ?? .full,
                hasSinks: false,
                headDim: shape.headDim, kvHeads: shape.kvHeads, queryHeads: shape.queryHeads)

            for history in [5, 33, 200] {
                // bf16 inputs at the magnitudes measured on real gemma-4
                // weights (max|K| ~ 1.7, max|V| ~ 17), so the conditioning of
                // the softmax matches production rather than a unit-variance
                // fixture.
                let qAll = (MLXRandom.normal([1, shape.queryHeads, history + 1, shape.headDim]))
                    .asType(.bfloat16)
                let kAll = (MLXRandom.normal([1, shape.kvHeads, history + 1, shape.headDim]) * 0.55)
                    .asType(.bfloat16)
                let vAll = (MLXRandom.normal([1, shape.kvHeads, history + 1, shape.headDim]) * 5.5)
                    .asType(.bfloat16)
                eval(qAll, kAll, vAll)

                let prompt = 0 ..< history
                let step = history ..< (history + 1)

                func run(paged: Bool) throws -> MLXArray {
                    let cache: any CBv2AttendingLayerCache
                    let rows: [CBv2SequenceKV?]
                    let backendRelease: () -> Void
                    if paged {
                        let backend = try PagedKVBackend(
                            layerKinds: [kind],
                            config: PagedKVPoolConfig(
                                capacityBytes: 256 * 1024 * 1024,
                                dtype: .float16,
                                maxPrefillChunk: 512,
                                nominalMaxSequenceLength: 1024))
                        rows = try backend.makeSequenceState(
                            layerKinds: [kind], promptLength: history,
                            maxLength: history + 2)
                        cache = backend.makeLayerCaches()[0]
                        backendRelease = { backend.release(rows) }
                    } else {
                        let backend = CBv2ContiguousKVBackend(
                            config: CBv2ContiguousBackendConfig(bytesCapacity: 256 * 1024 * 1024))
                        rows = try backend.makeSequenceState(
                            layerKinds: [kind], promptLength: history,
                            maxLength: history + 2)
                        cache = CBv2LayerCache(layerIndex: 0, kind: kind, attentionSoftcap: nil)
                        backendRelease = { backend.release(rows) }
                    }
                    defer { backendRelease() }
                    cache.setRows(rows.compactMap { $0 })
                    _ = cache.updateAndAttend(
                        queries: qAll[0..., 0..., prompt, 0...],
                        keys: kAll[0..., 0..., prompt, 0...],
                        values: vAll[0..., 0..., prompt, 0...],
                        scale: shape.scale, sinks: nil)
                    let decode = cache.updateAndAttend(
                        queries: qAll[0..., 0..., step, 0...],
                        keys: kAll[0..., 0..., step, 0...],
                        values: vAll[0..., 0..., step, 0...],
                        scale: shape.scale, sinks: nil)
                    eval(decode)
                    return decode
                }

                let pagedOut = try run(paged: true)
                let contigOut = try run(paged: false)

                // fp32 reference over the SAME values. The decode query sees
                // the whole history here (history + 1 <= window for every case
                // above), so no mask is needed.
                let reference = PagedAttentionReference.composedAttention(
                    queries: qAll[0..., 0..., step, 0...].asType(.float32),
                    keys: kAll.asType(.float32),
                    values: vAll.asType(.float32),
                    scale: shape.scale, boolMask: nil, sinks: nil, softcap: nil)
                eval(reference)

                // CALIBRATION: what does the SMALLEST realistic correctness
                // bug look like in these same units? A window off-by-one, an
                // evicted page, or a mis-resolved page table all present as
                // "the query attended the wrong key set". The mildest such
                // failure is losing exactly ONE key at the oldest end, so
                // that is the planted bug. A gate whose threshold does not
                // sit between the honest disagreement and this number is not
                // a gate.
                let planted = PagedAttentionReference.composedAttention(
                    queries: qAll[0..., 0..., step, 0...].asType(.float32),
                    keys: kAll[0..., 0..., 1..., 0...].asType(.float32),
                    values: vAll[0..., 0..., 1..., 0...].asType(.float32),
                    scale: shape.scale, boolMask: nil, sinks: nil, softcap: nil)
                eval(planted)

                let p = relativeError(pagedOut, reference)
                let c = relativeError(contigOut, reference)
                let pc = relativeError(pagedOut, contigOut)
                let bug = relativeError(planted, reference)
                print(
                    String(
                        format:
                            "[acc] %@  %4d   %12.3e   %12.3e   %12.3e   %7.2fx   %12.3e",
                        shape.name, history, p.rel, c.rel, pc.rel,
                        c.rel > 0 ? p.rel / c.rel : Float.nan, bug.rel))
                MLX.Memory.clearCache()
            }
        }
    }

    /// How large is the softmax's pre-exponential input on each shape?
    ///
    /// gemma-4 runs scale 1.0 at head_dim 256/512, so the QK logits are
    /// O(head_dim) rather than O(1). This is the conditioning term: the same
    /// input ULP produces a `d`-times larger swing in the exponent, and the
    /// online-softmax rescaling in the paged kernel and the batched softmax in
    /// MLX SDPA do not round it the same way.
    @Test("QK logit magnitude per shape (the conditioning term)")
    func qkConditioning() throws {
        guard Self.enabled else { return }
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        MLXRandom.seed(0x5EED_1234)
        for shape in Self.shapes {
            let q = MLXRandom.normal([1, shape.kvHeads, 64, shape.headDim]).asType(.bfloat16)
            let k = (MLXRandom.normal([1, shape.kvHeads, 64, shape.headDim]) * 0.55)
                .asType(.bfloat16)
            let logits =
                MLX.matmul(q.asType(.float32), k.asType(.float32).transposed(0, 1, 3, 2))
                * shape.scale
            eval(logits)
            let spread = MLX.max(MLX.abs(logits)).item(Float.self)
            print(
                String(
                    format: "[acc] %@ headDim %3d scale %.4f -> max|QK| = %.2f",
                    shape.name, shape.headDim, shape.scale, spread))
        }
    }
}
