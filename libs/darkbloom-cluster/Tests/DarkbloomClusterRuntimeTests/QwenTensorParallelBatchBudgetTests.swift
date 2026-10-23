import DarkbloomClusterPlacement
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

struct QwenTensorParallelBatchBudgetTests {
    private struct Inputs: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
        struct Profile: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
        let twentySeven: Profile
    }
    private func input() throws -> (QwenDensePlacementFamily, [QwenDenseCanonicalTensor]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StageMetadataChecks/Inputs/qwen-retained-inputs.json")
        let value = try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: url)).twentySeven
        let family = try QwenDensePlacementFamily(configuration: value.configuration)
        let tensors = try family.requireRegisteredInventory(value.canonicalTensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        })
        return (family, tensors)
    }
    private func bound(_ bytes: Int) -> Int { ((bytes + 16_383) / 16_384) * 16_384 }

    @Test func actualRegisteredInventoryPricesRetainedAndTransientConstantsOnceEach() throws {
        let (family, tensors) = try input(), plan = family.tensorParallel!
        let context = family.largestContextTokens, chunk = family.maximumChunkTokens
        let scalar = try QwenTensorParallelRequestBudget.derive(geometry: family.geometry, plan: plan,
            tensors: tensors, maximumTokens: context, chunkSize: chunk, allocationBound: bound)
        for lanes in [2, 4, 8] {
            let candidate = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan,
                tensors: tensors, maximumTokens: context, chunkSize: chunk, lanes: lanes, paged: true, allocationBound: bound)
            #expect(candidate.batchProjectionConstantBytes == scalar.projectionConstantBytes)
            #expect(candidate.perLaneStateBytes >= scalar.stateBytes)
            #expect(candidate.allowance.requestBytesExcludingCollectives == lanes * candidate.perLaneStateBytes + candidate.sharedBytesExcludingCollectives)
            let logits = 3 * bound(lanes * plan.vocabularySize * 4)
            #expect(candidate.sharedBytesExcludingCollectives == scalar.fusionBytes + scalar.transientBytes + logits
                + 2 * scalar.projectionConstantBytes + candidate.pagedPoolSlackBytes)
            #expect(candidate.pagedPoolSlackBytes >= 2 * CBv2StageKVHost.segmentBytes)
            // The underlying host's entire admitted page capacity, its gather
            // and replacement pages fit inside the full state charges.
            let pages = try CBv2StageKVHost.pageRoundedRequestBytes(kvShapes:
                Array(repeating: (family.geometry.kvHeads, family.geometry.headDimension), count: family.geometry.attentionLayers),
                maximumTokens: context, dtypeSize: 2)
            #expect(lanes * pages + CBv2StageKVHost.segmentBytes <= lanes * candidate.perLaneStateBytes + candidate.pagedPoolSlackBytes)
        }
    }

    @Test func shortPromptStillPricesWidestSampledGatherAndAuthenticatedFrame() throws {
        let (family, tensors) = try input(), plan = family.tensorParallel!
        for context in [1, 17, 512, 65536] {
            let candidate = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan,
                tensors: tensors, maximumTokens: context, chunkSize: 1, lanes: 8, paged: true, allocationBound: bound)
            let payload = max(8 * plan.vocabularySize * 4, QwenTensorParallelBatchWire.words * 4, 8 * plan.maximumPartialBytesPerToken)
            #expect(candidate.allowance.maximumCollectivePayloadBytes == payload)
            #expect(candidate.allowance.maximumCollectiveFrameBytes == payload + QwenTensorParallelSealCodec.frameOverhead)
            #expect(candidate.allowance.collectiveScratchBytes == 8 * bound(payload + QwenTensorParallelSealCodec.frameOverhead))
            #expect(candidate.allowance.collectiveScratchBytes > 8 * bound(payload))
        }
    }

    @Test func omittedInventoryInvalidWidthsAndAllocatorUnderchargeRefuse() throws {
        let (family, tensors) = try input(), plan = family.tensorParallel!
        func budget(_ source: [QwenDenseCanonicalTensor], lanes: Int = 8, allocator: (Int) throws -> Int = { $0 }) throws {
            _ = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan,
                tensors: source, maximumTokens: 512, chunkSize: 32, lanes: lanes, paged: true, allocationBound: allocator)
        }
        for lanes in [0, 1, 9, Int.max] { #expect(throws: (any Error).self) { try budget(tensors, lanes: lanes) } }
        #expect(throws: (any Error).self) { try budget(tensors, allocator: { $0 - 1 }) }
        #expect(throws: (any Error).self) { try budget(tensors, allocator: { _ in Int.max }) }
        #expect(throws: (any Error).self) { try budget(tensors.filter { !$0.name.hasSuffix(".mlp.down_proj.scales") }) }
    }
}
