// Copyright © 2026 Eigen Labs.
//
// Metal buffer admission for the VLM vision tower.
//
// The Qwen3-VL vision tower attends over N patches with an N×N-shaped
// intermediate, where N is the patch count of everything handed to ONE tower
// call. That intermediate is the largest allocation anywhere on the vision
// path and it grows quadratically, so whether a media request fits on the GPU
// reduces to one number: the patch count of a tower call.
//
// WHICH N×N buffer is the largest depends on which SDPA kernel MLX picks, and
// the difference is a factor of the head count:
//
//   * `Qwen3VLVision.Attention` always materializes a dense additive mask,
//     `ones([1, N, N])`, to express its per-image block-diagonal attention.
//   * MLX's FUSED full-attention kernel accepts only head dims 64, 80 and 128
//     (`sdpa_full_supported_head_dim`, backend/metal/
//     scaled_dot_product_attention.cpp). With one of those the mask is the
//     peak and the factor is 1.
//   * Otherwise MLX falls back to the unfused path, which materializes the
//     score tensor `matmul(q, kᵀ)` at `[1, H, N, N]` (fast.cpp) — H times the
//     mask. On a 16-head tower that is a 16× larger peak.
//
// So the factor is read from the model's own vision config against MLX's own
// kernel-selection rule rather than assumed. Nothing here guesses.
//
// Metal then answers the question exactly. `MTLDevice.maxBufferLength` is a
// hard per-allocation ceiling (38.9 GiB on an M2 Ultra, ~1/4 of a machine's
// RAM on Apple silicon); `MetalAllocator::malloc` compares against it BEFORE
// allocating and throws. The admissible patch count is a closed form:
//
//     N_max = floor(sqrt(maxBufferLength / (headFactor × elementBytes)))
//
// This type is pure arithmetic over `THW` grids the processor has already
// produced, which makes the decision deterministic, testable without a GPU,
// and knowable BEFORE any tower work runs.
//
// WHY THIS EXISTS AT ALL: an allocation over the ceiling is not a recoverable
// failure. MLX routes the C++ `std::runtime_error` to its error handler, whose
// default is `fatalError` — one oversized request used to take the whole
// provider process down with every co-batched request on it. This gate is the
// cheap deterministic half of the answer; `MLX.withError` at the call site is
// the guarantee, because the gate models the dominant buffer and not every
// transient MLX allocates.

import Foundation
import MLX
import MLXLMCommon

/// Admission arithmetic for one vision-tower invocation.
///
/// Pure functions; no state. Every entry point takes its limits explicitly so
/// tests pin behaviour without a Metal device.
enum VisionTowerBudget {

    /// Bytes per element of the tower's N×N attention intermediates.
    ///
    /// They are built at `queries.dtype`, i.e. the vision tower's activation
    /// dtype, which is 16-bit (bf16/fp16) in every shipping checkpoint —
    /// including the MXFP8 Qwen builds, whose quantization applies to weights,
    /// not activations. Verified against production crash reports: a
    /// 298,090,824,192-byte refusal is exactly 386,064² × 2 (mask, factor 1)
    /// or 96,516² × 16 × 2 (scores, factor 16).
    static let attentionElementBytes = 2

    /// Head dims MLX's fused full-attention kernel accepts. Mirrors
    /// `sdpa_full_supported_head_dim` in
    /// `mlx/backend/metal/scaled_dot_product_attention.cpp`. The vision tower's
    /// query length is always > 8, so the vector kernel (which accepts a
    /// different set) can never apply.
    static let fusedAttentionHeadDims: Set<Int> = [64, 80, 128]

    /// The multiple of N² the tower's largest attention buffer occupies: 1
    /// when MLX takes the fused kernel and only the additive mask is
    /// materialized, `numHeads` when it falls back and materializes the score
    /// tensor. Fails CLOSED on a nonsensical config (treats it as the fallback
    /// path) — over-tightening costs a retriable refusal, under-tightening
    /// costs the process.
    static func attentionHeadFactor(hiddenSize: Int, numHeads: Int) -> Int {
        guard numHeads > 0, hiddenSize > 0, hiddenSize % numHeads == 0 else {
            return max(1, numHeads)
        }
        return fusedAttentionHeadDims.contains(hiddenSize / numHeads) ? 1 : numHeads
    }

