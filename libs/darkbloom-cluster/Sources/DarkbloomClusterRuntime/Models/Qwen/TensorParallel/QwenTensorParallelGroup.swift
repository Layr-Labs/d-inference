import Cmlx
import Foundation
import MLX

/// The rank group of a tensor-parallel run.
///
/// `jaccl` is RDMA over Thunderbolt between two Macs (strict: no fallback).
/// `ring` is MLX's TCP ring between two ranks on ONE Mac over 127.0.0.1
/// (`MLX_RANK`, `MLX_HOSTFILE`); it carries real reductions, so it qualifies a
/// tensor-parallel run's arithmetic and control on one Mac, and it is never a
/// pair timing or a hardware pass.
public final class QwenTensorParallelGroup: QwenTensorParallelReduction {
    public enum Backend: String, Sendable, CaseIterable {
        case jaccl
        case ring
    }

    public let backend: Backend
    public let rank: Int
    public let size: Int
    private let handle: mlx_distributed_group
    public private(set) var floatingReductions = 0

    public init(backend: Backend) throws {
        if backend == .ring { try Self.validateLocalRing() }
        guard mlx_distributed_is_available(backend.rawValue) else {
            throw ProbeError("The \(backend.rawValue) backend is not available in this build; no fallback is allowed")
        }
        var initialized = mlx_distributed_group_new()
        try MLX.withError { error in
            let status = mlx_distributed_init(&initialized, true, backend.rawValue)
            try error.check()
            guard status == 0 else { throw ProbeError("\(backend.rawValue) initialization failed: \(status)") }
        }
        handle = initialized
        self.backend = backend
        rank = Int(mlx_distributed_group_rank(initialized))
        size = Int(mlx_distributed_group_size(initialized))
        guard size == 2, (0..<size).contains(rank) else {
            mlx_distributed_group_free(initialized)
            throw ProbeError("Tensor parallel runs exactly two ranks, got rank=\(rank) size=\(size)")
        }
    }

    deinit { mlx_distributed_group_free(handle) }

    /// Unevaluated all-sum on the CPU stream: the graph decides when it runs.
    public func allSum(_ value: MLXArray) -> MLXArray {
        if [.float16, .bfloat16, .float32].contains(value.dtype) { floatingReductions += 1 }
        var result = mlx_array_new()
        let status = mlx_distributed_all_sum(&result, value.ctx, handle, StreamOrDevice.cpu.ctx)
        precondition(status == 0, "\(backend.rawValue) all-sum graph construction failed")
        return MLXArray(result)
    }

    /// Evaluated now; the caller learns whether every rank passed the same values.
    public func agree(_ values: [Int32]) throws -> Bool {
        let combined = allSum(MLXArray(values))
        try MLX.withError { error in
            eval(combined)
            try error.check()
        }
        return combined.asArray(Int32.self) == values.map { $0 &* Int32(size) }
    }

    /// Both ranks learn whether they hold the same 64-bit digest. Each rank
    /// fills its own slot with the digest's four 16-bit pieces.
    public func digestsEqual(_ digest: UInt64) throws -> Bool {
        var slots = [Int32](repeating: 0, count: 4 * size)
        for piece in 0..<4 { slots[rank * 4 + piece] = Int32((digest >> (16 * UInt64(piece))) & 0xFFFF) }
        let combined = allSum(MLXArray(slots))
        try MLX.withError { error in
            eval(combined)
            try error.check()
        }
        let all = combined.asArray(Int32.self)
        return (1..<size).allSatisfy { other in Array(all[(other * 4)..<(other * 4 + 4)]) == Array(all[0..<4]) }
    }

    /// The local ring may only open two IPv4 loopback endpoints.
    private static func validateLocalRing() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rankText = environment["MLX_RANK"], ["0", "1"].contains(rankText),
              let file = environment["MLX_HOSTFILE"], !file.isEmpty else {
            throw ProbeError("The local ring requires MLX_RANK=0|1 and MLX_HOSTFILE")
        }
        let hosts = try JSONDecoder().decode([[String]].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        guard hosts.count == 2, hosts.allSatisfy({ $0.count == 1 && $0[0].hasPrefix("127.0.0.1:") }),
              Set(hosts.map { $0[0] }).count == 2 else {
            throw ProbeError("The local ring requires exactly two distinct 127.0.0.1:port endpoints")
        }
    }
}
