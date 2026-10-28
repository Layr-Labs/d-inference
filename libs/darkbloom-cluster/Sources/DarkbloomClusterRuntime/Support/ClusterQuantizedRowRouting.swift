import Darwin
import Foundation

/// Which kernels take a quantized product of a few rows (`x @ w.T` with 2 to
/// MLX's vector limit - 1 rows: speculative verify windows, a cohort's rows
/// in one launch). The cluster's MLX core keeps every such row count on its
/// per-vector kernels when `MLX_QMV_BATCH_INVARIANT=1` (`env::qmv_batch_invariant`
/// in `mlx/utils.h`): a row then has the same bits at every row count from 2
/// up and at every position, as on the core every cluster path was qualified
/// on. Without it, the upstream routes the core took from MLX main (#4712:
/// NVFP4, MXFP4 and MXFP8 at 6 to 16 rows; #4682: affine split-K from 8 rows)
/// give a row other bits when more rows share its launch, so a request served
/// beside others would not get the bytes it gets alone.
///
/// Only which kernel runs changes, never a model's recipe. MLX reads the value
/// once, so every process that runs cluster arithmetic (the worker, the
/// single-Mac reference, the tensor-parallel check) sets it before anything
/// native. A value its launcher chose is kept and named in the line.
public enum ClusterQuantizedRowRouting {
    public static let variable = "MLX_QMV_BATCH_INVARIANT"
    public static let value = "1"

    /// Sets the switch unless `environment` carries it, and returns the line
    /// the process logs (`source` names the process that set it).
    public static func apply(source: String,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let explicit = environment[variable] {
            return "darkbloom-qmv-batch-invariant-v1 enabled=\(explicit) source=launcher"
        }
        setenv(variable, value, 1)
        return "darkbloom-qmv-batch-invariant-v1 enabled=\(value) source=\(source)"
    }
}