    /// Hard ceilings for one tower call.
    struct Limits: Sendable, Equatable {
        /// `MTLDevice.maxBufferLength` — the largest single allocation Metal
        /// will accept. Non-positive means "unknown", which disables the gate
        /// (fail open; `MLX.withError` remains the backstop).
        let maxBufferBytes: Int
        /// Bytes per element of the N×N attention intermediate.
        let attentionElementBytes: Int
        /// How many N² planes the peak buffer holds — see
        /// ``attentionHeadFactor(hiddenSize:numHeads:)``.
        let headFactor: Int
        /// Operator ceiling on patches per tower call, or nil for none.
        /// Applied on top of the device bound, never above it.
        let operatorMaxPatches: Int?

        init(
            maxBufferBytes: Int,
            attentionElementBytes: Int,
            headFactor: Int,
            operatorMaxPatches: Int? = nil
        ) {
            self.maxBufferBytes = maxBufferBytes
            self.attentionElementBytes = attentionElementBytes
            self.headFactor = max(1, headFactor)
            self.operatorMaxPatches = operatorMaxPatches
        }

        /// Bytes per N² element once the head factor is folded in.
        var bytesPerSquaredPatch: Int { attentionElementBytes * headFactor }

        /// The same limits with a different head factor.
        func withHeadFactor(_ factor: Int) -> Limits {
            Limits(
                maxBufferBytes: maxBufferBytes,
                attentionElementBytes: attentionElementBytes,
                headFactor: factor,
                operatorMaxPatches: operatorMaxPatches)
        }
    }

    enum Decision: Sendable, Equatable {
        case admit
        /// Operator-facing, content-free reason. Never embeds prompt or media
        /// bytes — only patch counts and byte budgets.
        case reject(String)
    }

    /// Live device limits, with a head factor of 1 (the fused-kernel case).
    /// Callers refine it per model with ``Limits/withHeadFactor(_:)``.
    ///
    /// Metal introspection and the env read are process-lifetime constants, so
    /// they are resolved once rather than on every media request.
    static let liveLimits: Limits = resolveLiveLimits()

