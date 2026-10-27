import Foundation
import MLXLLM

/// Metadata and allocator bounds, never a load permit or a context/workspace
/// calibration. The caller must separately reserve execution state and workspace.
struct GLM5NextStageLoadResources {
    struct Tensor {
        let bytes: Int
        let allocationBound: Int
    }
    struct Summary: Codable, Equatable {
        let stageIndex: Int
        let cut: Int
        let includesMTP: Bool
        var includesVision = false
        let textStoredBytes: Int
        let mtpStoredBytes: Int
        let additionalMTPEmbeddingBytes: Int
        let selectedStoredBytes: Int
        /// Packed bytes are neither expanded nor requantized. Shared embedding
        /// and head are counted once in the final stage, including its MTP owner.
        let selectedLoadedTensorBytes: Int
        let deferredVisionStoredBytes: Int
        let sourceAllocationBoundBytes: Int
        let largestSourceTensorBytes: Int
        let largestExpertBankBytes: Int
        let nativeConstructionAllowanceBytes: Int
        let hostReadAllowanceBytes: Int
        let metadataAllowanceBytes: Int
        let initialLoadPeakBytes: Int
    }

    let summary: Summary
    let selected: [String: Tensor]
    let selectedNamesSHA256: String
    let storageCommitmentSHA256: String

