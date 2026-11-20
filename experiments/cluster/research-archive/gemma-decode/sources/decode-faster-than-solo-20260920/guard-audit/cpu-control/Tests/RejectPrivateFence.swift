import Cmlx
import MLX

// Expected TYPECHECK FAILURE: an ordinary caller cannot opt an arbitrary GPU
// graph out of its fence by calling the private common implementation.
func cannotDisableModelFence(_ pendingGPUProducer: MLXArray,
                            group: mlx_distributed_group) throws {
    _ = try CollectivePointToPoint.sendInput(pendingGPUProducer, peer: 1,
        group: group, rank: 0, size: 2, maximumBytes: 16_384,
        fenceModelGPU: false, check: {})
}
