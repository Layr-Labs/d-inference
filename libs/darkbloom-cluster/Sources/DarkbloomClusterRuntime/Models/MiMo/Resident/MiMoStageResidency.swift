import Cmlx
import Foundation
import MLX

/// Standing residency for one loaded MiMo stage, as the product keeps it for
/// the whole model (`MiMoV26WiredResidency` in the provider).
///
/// What it sets is MLX's own per-process wired limit (`mlx_set_wired_limit`):
/// the Metal allocator then keeps its buffers in a residency set of that size,
/// so a command buffer does not have to make the stage's expert tensors
/// resident again each time. It is not a system limit, needs no privilege and
/// changes nothing outside this process; MLX itself refuses a value above the
/// device's recommended working set. Without it the product measured decode
/// collapsing on a 256 GiB Mac (about 0.4 tok/s against about 38).
///
/// The ceiling is the product's: never more than the recommended working set,
/// and always leaving the larger of 16 GiB and a tenth of physical memory
/// unwired. Acceleration only: it is neither a memory permit nor a promise
/// that particular buffers are wired, and the host memory gate still decides
/// every load and request.
final class MiMoStageResidency {
    static let policy = "mimo_stage_wired_residency_v1"

    /// MLX's wired limit for this process right now. MLX offers no getter, so
    /// this sets the limit to zero, reads what it replaced and puts it back;
    /// call it only on the native executor with no evaluation in flight.
    static var current: Int {
        var previous: size_t = 0, replaced: size_t = 0
        guard mlx_set_wired_limit(&previous, 0) == 0,
              mlx_set_wired_limit(&replaced, previous) == 0 else { return -1 }
        return Int(clamping: previous)
    }

    struct Receipt: Encodable, Equatable {
        let policy = MiMoStageResidency.policy
        let requestedBytes: Int
        let ceilingBytes: Int
        let appliedBytes: Int
        let previousBytes: Int
        let recommendedWorkingSetBytes: Int
        let physicalMemoryBytes: Int
    }

    static let environmentName = "DARKBLOOM_CLUSTER_MIMO_STAGE_RESIDENCY"

    let receipt: Receipt
    private var held = true

    /// The product's bound, on this Mac's own figures.
    static func ceiling(physicalBytes: Int, recommendedBytes: Int) -> Int? {
        guard physicalBytes > 0, recommendedBytes > 0 else { return nil }
        let tenth = physicalBytes / 10 + (physicalBytes % 10 == 0 ? 0 : 1)
        let reserve = max(16 << 30, tenth)
        guard physicalBytes > reserve else { return nil }
        return min(physicalBytes - reserve, recommendedBytes)
    }

    /// Call on the native executor, with no evaluation in flight. `bytes` is
    /// what should stay resident: the stage's tensors and its request state.
    init(bytes: Int) throws {
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        guard bytes > 0, Device.defaultDevice().deviceType == .gpu,
              let recommended = GPU.maxRecommendedWorkingSetBytes(),
              let ceiling = Self.ceiling(physicalBytes: physical, recommendedBytes: recommended) else {
            throw ProbeError("MiMo stage residency requires a GPU device and its recommended working set")
        }
        let applied = min(bytes, ceiling)
        var previous: size_t = 0
        guard mlx_set_wired_limit(&previous, size_t(applied)) == 0 else {
            throw ProbeError("MLX refused the MiMo stage wired limit of \(applied) bytes")
        }
        receipt = .init(requestedBytes: bytes, ceilingBytes: ceiling, appliedBytes: applied,
            previousBytes: Int(clamping: previous), recommendedWorkingSetBytes: recommended,
            physicalMemoryBytes: physical)
    }

    /// Restores the limit that was in force before. Call before the stage's
    /// tensors are released, on the native executor.
    func end() throws {
        guard held else { return }
        held = false
        var replaced: size_t = 0
        guard mlx_set_wired_limit(&replaced, size_t(receipt.previousBytes)) == 0 else {
            throw ProbeError("MLX refused to restore the wired limit")
        }
    }

    deinit {
        if held { var replaced: size_t = 0; _ = mlx_set_wired_limit(&replaced, size_t(receipt.previousBytes)) }
    }
}
