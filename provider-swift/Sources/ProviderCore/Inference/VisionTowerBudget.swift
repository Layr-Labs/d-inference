// Copyright © 2026 Eigen Labs.
//
// Metal buffer admission for the VLM vision tower.
//
// The Qwen3-VL vision tower expresses its per-image attention with a DENSE
// additive mask — `ones([1, N, N])` in `Qwen3VLVision.Attention` — where N is
// the total patch count of everything handed to ONE tower call. That single
// buffer is the largest allocation anywhere on the vision path and it grows
// quadratically, so the whole question of whether a media request fits on the
// GPU reduces to one number: the patch count of a tower call.
//
// Metal answers that question exactly. `MTLDevice.maxBufferLength` is a hard
// per-allocation ceiling (38.9 GiB on an M2 Ultra, ~1/4 of a machine's RAM on
// Apple silicon); `MetalAllocator::malloc` compares against it BEFORE
// allocating and throws. So the admissible patch count is a closed form:
//
//     N_max = floor(sqrt(maxBufferLength / maskElementBytes))
//
// This type computes that bound and the projected mask size for a set of
// grids. It is pure arithmetic over `THW` grids the processor has already
// produced, which makes the decision deterministic, testable without a GPU,
// and knowable BEFORE any tower work runs.
//
// WHY THIS EXISTS AT ALL: a mask that exceeds the ceiling is not a recoverable
// allocation failure. MLX routes the C++ `std::runtime_error` to its error
// handler, whose default is `fatalError` — one oversized request used to take
// the whole provider process down with every co-batched request on it. The
// callers pair this gate with `MLX.withError` so neither the predictable case
// (rejected here, deterministically, with a 4xx) nor the unpredictable one
// (thrown by MLX, refused with a 503) can trap the process.

import Foundation
import MLX
import MLXLMCommon

/// Admission arithmetic for one vision-tower invocation.
///
/// Pure functions; no state. Every entry point takes its limits explicitly so
/// tests pin behaviour without a Metal device.
enum VisionTowerBudget {

    /// Bytes per element of the tower's dense attention mask.
    ///
    /// The mask is built with `dtype: queries.dtype`, i.e. the vision tower's
    /// activation dtype, which is 16-bit (bf16/fp16) in every shipping
    /// checkpoint — including the MXFP8 Qwen builds, whose quantization
    /// applies to weights, not activations. Verified against production crash
    /// reports: a 298,090,824,192-byte refusal is exactly 386,064² × 2.
    static let maskElementBytes = 2

    /// Hard ceilings for one tower call.
    struct Limits: Sendable, Equatable {
        /// `MTLDevice.maxBufferLength` — the largest single allocation Metal
        /// will accept. Non-positive means "unknown", which disables the gate
        /// (fail open; `MLX.withError` remains the backstop).
        let maxBufferBytes: Int
        /// Bytes per mask element.
        let maskElementBytes: Int
        /// Operator ceiling on patches per tower call, or nil for none.
        /// Applied on top of the device bound, never above it.
        let operatorMaxPatches: Int?

        init(maxBufferBytes: Int, maskElementBytes: Int, operatorMaxPatches: Int? = nil) {
            self.maxBufferBytes = maxBufferBytes
            self.maskElementBytes = maskElementBytes
            self.operatorMaxPatches = operatorMaxPatches
        }
    }

    enum Decision: Sendable, Equatable {
        case admit
        /// Operator-facing, content-free reason. Never embeds prompt or media
        /// bytes — only patch counts and byte budgets.
        case reject(String)
    }

    /// Live device limits. Reads Metal once per call; callers resolve them
    /// outside hot loops.
    static func liveLimits(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Limits {
        Limits(
            maxBufferBytes: MLX.GPU.deviceInfo().maxBufferSize,
            maskElementBytes: maskElementBytes,
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

    /// Bytes of the dense `[1, N, N]` attention mask, saturating at `.max`.
    static func maskBytes(patches: Int, elementBytes: Int) -> UInt64 {
        guard patches > 0, elementBytes > 0 else { return 0 }
        let n = UInt64(patches)
        let (square, squareOverflow) = n.multipliedReportingOverflow(by: n)
        guard !squareOverflow else { return .max }
        let (bytes, bytesOverflow) = square.multipliedReportingOverflow(by: UInt64(elementBytes))
        return bytesOverflow ? .max : bytes
    }

    /// Largest patch count whose mask still fits, or nil when unbounded
    /// (device limit unknown and no operator ceiling).
    static func maxAdmissiblePatches(_ limits: Limits) -> Int? {
        var bound: Int?
        if limits.maxBufferBytes > 0, limits.maskElementBytes > 0 {
            bound = integerSquareRoot(UInt64(limits.maxBufferBytes) / UInt64(limits.maskElementBytes))
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

        let projected = maskBytes(patches: patches, elementBytes: limits.maskElementBytes)
        return .reject(
            "\(subject) resolves to \(patches) vision patches, above this GPU's limit of "
                + "\(ceiling); its attention mask alone would need "
                + "\(formatGiB(projected)) in one Metal buffer "
                + "(max \(formatGiB(UInt64(max(0, limits.maxBufferBytes)))))"
                + " — send a smaller image")
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
