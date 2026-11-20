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

    // This path has no caller-supplied MLXArray and therefore cannot silently
    // classify a uint8 GPU producer as CPU-origin storage. Keep the ordinary
    // tensor API's two-stream completion unchanged.
    private static let maximumControlBytes = 65_536

    private static func requireControlBounds(_ count: Int, maximumBytes: Int) throws {
        guard (1...maximumControlBytes).contains(maximumBytes),
              (1...maximumBytes).contains(count) else {
            throw ProbeError("CPU control bytes exceed their explicit bound")
        }
    }

    static func sendControl(_ bytes: Data, peer: Int, group: mlx_distributed_group,
                            rank: Int, size: Int, maximumBytes: Int,
                            check: () throws -> Void) throws {
        try requireControlBounds(bytes.count, maximumBytes: maximumBytes)
        let input = MLXArray(bytes, [bytes.count], dtype: .uint8)
        _ = try sendInput(input, peer: peer, group: group, rank: rank, size: size,
            maximumBytes: maximumBytes, fenceModelGPU: false, check: check)
    }

    static func receiveControl(byteCount: Int, peer: Int, group: mlx_distributed_group,
                               rank: Int, size: Int, maximumBytes: Int,
                               check: () throws -> Void) throws -> Data {
        try requireControlBounds(byteCount, maximumBytes: maximumBytes)
        let output = try receiveArray(shape: [byteCount], dtype: .uint8, peer: peer,
            group: group, rank: rank, size: size, maximumBytes: maximumBytes,
            fenceModelGPU: false, check: check)
        // The completed CPU receive has no inputs or GPU consumers. Copy only
        // after the same compact/unique/zero-offset native ownership check.
        return output.asData(access: .copy).data
    }

    /// Returns the completed native Send handle, which aliases `input` storage.
    /// Completion permits source release; it does not acknowledge peer consumption.
    static func send(_ input: MLXArray, peer: Int, group: mlx_distributed_group,
                     rank: Int, size: Int, maximumBytes: Int,
                     check: () throws -> Void) throws -> MLXArray {
        try sendInput(input, peer: peer, group: group, rank: rank, size: size,
            maximumBytes: maximumBytes, fenceModelGPU: true, check: check)
    }

    private static func sendInput(_ input: MLXArray, peer: Int, group: mlx_distributed_group,
                                  rank: Int, size: Int, maximumBytes: Int,
                                  fenceModelGPU: Bool, check: () throws -> Void) throws -> MLXArray {
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
                let gpu: StreamOrDevice? = fenceModelGPU ? .gpu : nil
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
        try receiveArray(shape: shape, dtype: dtype, peer: peer, group: group,
            rank: rank, size: size, maximumBytes: maximumBytes, fenceModelGPU: true, check: check)
    }

    private static func receiveArray(shape: [Int], dtype: DType, peer: Int,
                                     group: mlx_distributed_group, rank: Int, size: Int,
                                     maximumBytes: Int, fenceModelGPU: Bool,
                                     check: () throws -> Void) throws -> MLXArray {
        let geometry = try CollectivePointToPointShape(shape: shape, dtype: dtype,
                                                      maximumBytes: maximumBytes)
        operationLock.lock()
        defer { operationLock.unlock() }
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check() }
            try checked()
            try validatePeer(peer, group: group, rank: rank, size: size, check: checked)
            let communication = StreamOrDevice.cpu
            let gpu: StreamOrDevice? = fenceModelGPU ? .gpu : nil
            let cShape = shape.map { Int32($0) }
            let output = try makeArray(operation: "receive", check: checked) { result in
                cShape.withUnsafeBufferPointer { dimensions in
                    mlx_distributed_recv(&result, dimensions.baseAddress, dimensions.count,
                                         dtype.cmlxDtype, Int32(peer), group, communication.ctx)
                }
            }
            try complete(output, communication: communication, gpu: gpu, check: checked)
            // CPU completion drains CPU-owned references. Generic receives keep
            // both stream fences; the private control path has no GPU graph.
            try geometry.validateOwnedReceive(output)
            try checked()
            return output
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
                                 gpu: StreamOrDevice?, check: () throws -> Void) throws {
        try requireSuccess(mlx_array_eval(array.ctx), operation: "evaluation", check: check)
        try requireSuccess(mlx_synchronize(communication.ctx), operation: "CPU completion", check: check)
        // Producer tensors can originate on the model GPU stream. Waiting for its
        // completion handlers also removes transient references before ownership
        // inspection. This correctness fence is intentionally not a TPS policy.
        if let gpu {
            try requireSuccess(mlx_synchronize(gpu.ctx), operation: "GPU completion", check: check)
        } else {
            // Preserve the same fresh check/error checkpoint count. The typed
            // host-control path alone omits the unrelated default GPU fence.
            try check()
        }
    }

    private static func requireSuccess(_ status: Int32, operation: String,
                                       check: () throws -> Void) throws {
        try check()
        guard status == 0 else {
            throw ProbeError("Point-to-point \(operation) failed with C status \(status)")
        }
    }
}

