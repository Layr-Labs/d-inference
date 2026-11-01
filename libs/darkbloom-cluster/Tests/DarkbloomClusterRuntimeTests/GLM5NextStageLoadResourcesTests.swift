import Foundation
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GLM selected-stage LOAD accounting")
struct GLM5NextStageLoadResourcesTests {
    static func resources(_ inventory: GLM5NextWeightInventory, rank: Int = 1,
                          cut: Int = 3, mtp: Bool = true,
                          policy: GLM5NextExecutionPolicy = .reference,
                          maximum: Int = 1 << 30) throws -> GLM5NextStageLoadResources {
        try .init(inventory: inventory, stageIndex: rank, cut: cut, includeMTP: mtp,
            executionPolicy: policy, metadataAllowanceBytes: 256 << 20,
            maximumBufferBytes: maximum, allocationBound: { bytes in
                let rounded = bytes.addingReportingOverflow(255)
                guard !rounded.overflow else { throw ProbeError("fixture allocation overflow") }
                return rounded.partialValue / 256 * 256
            })
    }

    @Test func everyCutConservesSourceAndFinalMTPEmbeddingWithoutChargingVisionToText() throws {
        let metadata = try GLM5NextMetadataTestFixture(layers: 8)
        let layout = try GLM5NextStageLayout(inventory: metadata.inventory)
        for cut in 1..<8 {
            for mtp in [false, true] {
                let first = try Self.resources(metadata.inventory, rank: 0, cut: cut, mtp: mtp)
                let last = try Self.resources(metadata.inventory, rank: 1, cut: cut, mtp: mtp)
                #expect(first.storageCommitmentSHA256 == last.storageCommitmentSHA256)
                let total = first.summary.selectedStoredBytes + last.summary.selectedStoredBytes
                #expect(total == metadata.inventory.bytes(in: .text)
                    + (mtp ? layout.mtp.bytes + layout.embedding.bytes : 0))
                #expect(first.summary.additionalMTPEmbeddingBytes == 0 && first.summary.mtpStoredBytes == 0)
                #expect(last.summary.additionalMTPEmbeddingBytes == (mtp ? layout.embedding.bytes : 0))
                #expect(last.summary.mtpStoredBytes == (mtp ? layout.mtp.bytes : 0))
                for value in [first, last] {
                    #expect(value.summary.selectedLoadedTensorBytes == value.summary.selectedStoredBytes)
                    #expect(value.summary.deferredVisionStoredBytes == layout.vision.bytes)
                    #expect(value.summary.sourceAllocationBoundBytes >= value.summary.selectedStoredBytes)
                    #expect(value.selected.keys.allSatisfy { metadata.inventory.entries[$0]!.part != .vision })
                }
                let duplicated = Set(first.selected.keys).intersection(last.selected.keys)
                let embeddingNames = Set(metadata.inventory.entries.keys.filter {
                    $0.hasPrefix("model.language_model.embed_tokens.")
                })
                #expect(duplicated == (mtp ? embeddingNames : []))
            }
        }
    }

    @Test func stackedBanksAreBoundedEvenWhenIndividualTensorsFit() throws {
        let metadata = try GLM5NextMetadataTestFixture(layers: 8)
        let encoded = try canonicalJSONData(metadata.configuration)
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        var root = try #require(decoded as? [String: Any])
        var text = try #require(root["text_config"] as? [String: Any])
        text["n_routed_experts"] = 32
        root["text_config"] = text
        let configuration = try JSONDecoder().decode(GLM5NextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: root))
        let tensors = try GLM5NextWeightInventory.expectedTensors(configuration: configuration,
            storage: .float32, shard: "a.safetensors")
        let inventory = try GLM5NextWeightInventory.validate(configuration: configuration,
            tensors: tensors, storage: .float32)
        let largestSource = try #require(inventory.entries.values.map(\.bytes).max())
        let full = try Self.resources(inventory)
        #expect(full.summary.largestExpertBankBytes > largestSource)
        #expect(throws: ProbeError.self) { try Self.resources(inventory, maximum: largestSource) }
    }

    @Test func fusedConstructionHasSeparateAllowanceAndArithmeticFailsClosed() throws {
        let metadata = try GLM5NextMetadataTestFixture(layers: 8)
        let reference = try Self.resources(metadata.inventory)
        var policy = GLM5NextExecutionPolicy.reference
        policy.projections = .fusedInputs
        let fused = try Self.resources(metadata.inventory, policy: policy)
        #expect(reference.summary.selectedStoredBytes == fused.summary.selectedStoredBytes)
        #expect(reference.summary.selectedLoadedTensorBytes == fused.summary.selectedLoadedTensorBytes)
        #expect(fused.summary.nativeConstructionAllowanceBytes > reference.summary.nativeConstructionAllowanceBytes)
        #expect(throws: ProbeError.self) {
            try GLM5NextStageLoadResources(inventory: metadata.inventory, stageIndex: 1, cut: 3,
                includeMTP: true, executionPolicy: .reference, metadataAllowanceBytes: 1,
                maximumBufferBytes: Int.max, allocationBound: { _ in Int.max })
        }
        #expect(throws: ProbeError.self) { try GLM5NextStageLoadResources.sum([Int.max, 1]) }
        #expect(throws: ProbeError.self) { try GLM5NextStageLoadResources.sum([1, -1]) }
    }

    @Test func exactCapacityBoundaryAndExplicitExecutionReservationsAreRequired() throws {
        let metadata = try GLM5NextMetadataTestFixture(layers: 8)
        let resources = try Self.resources(metadata.inventory)
        let capacity = resources.summary.initialLoadPeakBytes + 3072
        let exact = try GLM5NextStageLoadGate(resources: resources, capacityLimitBytes: capacity,
            executionStateReserveBytes: 1024, workspaceReserveBytes: 2048)
        #expect(exact.reservedBytes == capacity)
        #expect(throws: ProbeError.self) {
            try GLM5NextStageLoadGate(resources: resources, capacityLimitBytes: capacity - 1,
                executionStateReserveBytes: 1024, workspaceReserveBytes: 2048)
        }
        #expect(throws: ProbeError.self) {
            try GLM5NextStageLoadGate(resources: resources, capacityLimitBytes: Int.max,
                executionStateReserveBytes: 0, workspaceReserveBytes: 2048)
        }
        #expect(throws: ProbeError.self) {
            try GLM5NextStageLoadGate(resources: resources, capacityLimitBytes: Int.max,
                executionStateReserveBytes: Int.max, workspaceReserveBytes: 1)
        }
    }

    @Test func foreignDuplicateAndWrongSizeReadsPoisonProgress() throws {
        let metadata = try GLM5NextMetadataTestFixture(layers: 8)
        let resources = try Self.resources(metadata.inventory)
        let name = try #require(resources.selected.keys.sorted().first)
        let bytes = try #require(resources.selected[name]?.bytes)
        for mode in 0..<3 {
            let gate = try GLM5NextStageLoadGate(resources: resources, capacityLimitBytes: Int.max,
                executionStateReserveBytes: 1024, workspaceReserveBytes: 1024)
            if mode == 0 { try gate.recordRequest(name, bytes: bytes) }
            #expect(throws: ProbeError.self) {
                try gate.recordRequest(mode == 1 ? "foreign.weight" : name,
                    bytes: mode == 2 ? bytes + 1 : bytes)
            }
            #expect(gate.isFailed)
            #expect(throws: ProbeError.self) { try gate.recordRequest(name, bytes: bytes) }
        }
        let gate = try GLM5NextStageLoadGate(resources: resources, capacityLimitBytes: Int.max,
            executionStateReserveBytes: 1024, workspaceReserveBytes: 1024)
        for (name, tensor) in resources.selected { try gate.recordRequest(name, bytes: tensor.bytes) }
        #expect(gate.remainingAllocationBytes == 0)
        #expect(gate.requestedBytes == resources.summary.selectedStoredBytes)
        #expect(gate.requestedNames.count == resources.selected.count)
    }

    @Test func pressureStalenessAndAllocatorShortfallCannotGrantLoading() throws {
        let metadata = try GLM5NextMetadataTestFixture(layers: 8)
        let resources = try Self.resources(metadata.inventory)
        let gib = 1 << 30, page = 16_384, free = 64 * gib / page
        func observation(pressure: Int) -> QwenDenseStageLoadOSObservation {
            .init(startedNanoseconds: 900, completedNanoseconds: 1000, timestampUTC: "fixture",
                physicalMemoryBytes: 128 * gib, pageSizeBytes: page,
                kernelFreePages: free, freePages: free, inactivePages: 0, speculativePages: 0,
                actualFreeBytes: free * page, estimatedReclaimableBytes: free * page,
                pressureLevel: pressure, swapUsedBytes: 0)
        }
        for mode in 0..<4 {
            let gate = try GLM5NextStageLoadGate(resources: resources, capacityLimitBytes: Int.max,
                executionStateReserveBytes: 1024, workspaceReserveBytes: 1024)
            let os = observation(pressure: mode == 1 ? 4 : 1)
            let native = QwenDenseStageLoadNativeObservation(activeBytes: 0, cacheBytes: 0,
                peakBytes: 0, allocatorLimitBytes: mode == 3 ? 1 : 64 * gib)
            if mode == 0 {
                try gate.require(os: os, native: native, now: 1100)
                #expect(gate.lastAdmission?.admitted == true && !gate.isFailed)
            } else {
                #expect(throws: ProbeError.self) {
                    try gate.require(os: os, native: native, now: mode == 2 ? 2_000_001_000 : 1100)
                }
                #expect(gate.isFailed && gate.requestedNames.isEmpty)
            }
        }
    }

    @Test func operationCheckIsReleasedAndCancellationPoisonsTheGate() throws {
        final class Marker {}
        enum Refusal: Error { case cancelled }
        let metadata = try GLM5NextMetadataTestFixture(layers: 8)
        let gate = try GLM5NextStageLoadGate(resources: Self.resources(metadata.inventory),
            capacityLimitBytes: Int.max, executionStateReserveBytes: 1024, workspaceReserveBytes: 1024)
        var marker: Marker? = Marker()
        weak var observed = marker
        var cancelled = false
        try gate.beginOperation { [marker] in
            guard marker != nil, !cancelled else { throw Refusal.cancelled }
        }
        defer { gate.endOperation() }
        marker = nil
        #expect(observed != nil)
        try gate.requireOperation()
        cancelled = true
        #expect(throws: Refusal.self) { try gate.requireOperation() }
        #expect(gate.isFailed)
        gate.endOperation()
        #expect(observed == nil)
        #expect(throws: ProbeError.self) { try gate.requireOperation() }
        #expect(throws: ProbeError.self) { try gate.beginOperation(check: {}) }
    }
}
