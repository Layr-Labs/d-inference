import Cmlx
import MLX

// Expected TYPECHECK FAILURE against the actual implementation. A pending GPU
// producer, including dtype uint8, cannot enter the Data-only path. No execution.
func cannotClassifyGPUArrayAsCPUControl(_ pendingGPUProducer: MLXArray,
                                      group: mlx_distributed_group) throws {
    try CollectivePointToPoint.sendControl(pendingGPUProducer, peer: 1,
        group: group, rank: 0, size: 2, maximumBytes: 16_384, check: {})
}
