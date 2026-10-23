import DarkbloomClusterPlacement
import Foundation

#if canImport(MLX)
extension ClusterPlacementArtifact {
    /// Uses the owner's actual canonical inventory and budget derivation at
    /// its complete LOAD envelope, regardless of the reference prompt or
    /// installed frame size. Both supported KV backends fit the paged quote.
    public static func requestedTensorBatchQuote(directory: URL, promptTokens: Int, outputTokens: Int,
                                                 chunkTokens: Int, lanes: Int,
                                                 allocationBound: (Int) throws -> Int) throws -> ClusterPlacementTensorBatchQuote {
        let family = try QwenDensePlacementFamily(configuration: configuration(directory: directory))
        guard family.definition.specification.model == .qwen38TwentySevenB,
              let plan = family.tensorParallel, [2, 4, 8].contains(lanes),
              (1...family.profile.maximumChunkTokens).contains(chunkTokens) else {
            throw ProbeError("Tensor batch quotation requires exact Qwen27 and a supported width/chunk")
        }
        let request = try requestedScope(directory: directory, promptTokens: promptTokens, outputTokens: outputTokens)
        let canonical = try family.requireRegisteredInventory(storedTensors(directory: directory))
        let budget = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan,
            tensors: canonical, maximumTokens: family.profile.maximumContextTokens,
            chunkSize: family.profile.maximumChunkTokens, lanes: lanes, paged: true, allocationBound: allocationBound)
        return try .init(request: request, lanes: lanes, chunkTokens: chunkTokens,
            perLaneStateBytes: budget.perLaneStateBytes, sharedBytesExcludingCollectives: budget.sharedBytesExcludingCollectives,
            allowance: budget.allowance)
    }
}
#endif
