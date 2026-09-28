import Cmlx
import Foundation
import MLX

/// Synchronous raw-byte shim for a strictly serialized, two-rank worker.
/// No caller may evaluate another MLX graph concurrently with these methods.
/// They check actual C evaluation/synchronization statuses; MLX's public Swift
/// eval/synchronize wrappers discard those statuses and their evalLock is private.
/// The lock below serializes shim calls only, not arbitrary model work.
/// `check` must only check/throw; it must not dispatch model/transport work.
/// A blocking backend operation still requires an independent process deadline.
enum CollectivePointToPoint {
    private static let operationLock = NSLock()

    /// Returns the completed native Send handle, which aliases `input` storage.
    /// Completion permits source release; it does not acknowledge peer consumption.
    static func send(_ input: MLXArray, peer: Int, group: mlx_distributed_group,
                     rank: Int, size: Int, maximumBytes: Int,
                     check: () throws -> Void) throws -> MLXArray {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try withExtendedLifetime(input) {
            try MLX.withError { error in
                func checked() throws { try error.check(); try check() }
                try checked()
                try validatePeer(peer, group: group, rank: rank, size: size, check: checked)
                let geometry = try CollectivePointToPointShape(
                    shape: input.shape, dtype: input.dtype, maximumBytes: maximumBytes)
                try geometry.validateMetadata(input)
                try checked()
                // Capture this exact public stream. Pinned StreamOrDevice.stream(_)
                // ignores its argument; do not use it to wrap a custom CPU stream.
                let communication = StreamOrDevice.cpu
                let gpu = StreamOrDevice.gpu
                let output = try makeArray(operation: "send", check: checked) { result in
                    mlx_distributed_send(&result, input.ctx, Int32(peer), group, communication.ctx)
                }
                try complete(output, communication: communication, gpu: gpu, check: checked)
                try geometry.validateMetadata(output)
                try checked()
                return output
            }
        }
    }

    /// Returns the actual completed Recv allocation. No dtype conversion,
    /// all-reduce, or fallback copy is performed. Unexpected aliasing fails closed.
    static func receive(shape: [Int], dtype: DType, peer: Int,
                        group: mlx_distributed_group, rank: Int, size: Int,
                        maximumBytes: Int, check: () throws -> Void) throws -> MLXArray {
        let geometry = try CollectivePointToPointShape(shape: shape, dtype: dtype,
                                                      maximumBytes: maximumBytes)
        operationLock.lock()
        defer { operationLock.unlock() }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            try checked()
            try validatePeer(peer, group: group, rank: rank, size: size, check: checked)
            let communication = StreamOrDevice.cpu
            let gpu = StreamOrDevice.gpu
            let cShape = shape.map { Int32($0) }
            let output = try makeArray(operation: "receive", check: checked) { result in
                cShape.withUnsafeBufferPointer { dimensions in
                    mlx_distributed_recv(&result, dimensions.baseAddress, dimensions.count,
                                         dtype.cmlxDtype, Int32(peer), group, communication.ctx)
                }
            }
            try complete(output, communication: communication, gpu: gpu, check: checked)
            // Completion handlers may retain array copies beyond the output event.
            // Both stream fences run before inspecting native ownership metadata.
            try geometry.validateOwnedReceive(output)
            try checked()
            return output
        }
    }

    /// Reuse the same checked native evaluation/fences for host encryption input.
    /// Only called by the serialized native owner; no concurrent model evaluation.
    static func copyCompletedBytes(_ input: MLXArray, maximumBytes: Int,
                                   check: () throws -> Void) throws -> Data {
        let geometry = try CollectivePointToPointShape(shape: input.shape, dtype: input.dtype,
            maximumBytes: maximumBytes)
        operationLock.lock(); defer { operationLock.unlock() }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try checked()
            try geometry.validateMetadata(input)
            try complete(input, communication: .cpu, gpu: .gpu, check: checked)
            let copied = input.asData(access: .copy)
            try checked()
            guard copied.shape == geometry.shape, copied.dType == geometry.dtype,
                  copied.data.count == geometry.byteCount else {
                throw ProbeError("Completed native byte copy changed layout")
            }
            return copied.data
        }
    }

    /// Reconstruct bytes only after the caller has authenticated them. This raw
    /// utility does not itself grant authentication, consumption or lease release.
    static func materializeCompletedBytes(_ bytes: Data, shape: [Int], dtype: DType,
                                         maximumBytes: Int, check: () throws -> Void) throws -> MLXArray {
        let geometry = try CollectivePointToPointShape(shape: shape, dtype: dtype,
            maximumBytes: maximumBytes)
        guard bytes.count == geometry.byteCount else { throw ProbeError("Native reconstruction byte count differs") }
        operationLock.lock(); defer { operationLock.unlock() }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            try checked()
            let array = MLXArray(bytes, shape, dtype: dtype)
            try checked()
            try complete(array, communication: .cpu, gpu: .gpu, check: checked)
            try geometry.validateOwnedReceive(array)
            try checked()
            return array
        }
    }

    private static func validatePeer(_ peer: Int, group: mlx_distributed_group,
                                     rank: Int, size: Int, check: () throws -> Void) throws {
        guard size == 2, (0..<2).contains(rank), (0..<2).contains(peer), peer != rank,
            group.ctx != nil else {
            throw ProbeError("Point-to-point transfer requires the other rank of a two-rank group")
        }
        let actualRank = Int(mlx_distributed_group_rank(group))
        let actualSize = Int(mlx_distributed_group_size(group))
        try check()
        guard actualRank == rank, actualSize == size else {
            throw ProbeError("Point-to-point group differs from its admitted rank/world identity")
        }
    }

    private static func makeArray(operation: String, check: () throws -> Void,
                                  build: (inout mlx_array) -> Int32) throws -> MLXArray {
        var result = mlx_array_new()
        var transferred = false
        defer { if !transferred { mlx_array_free(result) } }
        let status = build(&result)
        try requireSuccess(status, operation: "\(operation) graph construction", check: check)
        let array = MLXArray(result)
        transferred = true
        return array
    }

    private static func complete(_ array: MLXArray, communication: StreamOrDevice,
                                 gpu: StreamOrDevice, check: () throws -> Void) throws {
        try requireSuccess(mlx_array_eval(array.ctx), operation: "evaluation", check: check)
        try requireSuccess(mlx_synchronize(communication.ctx), operation: "CPU completion", check: check)
        // Producer tensors can originate on the model GPU stream. Waiting for its
        // completion handlers also removes transient references before ownership
        // inspection. This correctness fence is intentionally not a TPS policy.
        try requireSuccess(mlx_synchronize(gpu.ctx), operation: "GPU completion", check: check)
    }

    private static func requireSuccess(_ status: Int32, operation: String,
                                       check: () throws -> Void) throws {
        try check()
        guard status == 0 else {
            throw ProbeError("Point-to-point \(operation) failed with C status \(status)")
        }
    }
}
