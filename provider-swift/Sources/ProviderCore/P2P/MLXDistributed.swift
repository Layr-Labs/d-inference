import Foundation
import MLX
import Cmlx

// MARK: - DistributedGroup

/// Thin Swift wrapper around the mlx-c distributed group API.
///
/// jaccl (RDMA over Thunderbolt) is the only backend used here.
/// Three environment variables must be set before calling `initialize()`:
///
///   MLX_RANK=<integer>                      — this process's rank (0 = coordinator)
///   MLX_JACCL_COORDINATOR=<ip>:<port>       — rank 0's IP:port for the TCP side channel
///   MLX_IBV_DEVICES=<path/to/devices.json>  — topology file mapping ranks to RDMA interfaces
///
/// Requires macOS 26.2+ with RDMA enabled in macOS Recovery.
public struct DistributedGroup: @unchecked Sendable {
    let raw: mlx_distributed_group

    public var rank: Int { Int(mlx_distributed_group_rank(raw)) }
    public var size: Int { Int(mlx_distributed_group_size(raw)) }

    /// Initialize the distributed backend. Returns nil if RDMA is unavailable
    /// or the required environment variables are not set.
    /// Pass `strict: true` to throw instead of returning nil.
    public static func initialize(strict: Bool = false) -> DistributedGroup? {
        let g = mlx_distributed_init(strict, nil)
        guard g.ctx != nil else { return nil }
        return DistributedGroup(raw: g)
    }

    /// True if librdma.dylib loaded successfully (macOS 26.2+ with RDMA enabled).
    public static var isAvailable: Bool {
        mlx_distributed_is_available(nil)
    }
}

// MARK: - MLXArray distributed ops

public extension MLXArray {

    /// Send this array to `dst` rank. Eval the returned sentinel to synchronize.
    /// The receiver must call `distributedRecvLike` or `distributedRecv` first.
    func distributedSend(
        to dst: Int,
        group: DistributedGroup,
        stream: StreamOrDevice = .cpu
    ) -> MLXArray {
        var res = mlx_array_new()
        mlx_distributed_send(&res, ctx, Int32(dst), group.raw, stream.ctx)
        return MLXArray(res)
    }

    /// Receive an array with the same shape and dtype as this array from `src` rank.
    func distributedRecvLike(
        from src: Int,
        group: DistributedGroup,
        stream: StreamOrDevice = .cpu
    ) -> MLXArray {
        var res = mlx_array_new()
        mlx_distributed_recv_like(&res, ctx, Int32(src), group.raw, stream.ctx)
        return MLXArray(res)
    }

    /// All-reduce (sum) across all ranks in the group. Returns the reduced array.
    func allSum(
        group: DistributedGroup,
        stream: StreamOrDevice = .cpu
    ) -> MLXArray {
        var res = mlx_array_new()
        mlx_distributed_all_sum(&res, ctx, group.raw, stream.ctx)
        return MLXArray(res)
    }

    /// All-gather across all ranks. Output shape is `[group.size * ...self.shape]`.
    func allGather(
        group: DistributedGroup,
        stream: StreamOrDevice = .cpu
    ) -> MLXArray {
        var res = mlx_array_new()
        mlx_distributed_all_gather(&res, ctx, group.raw, stream.ctx)
        return MLXArray(res)
    }
}

/// Receive an array with explicit shape and dtype from `src` rank.
public func distributedRecv(
    shape: [Int],
    dtype: DType,
    from src: Int,
    group: DistributedGroup,
    stream: StreamOrDevice = .cpu
) -> MLXArray {
    var res = mlx_array_new()
    let cShape = shape.map { Int32($0) }
    mlx_distributed_recv(
        &res, cShape, cShape.count, dtype.cmlxDtype,
        Int32(src), group.raw, stream.ctx)
    return MLXArray(res)
}