    static func resolveLiveLimits(
        maxBufferBytes: Int = MLX.GPU.deviceInfo().maxBufferSize,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Limits {
        Limits(
            maxBufferBytes: maxBufferBytes,
            attentionElementBytes: attentionElementBytes,
            headFactor: 1,
            operatorMaxPatches: operatorPatchCeiling(environment: environment))
    }

    /// `DARKBLOOM_VISION_MAX_TOWER_PATCHES` — a LOWER-ONLY operator ceiling on
    /// patches per tower call.
    ///
    /// Lower-only by construction: `maxAdmissiblePatches` takes the min of
    /// this and the device bound, so the override can tighten admission on a
    /// memory-pressured box but can never talk the gate into a patch count
    /// Metal would refuse. Non-numeric or non-positive values are ignored.
    static func operatorPatchCeiling(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard let raw = environment["DARKBLOOM_VISION_MAX_TOWER_PATCHES"],
            let value = Int(raw), value > 0
        else { return nil }
        return value
    }

    /// Patches in one grid (`t × h × w`), or nil on overflow.
    static func patchCount(_ grid: THW) -> Int? {
        let (spatial, spatialOverflow) = grid.h.multipliedReportingOverflow(by: grid.w)
        guard !spatialOverflow else { return nil }
        let (total, temporalOverflow) = spatial.multipliedReportingOverflow(by: grid.t)
        guard !temporalOverflow else { return nil }
        return total >= 0 ? total : nil
    }

    /// Patches across every grid handed to ONE tower call, or nil on overflow.
    static func totalPatchCount(_ grids: [THW]) -> Int? {
        var total = 0
        for grid in grids {
            guard let count = patchCount(grid) else { return nil }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    /// Bytes of the peak N×N attention buffer, saturating at `.max`.
    static func attentionBytes(patches: Int, bytesPerSquaredPatch: Int) -> UInt64 {
        guard patches > 0, bytesPerSquaredPatch > 0 else { return 0 }
        let n = UInt64(patches)
        let (square, squareOverflow) = n.multipliedReportingOverflow(by: n)
        guard !squareOverflow else { return .max }
        let (bytes, bytesOverflow) = square.multipliedReportingOverflow(
            by: UInt64(bytesPerSquaredPatch))
        return bytesOverflow ? .max : bytes
    }

    /// Largest patch count whose peak attention buffer still fits, or nil when
    /// unbounded (device limit unknown and no operator ceiling).
    static func maxAdmissiblePatches(_ limits: Limits) -> Int? {
        var bound: Int?
        let perSquare = limits.bytesPerSquaredPatch
        if limits.maxBufferBytes > 0, perSquare > 0 {
            bound = integerSquareRoot(UInt64(limits.maxBufferBytes) / UInt64(perSquare))
        }
        if let ceiling = limits.operatorMaxPatches {
            bound = bound.map { min($0, ceiling) } ?? ceiling
        }
        return bound
    }

    /// Decide whether one tower call over `grids` can allocate its mask.
    ///
    /// `subject` names what is being admitted in the rejection message
    /// (e.g. `"image 2 of 5"`), so an operator reading a 4xx knows which part
    /// of the request to shrink.
    static func admit(grids: [THW], subject: String, limits: Limits) -> Decision {
        guard let patches = totalPatchCount(grids) else {
            return .reject(
                "\(subject) has an unrepresentable patch grid "
                    + "(\(grids.count) grid(s) overflowed 64-bit patch arithmetic)")
        }
        return admit(patches: patches, subject: subject, limits: limits)
    }

    /// Patch-count form of ``admit(grids:subject:limits:)``.
    static func admit(patches: Int, subject: String, limits: Limits) -> Decision {
        guard patches > 0 else { return .admit }
        // Unknown device limit and no operator ceiling: fail OPEN. Refusing
        // every media request because Metal introspection failed would be a
        // worse outcome than the `MLX.withError` backstop the callers install.
        guard let ceiling = maxAdmissiblePatches(limits) else { return .admit }
        guard patches > ceiling else { return .admit }

        let projected = attentionBytes(
            patches: patches, bytesPerSquaredPatch: limits.bytesPerSquaredPatch)
        var reason = "\(subject) resolves to \(patches) vision patches, above this GPU's limit of "
            + "\(ceiling); its attention would need \(formatGiB(projected)) in one Metal buffer"
        if limits.maxBufferBytes > 0 {
            reason += " (max \(formatGiB(UInt64(limits.maxBufferBytes))))"
        }
        return .reject(reason + " — send a smaller image")
    }

    /// Integer square root by Newton's method. Exact for every `UInt64`; the
    /// `Double`-then-`sqrt` shortcut loses precision above 2^53 and can round
    /// the bound UP into an allocation Metal refuses.
    static func integerSquareRoot(_ value: UInt64) -> Int {
        guard value > 0 else { return 0 }
        var estimate = UInt64(Double(value).squareRoot())
        // Newton's method converges from either side depending on the seed's
        // rounding; clamp both directions so the result is the exact floor.
        while estimate > 0, estimate > value / estimate {
            estimate = (estimate + value / estimate) / 2
        }
        while (estimate + 1) <= value / (estimate + 1) {
            estimate += 1
        }
        return estimate > UInt64(Int.max) ? Int.max : Int(estimate)
    }

    private static func formatGiB(_ bytes: UInt64) -> String {
        if bytes == .max { return "an unrepresentable number of bytes" }
        let gib = Double(bytes) / Double(1 << 30)
        return String(format: "%.1f GiB", gib)
    }
}
