// Copyright © 2026 Eigen Labs.
//
// GPU-only enforcement. Darkbloom is a performance-critical inference
// runtime; CPU fallback is unacceptable -- a silent CPU degradation
// turns a 60 tok/s provider into a 0.5 tok/s one. Every entry point
// that loads a model funnels through `GPUEnforcement.requireMetal()`
// so we fail loud at startup instead of slow at decode time.

import Foundation
import MLX
#if canImport(Metal)
import Metal
#endif

public enum GPUEnforcement {

    /// Result of a Metal/GPU probe. Carries the device name when
    /// available so logs and `darkbloom doctor` can surface it.
    public struct MetalStatus: Sendable, Equatable {
        public let isAvailable: Bool
        public let deviceName: String?
        public let recommendedMaxWorkingSetSizeBytes: UInt64

        public static let unavailable = MetalStatus(
            isAvailable: false,
            deviceName: nil,
            recommendedMaxWorkingSetSizeBytes: 0
        )
    }

    /// Errors raised when CPU-only behavior is detected. CLI subcommands
    /// surface these to the user with a `[FATAL]` exit instead of
    /// degrading to CPU.
    public enum Error: Swift.Error, CustomStringConvertible {
        case metalUnavailable
        case mlxDefaultIsCPU

        public var description: String {
            switch self {
            case .metalUnavailable:
                return "GPU (Metal) is unavailable on this device. "
                    + "Darkbloom requires a Metal-capable Apple Silicon GPU; "
                    + "CPU-only execution is intentionally rejected for "
                    + "performance reasons."
            case .mlxDefaultIsCPU:
                return "MLX default device resolved to CPU. "
                    + "GPU enforcement could not pin Device.gpu as the "
                    + "default \u{2014} this is usually a sign that the "
                    + "Metal device probe failed. See `darkbloom doctor`."
            }
        }
    }

    /// Probe Metal without throwing. Used by `doctor`, status banners,
    /// and the unit-test harness. The check is cheap; safe to call on
    /// every CLI invocation.
    public static func probeMetal() -> MetalStatus {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .unavailable
        }
        return MetalStatus(
            isAvailable: true,
            deviceName: device.name,
            recommendedMaxWorkingSetSizeBytes: device.recommendedMaxWorkingSetSize
        )
        #else
        return .unavailable
        #endif
    }

    /// Pin MLX's default device to GPU and verify Metal is present.
    /// Throws `Error.metalUnavailable` on Intel Macs / Linux / any host
    /// without a Metal device. Idempotent: calling multiple times is
    /// a no-op after the first success.
    public static func requireMetal() throws -> MetalStatus {
        let status = probeMetal()
        guard status.isAvailable else {
            throw Error.metalUnavailable
        }
        // Pin GPU as the global default for *new* operations. mlx-swift
        // already defaults to GPU; this is belt-and-suspenders against
        // any code path that might have called `Device.setDefault(.cpu)`
        // earlier in the process (e.g. a stray test fixture).
        Device.setDefault(device: .gpu)
        if Device.defaultDevice().deviceType != .gpu {
            throw Error.mlxDefaultIsCPU
        }
        return status
    }
}