    init(inventory: GLM5NextWeightInventory, stageIndex: Int, cut: Int, includeMTP: Bool,
         executionPolicy: GLM5NextExecutionPolicy, metadataAllowanceBytes: Int,
         maximumBufferBytes: Int, allocationBound: (Int) throws -> Int, includeVision: Bool = false) throws {
        guard (0...1).contains(stageIndex), metadataAllowanceBytes > 0, maximumBufferBytes > 0 else {
            throw ProbeError("GLM stage load requires bounded metadata, buffers and rank")
        }
        let layout = try GLM5NextStageLayout(inventory: inventory)
        let split = try layout.split(at: cut, includeMTP: includeMTP)
        let plan = try GLM5NextTextStagePlan(configuration: inventory.configuration.textConfig,
            layers: split.stages[stageIndex].globalLayers, loadMTPEmbedding: includeMTP && stageIndex == 1)
        let textNames = try plan.tensorNames(in: inventory)
        let textAndMTPNames = try layout.sourceNames(rank: stageIndex, cut: cut, includeMTP: includeMTP)
        let mtpNames = Set(inventory.entries(in: .mtp).map { $0.tensor.name })
        guard textAndMTPNames == textNames.union(includeMTP && stageIndex == 1 ? mtpNames : []),
              !textAndMTPNames.isEmpty else { throw ProbeError("GLM layout and SDK selected tensor ownership differ") }
        let visionNames = includeVision && stageIndex == 0 ? Set(inventory.entries(in: .vision).map { $0.tensor.name }) : []
        let names = textAndMTPNames.union(visionNames)
        var memo: [Int: Int] = [:]
        func bound(_ bytes: Int) throws -> Int {
            if let value = memo[bytes] { return value }
            let value = try allocationBound(bytes)
            guard bytes > 0, value >= bytes, value <= maximumBufferBytes else {
                throw ProbeError("GLM selected tensor or construction buffer exceeds allocator bounds")
            }
            memo[bytes] = value
            return value
        }
        var selected: [String: Tensor] = [:]
        var sourceBound = 0, stored = 0, largest = 0
        var banks: [String: (bytes: Int, sourceBound: Int)] = [:]
        var fusionLayers: [String: (bytes: Int, sourceBound: Int)] = [:]
        for name in names.sorted() {
            guard let entry = inventory.entries[name] else { throw ProbeError("GLM selected tensor disappeared") }
            let rounded = try bound(entry.bytes)
            selected[name] = .init(bytes: entry.bytes, allocationBound: rounded)
            sourceBound = try Self.sum([sourceBound, rounded])
            stored = try Self.sum([stored, entry.bytes])
            largest = max(largest, entry.bytes)
            if name.contains(".mlp.experts.") {
                let old = banks[entry.nativeName, default: (0, 0)]
                banks[entry.nativeName] = (try Self.sum([old.bytes, entry.bytes]),
                    try Self.sum([old.sourceBound, rounded]))
            } else if executionPolicy.projections == .fusedInputs,
                      name.hasPrefix("model.language_model.layers.") {
                // Bound all non-expert arrays of this layer as possible fused
                // inputs. This is deliberately wider than the SDK's 2/4/6
                // projection groups, without duplicating their compatibility
                // logic. Source aliases can survive until the stage is adopted.
                let layer = name.split(separator: ".").prefix(4).joined(separator: ".")
                let old = fusionLayers[layer, default: (0, 0)]
                fusionLayers[layer] = (try Self.sum([old.bytes, entry.bytes]),
                    try Self.sum([old.sourceBound, rounded]))
            }
        }
        var largestBank = 0, largestBankBound = 0, bankRoundingExcess = 0
        for bank in banks.values {
            let rounded = try bound(bank.bytes)
            largestBank = max(largestBank, bank.bytes)
            largestBankBound = max(largestBankBound, rounded)
            bankRoundingExcess = try Self.sum([bankRoundingExcess, max(0, rounded - bank.sourceBound)])
        }
        var fusionAllowance = 0
        for layer in fusionLayers.values {
            fusionAllowance = try Self.sum([fusionAllowance, layer.sourceBound, bound(layer.bytes)])
        }
        // Vision constructor roots, source aliases, layout copies and final
        // parameters can coexist until the checked construction fence.
        let visionBound = try Self.sum(visionNames.map { selected[$0]!.allocationBound })
        let construction = try Self.sum([largestBankBound, bankRoundingExcess, fusionAllowance, visionBound, visionBound, visionBound])
        // Read Data + owned MLX copy, the concurrent verification chunks and
        // the aligned payload-read scratch extent (GLM5NextAlignedPayloadReader).
        let host = try Self.sum([largest, largest, GLM5NextArtifactLoader.verificationHostBytes,
            GLM5NextArtifactLoader.payloadReadScratchAllowanceBytes])
        let textBytes = try plan.tensorBytes(in: inventory)
        let mtpBytes = includeMTP && stageIndex == 1 ? layout.mtp.bytes : 0
        guard stored == (try Self.sum([split.stages[stageIndex].source.bytes, includeVision && stageIndex == 0 ? layout.vision.bytes : 0])),
              stored == (try Self.sum([textBytes, mtpBytes, includeVision && stageIndex == 0 ? layout.vision.bytes : 0])) else {
            throw ProbeError("GLM selected stored-byte conservation differs")
        }
        summary = .init(stageIndex: stageIndex, cut: cut, includesMTP: includeMTP, includesVision: includeVision,
            textStoredBytes: textBytes, mtpStoredBytes: mtpBytes,
            additionalMTPEmbeddingBytes: includeMTP && stageIndex == 1 ? layout.embedding.bytes : 0,
            selectedStoredBytes: stored, selectedLoadedTensorBytes: stored,
            deferredVisionStoredBytes: includeVision && stageIndex == 0 ? 0 : layout.vision.bytes, sourceAllocationBoundBytes: sourceBound,
            largestSourceTensorBytes: largest, largestExpertBankBytes: largestBank,
            nativeConstructionAllowanceBytes: construction, hostReadAllowanceBytes: host,
            metadataAllowanceBytes: metadataAllowanceBytes,
            initialLoadPeakBytes: try Self.sum([sourceBound, construction, host, metadataAllowanceBytes]))
        self.selected = selected
        selectedNamesSHA256 = sha256(try canonicalJSONData(names.sorted()))
        storageCommitmentSHA256 = try GLM5NextStageContractMetadata.storageCommitment(
            inventory: inventory, cut: cut, includeMTP: includeMTP)
    }

    static func sum(_ values: [Int]) throws -> Int {
        try values.reduce(0) { total, value in
            let next = total.addingReportingOverflow(value)
            guard value >= 0, !next.overflow else { throw ProbeError("GLM stage resource byte overflow") }
            return next.partialValue
        }
    }
}
