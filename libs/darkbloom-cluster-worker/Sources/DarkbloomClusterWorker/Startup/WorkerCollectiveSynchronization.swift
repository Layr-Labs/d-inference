import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Darwin
import Foundation

/// How this process's CPU waits for the GPU before a collective. Tensor
/// parallel puts its all-sum inside the lazy graph: every half-layer the CPU
/// waits for the partial, seals it and exchanges it, about 128 times a token
/// on a 64-layer model. MLX's default fence wait ends a command buffer for
/// each (about 1.5 ms on the pair, measured: 4.8 tok/s decode on the 27B);
/// its fast fence synchronization spins on a shared event instead. The value
/// only changes how the CPU waits, never what the GPU computes.
///
/// Set before any native initialization (MLX reads it once, on first use).
/// A value the launcher set is kept, so a developer can measure both.
enum WorkerCollectiveSynchronization {
    static let variable = "MLX_METAL_FAST_SYNCH"

    /// The line to log, or nil when this mode leaves the setting alone.
    static func apply(mode: ClusterGenerationMode, environment: [String: String]) -> String? {
        guard mode == .tensorParallel else { return nil }
        if let explicit = environment[variable] {
            return "darkbloom-collective-sync-v1 fast_synch=\(explicit) source=launcher"
        }
        setenv(variable, "1", 1)
        return "darkbloom-collective-sync-v1 fast_synch=1 source=worker"
    }
}

/// How much a Metal command buffer may take before MLX commits it. MLX
/// commits after 50 operations or after 50 Mi elements of distinct inputs,
/// and weights count: under tensor parallel every GLM MoE launch takes a
/// whole expert bank (151 Mi elements for one rank's gate bank), so each
/// decode step committed ~88 buffers instead of ~22, each a host round trip
/// and a GPU gap. Lifting the size bound leaves the operation bound in force.
/// Measured, GLM-5.3-Flash TP2 on two M5 Ultra: decode 52.6 -> 60.0 tok/s
/// (19.0 -> 16.8 ms a step), prefill within 2 %, tokens identical. Only the
/// commit points change, never what the GPU computes; a launcher value is kept.
enum WorkerCommandBufferBudget {
    static let variable = "MLX_MAX_MB_PER_BUFFER"
    static let tensorParallelMegaElements = 1_000_000

    static func apply(mode: ClusterGenerationMode, environment: [String: String]) -> String? {
        guard mode == .tensorParallel else { return nil }
        if let explicit = environment[variable] {
            return "darkbloom-command-buffer-budget-v1 max_mb=\(explicit) source=launcher"
        }
        setenv(variable, String(tensorParallelMegaElements), 1)
        return "darkbloom-command-buffer-budget-v1 max_mb=\(tensorParallelMegaElements) source=worker"
    }
}

/// How a GLM tensor-parallel rank's GPU meets each all-sum. The
/// hyper-connection site that reads a sum waits for it itself instead of a
/// separate spinning dispatch (`MLX_METAL_FENCED_INPUTS`; GLM's site kernels
/// declare the sum as a fenced input): a worker turns that on unless its
/// launcher chose. Only when and where the GPU waits changes, never what it
/// computes.
///
/// The fused fence update (`MLX_METAL_FUSED_FENCE_UPDATE`) stays a
/// launcher's choice: for a partial above 32 KB it splits the update over
/// several threadgroups and that path never signals the CPU, so a batched
/// round of two lanes (six rows) stalled about 0.7 s each on the pair, and a
/// synthetic chain of sites hung at five rows and more.
enum WorkerFenceFusion {
    static let variables = ["MLX_METAL_FUSED_FENCE_UPDATE", "MLX_METAL_FENCED_INPUTS"]
    /// What a worker sets where its launcher set nothing.
    static let defaults = ["MLX_METAL_FENCED_INPUTS": "1"]

    static func apply(mode: ClusterGenerationMode, family: ClusterResidentModelCatalog.Family?,
                      environment: [String: String]) -> String? {
        guard mode == .tensorParallel, family == .glm5Next else { return nil }
        var values: [String] = []
        for name in variables {
            if let explicit = environment[name] {
                values.append("\(name)=\(explicit)")
            } else if let value = defaults[name] {
                setenv(name, value, 1)
                values.append("\(name)=\(value)")
            }
        }
        let chosen = variables.filter { environment[$0] != nil }
        let source = chosen.isEmpty ? "worker" : chosen.count == variables.count ? "launcher" : "mixed"
        return "darkbloom-fence-fusion-v1 " + values.joined(separator: " ") + " source=" + source
    }
}
