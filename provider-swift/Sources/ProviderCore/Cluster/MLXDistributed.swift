/// MLXDistributed -- a thin Swift binding over MLX's C distributed API.
///
/// `mlx-swift` ships the full MLX C++ core and the `mlx-c` C API (which DOES
/// expose distributed collectives: `mlx_distributed_init`,
/// `mlx_distributed_send`, `mlx_distributed_recv_like`,
/// `mlx_distributed_all_gather`, `mlx_distributed_all_sum`, ...) but does NOT
/// wrap them in Swift. This file is that missing wrapper -- the foundation of
/// Spike A (Swift-native pipeline parallelism); see
/// docs/developer/clustering-spike-plan.md.
///
/// It deliberately exposes only the primitives the pipeline path needs:
///   - init/availability + rank/size
///   - send / recv_like  (ring activation hand-off)
///   - all_gather        (final-token broadcast at the pipeline tail)
///
/// Tensor-parallel collectives (all_sum/sum_scatter) are intentionally omitted
/// for now: pipeline parallelism is the securable-first path (see
/// docs/architecture/clustering.md §3①).
///
/// NOTE (Spike A wiring): the binding calls the C symbols directly via `Cmlx`
/// and reaches into `MLXArray.ctx` (public `internal(set)`). The transport
/// (ring/jaccl), host list, and rank are configured the way exo configures
/// them -- environment variables (`MLX_HOSTFILE`, `MLX_RANK`, ...) -- before
/// `initialize()` is called. That env wiring is host/launch concern, handled by
/// the provider start path, not here.

import Cmlx
import Foundation
import MLX

public enum MLXDistributedError: Error, Sendable {
    case unavailable(backend: String)
    case initFailed(backend: String)
    case opFailed(op: String, code: Int32)
}

/// Selects the MLX distributed transport backend.
public enum MLXDistributedBackend: String, Sendable {
    /// TCP ring (Thunderbolt-IP prioritized). The PoC / no-RDMA path.
    case ring
    /// RDMA over Thunderbolt 5. Faster; requires rdma_ctl + TB5 hardware.
    case jaccl
}

/// A handle to an initialized MLX distributed group. Wraps the C
/// `mlx_distributed_group`. Not Sendable: MLX group handles are tied to the
/// process's distributed runtime and must be used from the inference actor.
public final class MLXDistributedGroup {
    let group: mlx_distributed_group

    init(group: mlx_distributed_group) {
        self.group = group
    }

    public var rank: Int { Int(mlx_distributed_group_rank(group)) }
    public var size: Int { Int(mlx_distributed_group_size(group)) }

    /// Whether a backend is available in this build/runtime.
    public static func isAvailable(_ backend: MLXDistributedBackend) -> Bool {
        backend.rawValue.withCString { mlx_distributed_is_available($0) }
    }

    /// Initialize (or join) the process's distributed group for `backend`.
    /// `strict = true` fails rather than silently falling back to a 1-rank
    /// group -- we want a hard error if the cluster didn't form.
    public static func initialize(backend: MLXDistributedBackend, strict: Bool = true) throws -> MLXDistributedGroup {
        guard isAvailable(backend) else {
            throw MLXDistributedError.unavailable(backend: backend.rawValue)
        }
        let group = backend.rawValue.withCString { mlx_distributed_init(strict, $0) }
        // A zero/empty handle indicates init failure under strict mode.
        let handle = MLXDistributedGroup(group: group)
        guard handle.size >= 1 else {
            throw MLXDistributedError.initFailed(backend: backend.rawValue)
        }
        return handle
    }

    // MARK: - Collectives (pipeline path)

    // The ring backend's collectives are CPU-only (it forces Device::cpu in
    // `communication_stream`). Passing a GPU stream makes MLX try a GPU
    // Send/Recv that has no implementation ([Send::eval_gpu] has no GPU
    // implementation). So these ops default to the CPU stream; MLX moves the
    // tensor across the GPU↔CPU boundary at the hop.

    /// Send `x` to rank `dst`. Returns the dependency array MLX produces (the
    /// graph node that must be evaluated to actually transmit).
    public func send(_ x: MLXArray, to dst: Int, stream: StreamOrDevice = .cpu) throws -> MLXArray {
        try call("send") { res in
            mlx_distributed_send(&res, x.ctx, Int32(dst), group, stream.ctx)
        }
    }

    /// Receive an array shaped like `like` from rank `src`.
    public func recvLike(_ like: MLXArray, from src: Int, stream: StreamOrDevice = .cpu) throws -> MLXArray {
        try call("recv_like") { res in
            mlx_distributed_recv_like(&res, like.ctx, Int32(src), group, stream.ctx)
        }
    }

    /// All-gather `x` across the group (used to broadcast the sampled token
    /// from the pipeline tail back to every rank).
    public func allGather(_ x: MLXArray, stream: StreamOrDevice = .cpu) throws -> MLXArray {
        try call("all_gather") { res in
            mlx_distributed_all_gather(&res, x.ctx, group, stream.ctx)
        }
    }

    // MARK: - Plumbing

    /// Run a C collective that fills an `mlx_array` out-param, mapping the
    /// non-zero return code to an error and wrapping the result as `MLXArray`.
    private func call(_ op: String, _ body: (inout mlx_array) -> Int32) throws -> MLXArray {
        var res = mlx_array_new()
        let code = body(&res)
        guard code == 0 else {
            mlx_array_free(res)
            throw MLXDistributedError.opFailed(op: op, code: code)
        }
        return MLXArray(res)
    }
}
