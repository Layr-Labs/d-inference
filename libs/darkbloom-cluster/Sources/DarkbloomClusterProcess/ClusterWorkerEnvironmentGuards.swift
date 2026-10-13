import Foundation

/// Environment every rank is started with unless the operator pinned a value.
///
/// The owner's rank-environment defaults (oMLX 716591f8, `deployment.py`
/// `_RANK_ENV_DEFAULTS`), ported as they are: each entry yields to a value the
/// owner process already has in its own environment, so an operator who pinned
/// a knob keeps it and everyone else gets the tuned default.
///
/// `MLX_MAX_OPS_PER_BUFFER` / `MLX_MAX_MB_PER_BUFFER` bound how much work MLX
/// lands in one Metal command buffer (read by the MLX fork in `mlx/utils.h`).
/// An unbounded buffer can overrun the GPU driver's command-buffer execution
/// timeout, which the driver answers with SIGABRT and stranded wired memory:
/// the crash class ThunderMLX root-caused to missing caps. The bounds are a
/// property of the driver, not of a chip or a model, so they apply to every
/// Mac. The JACCL progress guard is compiled into the fork (guard v2, 30 s,
/// exit 75 with release) and takes no environment, so nothing is set for it.
public enum ClusterWorkerEnvironmentGuards {
    public static let defaults: [(name: String, value: String)] = [
        ("MLX_MAX_OPS_PER_BUFFER", "16"),
        ("MLX_MAX_MB_PER_BUFFER", "512"),
    ]

    /// `environment` with every guard added that it does not already carry,
    /// taking an operator's own value from `ownerEnvironment` first.
    public static func apply(to environment: [String: String],
                             ownerEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = environment
        for (name, value) in defaults where result[name] == nil {
            if let pinned = ownerEnvironment[name], Self.isCanonical(pinned) {
                result[name] = pinned
            } else {
                result[name] = value
            }
        }
        return result
    }

    /// A pinned value is a positive decimal integer; anything else is ignored
    /// and the default applies (a worker never receives free text).
    public static func isCanonical(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 12, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(value), number > 0 else { return false }
        return true
    }
}
