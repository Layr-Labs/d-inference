// Copyright © 2026 Eigen Labs.

import Foundation

/// One packaged Metal kernel library and why it could not be loaded.
public struct PackagedMetallibAttempt: Equatable, Sendable {
    public let path: String
    public let failure: String

    public init(path: String, failure: String) {
        self.path = path
        self.failure = failure
    }
}

/// Why MLX cannot bring up its Metal backend in this process.
///
/// `GPU.gemma4ExpertQMMDiagnostics()` cannot express this: its C facade
/// catches every exception out of `metal::device(gpu)` and hands back an
/// all-zero struct, which is indistinguishable from a healthy runtime that
/// simply was not asked for the expert-slice route. A caller that already
/// proved the request is in the environment must probe Metal directly to say
/// anything true about the failure.
public enum MetalRuntimeDiagnosis: Equatable, Sendable, CustomStringConvertible {
    /// A Metal device exists and a packaged kernel library loaded on it.
    case healthy
    /// No Metal device at all — headless, sandboxed, or virtualized session.
    case noMetalDevice
    /// A device exists, but no packaged kernel library was loadable on it.
    case noLoadableMetallib(hostOS: String, attempts: [PackagedMetallibAttempt])

    public var isHealthy: Bool { self == .healthy }

    public var description: String {
        switch self {
        case .healthy:
            return "Metal runtime is available"
        case .noMetalDevice:
            return """
                no Metal device is available to this process (headless, \
                sandboxed, or virtualized macOS sessions expose no GPU)
                """
        case .noLoadableMetallib(let hostOS, let attempts):
            let tried = attempts.isEmpty
                ? "no packaged kernel library was found beside the executable"
                : attempts
                    .map { "\($0.path): \($0.failure)" }
                    .joined(separator: "; ")
            return """
                no packaged Metal kernel library could be loaded on macOS \
                \(hostOS); Darkbloom requires macOS \
                \(PackagedMetallib.minimumMacOSVersion) or later — update in \
                System Settings > General > Software Update. Tried \(tried)
                """
        }
    }
}

/// Layout of the Metal kernel libraries inside a packaged `Darkbloom.app`.
///
/// Two libraries ship side by side because one file cannot serve both OS
/// floors. The M5 `_nax` kernels compile only against Metal 4.0 with a macOS
/// 26.2 deployment target, and a metallib linked for 26.2 is rejected outright
/// by every older Metal runtime — which used to take MLX's whole `Device()`
/// constructor down on macOS 15 hosts.
///
/// MLX's own `load_default_library` probes a colocated `mlx.metallib` first and
/// a colocated `Resources/mlx.metallib` second, falling through only when the
/// first fails to load. So the NAX build ships as the primary and the
/// NAX-free build as the fallback that older systems land on. `is_nax_available()`
/// is itself gated on macOS 26.2, so a host that lands on the baseline never
/// asks for a kernel the baseline lacks.
public enum PackagedMetallib {
    /// Deployment target of the primary, NAX-capable library.
    public static let primaryDeploymentTarget = "26.2"
    /// Deployment target of the baseline, NAX-free fallback library.
    public static let baselineDeploymentTarget = "15.0"
    /// Oldest macOS a packaged provider can run on. Set by the baseline
    /// library: below this the fallback is rejected too and MLX cannot start.
    /// `scripts/check-macos-floor.sh` pins this to the installers and the
    /// release workflow.
    public static let minimumMacOSVersion = baselineDeploymentTarget

    /// Probe order, relative to the directory holding the `darkbloom`
    /// executable. Mirrors MLX's `load_default_library`.
    public static let relativePaths = ["mlx.metallib", "Resources/mlx.metallib"]

    /// Signed marker proving the release staged the baseline library. Absent in
    /// pre-baseline releases, which stay installable.
    public static let baselineCapabilityRelativePath =
        "Contents/Resources/darkbloom-runtime-capabilities/baseline-metallib-v1"

    /// Baseline library location inside the app bundle.
    public static let baselineBundleRelativePath =
        "Contents/MacOS/Resources/mlx.metallib"

    /// Candidate library URLs in MLX's probe order.
    public static func candidateURLs(executableDirectory: URL) -> [URL] {
        relativePaths.map {
            executableDirectory.appendingPathComponent($0)
        }
    }

    /// `major.minor.patch` rendering of a host OS version.
    public static func versionString(
        _ version: OperatingSystemVersion
    ) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
