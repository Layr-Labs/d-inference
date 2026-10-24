import Darwin

/// Keeps a serving process's GPU buffers resident while the GPU is idle.
///
/// macOS drops the residency of a process's Metal buffers about two seconds
/// after the GPU goes idle, despite MLX's standing residency request
/// (ml-explore/mlx#4609; Apple has acknowledged it as an OS bug). The first
/// request after an idle gap then waits while the model's buffers are made
/// resident again before its first kernel runs. MLX's residency refresh
/// (ml-explore/mlx#4633, `MLX_METAL_RESIDENCY_REFRESH_INTERVAL_MS`, in the
/// pinned MLX since the 2026-10-23 upstream sync) re-requests residency for
/// every non-empty residency set from a background thread at that interval.
/// It submits no GPU work; MLX builds without it ignore the variable.
public enum MLXResidencyRefresh {
    public static let environmentKey = "MLX_METAL_RESIDENCY_REFRESH_INTERVAL_MS"
    /// Shorter than the ~2 s idle window after which macOS drops residency.
    public static let defaultIntervalMilliseconds = 1000

    /// Exports the default interval unless the environment already sets the
    /// key (an operator's value, including `0` to turn the refresh off,
    /// wins). MLX reads the key once, when its Metal device is created, so
    /// this must run before the first MLX touch. Returns the value in effect.
    @discardableResult
    public static func applyDefault(
        getenv: (String) -> String? = {
            $0.withCString { Darwin.getenv($0) }.map { String(cString: $0) }
        },
        setenv: (String, String) -> Void = { name, value in
            _ = Darwin.setenv(name, value, 0)
        }
    ) -> String {
        if let existing = getenv(environmentKey) { return existing }
        let value = String(defaultIntervalMilliseconds)
        setenv(environmentKey, value)
        return value
    }
}