/// The only tensor path allowed to omit the seven INTERMEDIATE GPU fences.
/// This is a closed seven-shape Gemma snapshot, never a generic fence switch.
/// One original owner must forbid concurrent MLX work for the whole batch.
extension CollectivePointToPoint {
    static func sendOwnedSnapshotBatch(_ batch: Gemma4MTPPullSnapshotBatch,
                                      capture: Gemma4OwnedMTPConditioning,
                                      peer: Int, group: mlx_distributed_group,
                                      rank: Int, size: Int, check: () throws -> Void) throws {
        do {
            try batch.begin()
            guard batch.direction == .send, operationLock.try() else {
                throw ProbeError("Owned snapshot send reentered or lacks exclusive transport")
            }
            defer { operationLock.unlock() }
            try MLX.withError { native in
                func checked() throws { try native.check(); try check(); try native.check() }
                try checked()
                try batch.prepare(capture,check:checked)
                let communication = StreamOrDevice.cpu, gpu = StreamOrDevice.gpu
                // Producers ONLY. Vector-evaluating network operations could
                // reorder blocking sends/receives and is deliberately forbidden.
                let contexts = batch.inputs.map(\.ctx)
                let vector = contexts.withUnsafeBufferPointer { mlx_vector_array_new_data($0.baseAddress,$0.count) }
                defer { mlx_vector_array_free(vector) }
                try requireSuccess(mlx_eval(vector),operation:"snapshot producer evaluation",check:checked)
                try snapshotBoundary(communication:communication,gpu:gpu,check:checked)
                try batch.preparedAfterFence()
                for index in 0..<7 {
                    try batch.requireNext(index); try checked()
                    try validatePeer(peer,group:group,rank:rank,size:size,check:checked)
                    let geometry = batch.geometries[index], input = batch.inputs[index]
                    try geometry.validateMetadata(input); try checked()
                    let output = try snapshotArray(batch:batch,index:index,operation:"send",check:checked) { result in
                        mlx_distributed_send(&result,input.ctx,Int32(peer),group,communication.ctx)
                    }
                    // Every C evaluation, CPU completion and the old post-GPU
                    // check remains. Only that unrelated GPU wait is deferred.
                    try complete(output,communication:communication,gpu:nil,check:checked)
                    try geometry.validateMetadata(output); try checked()
                    try batch.transferCompleted(index)
                }
                try snapshotBoundary(communication:communication,gpu:gpu,check:checked)
                try batch.finishAfterFence()
            }
        } catch { batch.poison(); throw error }
    }

    static func receiveOwnedSnapshotBatch(_ batch: Gemma4MTPPullSnapshotBatch,
                                         peer: Int, group: mlx_distributed_group,
                                         rank: Int, size: Int, check: () throws -> Void) throws {
        do {
            try batch.begin()
            guard batch.direction == .receive, operationLock.try() else {
                throw ProbeError("Owned snapshot receive reentered or lacks exclusive transport")
            }
            defer { operationLock.unlock() }
            try MLX.withError { native in
                func checked() throws { try native.check(); try check(); try native.check() }
                try checked()
                let communication = StreamOrDevice.cpu, gpu = StreamOrDevice.gpu
                try snapshotBoundary(communication:communication,gpu:gpu,check:checked)
                try batch.preparedAfterFence()
                for index in 0..<7 {
                    try batch.requireNext(index); try checked()
                    try validatePeer(peer,group:group,rank:rank,size:size,check:checked)
                    let geometry = batch.geometries[index]
                    let cShape = geometry.shape.map { Int32($0) }
                    let output = try snapshotArray(batch:batch,index:index,operation:"receive",check:checked) { result in
                        cShape.withUnsafeBufferPointer { dimensions in
                            mlx_distributed_recv(&result,dimensions.baseAddress,dimensions.count,
                                geometry.dtype.cmlxDtype,Int32(peer),group,communication.ctx)
                        }
                    }
                    try complete(output,communication:communication,gpu:nil,check:checked)
                    // No descriptor alias/reshape/concat has been made. Swift
                    // references to this SAME MLXArray object do not add C roots.
                    try geometry.validateOwnedReceive(output); try checked()
                    try batch.transferCompleted(index)
                }
                try snapshotBoundary(communication:communication,gpu:gpu,check:checked)
                // Recheck before any assembly or publication, with no C vector
                // retaining these receive descriptors.
                for (geometry,array) in zip(batch.geometries,batch.outputs) {
                    try geometry.validateOwnedReceive(array); try checked()
                }
                try batch.finishAfterFence()
            }
        } catch { batch.poison(); throw error }
    }

    private static func snapshotArray(batch: Gemma4MTPPullSnapshotBatch, index: Int,
                                      operation: String, check: () throws -> Void,
                                      build: (inout mlx_array) -> Int32) throws -> MLXArray {
        var result = mlx_array_new()
        let status = build(&result)
        // Transfer even a refused/empty C result to the existing owner's staging
        // before observing C status or invoking a throwing resource callback.
        let output = MLXArray(result)
        try batch.retainOutput(output,index:index)
        try requireSuccess(status,operation:"snapshot \(operation) graph construction",check:check)
        return output
    }

    private static func snapshotBoundary(communication: StreamOrDevice, gpu: StreamOrDevice,
                                         check: () throws -> Void) throws {
        // Observe BOTH statuses even if the first fails. A failed boundary
        // poisons this batch and leaves every retained root with its owner.
        let gpuStatus = mlx_synchronize(gpu.ctx)
        let cpuStatus = mlx_synchronize(communication.ctx)
        try check()
        guard gpuStatus == 0, cpuStatus == 0 else {
            throw ProbeError("Owned snapshot boundary failed: GPU=\(gpuStatus), CPU=\(cpuStatus)")
        }
    }
}
