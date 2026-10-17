import DarkbloomClusterProtocol
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
