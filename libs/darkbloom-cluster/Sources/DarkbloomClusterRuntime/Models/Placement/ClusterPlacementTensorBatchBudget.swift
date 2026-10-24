import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

#if canImport(MLX)
import MLX
extension ClusterPlacementArtifact {
    /// Uses the owner's actual canonical inventory and budget derivation at
    /// its complete LOAD envelope, regardless of the reference prompt or
    /// installed frame size. Both supported KV backends fit the paged quote.
    public static func requestedTensorBatchQuote(directory: URL, promptTokens: Int, outputTokens: Int,
                                                 chunkTokens: Int, lanes: Int, assistantDepth: Int? = nil,
                                                 assistantVerification: ClusterQwenTensorAssistantPolicy.Verification = .singleton,
                                                 allocationBound: (Int) throws -> Int) throws -> ClusterPlacementTensorBatchQuote {
        let configuration = try configuration(directory: directory)
        let request = try requestedScope(directory: directory, promptTokens: promptTokens, outputTokens: outputTokens)
        return try tensorBatchQuote(configuration: configuration, stored: storedTensors(directory: directory),
            request: request, chunkTokens: chunkTokens, lanes: lanes, assistantDepth: assistantDepth, assistantVerification: assistantVerification,
            allocationBound: allocationBound)
    }

    /// The same pure header calculation can be checked against native LOAD
    /// without fabricating tensor payloads or constructing model parameters.
    static func tensorBatchQuote(configuration: Data, stored: [ClusterPlacementStoredTensor],
                                 request: ClusterPlacementRequestScope, chunkTokens: Int, lanes: Int,
                                 assistantDepth: Int? = nil,
                                 assistantVerification: ClusterQwenTensorAssistantPolicy.Verification = .singleton,
                                 allocationBound: (Int) throws -> Int) throws -> ClusterPlacementTensorBatchQuote {
        let family = try QwenDensePlacementFamily(configuration: configuration)
        try request.validate()
        guard request.runtimeModelID == family.runtimeModelID,
              request.artifactSHA256 == family.definition.specification.artifactSHA256,
              request.configurationSHA256 == family.definition.specification.configurationSHA256,
              request.maximumPromptTokens == family.profile.maximumPromptTokens,
              request.maximumOutputTokens == family.profile.maximumOutputTokens,
              request.maximumContextTokens == family.profile.maximumContextTokens,
              Set(stored.map(\.name)).count == stored.count else {
            throw ProbeError("Tensor quotation differs from the exact registered request or tensor inventory")
        }
        guard assistantDepth != nil || assistantVerification == .singleton else {
            throw ProbeError("Target cohort quotation requires an explicit assistant depth")
        }
        guard family.definition.specification.model == .qwen38TwentySevenB,
              let plan = family.tensorParallel,
              [1, 2, 4, 8].contains(lanes),
              (1...family.profile.maximumChunkTokens).contains(chunkTokens) else {
            throw ProbeError("Tensor batch quotation requires exact Qwen27 and a supported width/chunk")
        }
        let canonical = try family.requireRegisteredInventory(stored)
        // Each rank reserves only its own heads, rows and input columns at
        // LOAD (`QwenTensorParallelRankLedger`): quote both ranks of every
        // split placement may choose, the equal one first.
        func rankQuotes(_ rankBytes: (QwenTensorParallelPlan, Int) throws -> Int) throws -> [ClusterPlacementTensorRankQuote] {
            try ([plan] + family.tensorParallelSharePlans).map { split in
                .init(shares: split.equalShares ? [1, 1] : split.shares,
                      requestBytesExcludingCollectives: try (0..<split.size).map { try rankBytes(split, $0) })
            }
        }
        if let depth = assistantDepth {
            let specification = family.definition.specification
            guard sha256(configuration) == specification.configurationSHA256 else {
                throw ProbeError("Tensor assistant metadata configuration differs from its registered identity")
            }
            var assistantTensors: [String: (shape: [Int], dtype: DType, byteCount: Int)] = [:]
            for tensor in stored where tensor.name.hasPrefix("mtp.") {
                let dtype: DType
                switch tensor.dtype {
                case "U32": dtype = .uint32
                case "BF16": dtype = .bfloat16
                default: throw ProbeError("Tensor assistant metadata has an unsupported stored dtype")
                }
                assistantTensors[tensor.name] = (tensor.shape, dtype, tensor.byteCount)
            }
            let footprint = try QwenTensorParallelMTPInventory.footprint(tensors: assistantTensors,
                specification: specification, allocationBound: allocationBound)
            let policy = try ClusterQwenTensorAssistantPolicy(depth: depth, inventorySHA256: footprint.fingerprint, verification: assistantVerification)
            let assistant = try ClusterPlacementTensorAssistantQuote(policy: policy,
                residentBytes: footprint.allocationBytes, loadBytes: footprint.loadBytes,
                largestAllocationBytes: footprint.largestAllocationBytes)
            func assisted(_ split: QwenTensorParallelPlan, rank: Int?) throws -> QwenTensorParallelBatchMTPBudget {
                try QwenTensorParallelBatchMTPBudget.derive(geometry: family.geometry, plan: split,
                    tensors: canonical, maximumTokens: family.profile.maximumContextTokens,
                    promptTokens: family.profile.maximumPromptTokens,
                    chunkSize: family.profile.maximumChunkTokens, lanes: lanes, depth: depth,
                    maximumSpeculativeWidth: policy.maximumSpeculativeWidth(capacity: lanes), rank: rank,
                    allocationBound: allocationBound)
            }
            let whole = try assisted(plan, rank: nil)
            return try .init(request: request, lanes: lanes, chunkTokens: chunkTokens,
                perLaneStateBytes: whole.perLaneStateBytes, sharedBytesExcludingCollectives: whole.sharedBytesExcludingCollectives,
                allowance: whole.allowance, assistant: assistant,
                rankQuotes: rankQuotes { try assisted($0, rank: $1).allowance.requestBytesExcludingCollectives })
        }
        func plain(_ split: QwenTensorParallelPlan, rank: Int?) throws -> QwenTensorParallelBatchBudget {
            try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: split,
                tensors: canonical, maximumTokens: family.profile.maximumContextTokens,
                chunkSize: family.profile.maximumChunkTokens, lanes: lanes, paged: true, rank: rank,
                allocationBound: allocationBound)
        }
        let whole = try plain(plan, rank: nil)
        return try .init(request: request, lanes: lanes, chunkTokens: chunkTokens,
            perLaneStateBytes: whole.perLaneStateBytes, sharedBytesExcludingCollectives: whole.sharedBytesExcludingCollectives,
            allowance: whole.allowance,
            rankQuotes: rankQuotes { try plain($0, rank: $1).allowance.requestBytesExcludingCollectives })
    }
}
#endif
