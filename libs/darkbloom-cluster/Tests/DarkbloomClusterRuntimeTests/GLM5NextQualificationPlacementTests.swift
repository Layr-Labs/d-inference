import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

@Suite("GLM private qualification cut enumeration")
struct GLM5NextQualificationPlacementTests {
    typealias Placement = GLM5NextQualificationPlacement
    typealias BudgetTests = GLM5NextRequestStateBudgetTests

    private func device(_ rank: Int, capacity: Int = 1 << 40, memory: Int = 1 << 40,
                        allocator: Int = 1 << 40, buffer: Int = 1 << 30) -> Placement.DeviceBounds {
        .init(rank: rank, executionEnvironmentSHA256: BudgetTests.environment,
            capacityLimitBytes: capacity, availableMemoryBytes: memory,
            allocatorAvailableBytes: allocator, maximumBufferBytes: buffer,
            metadataAllowanceBytes: GLM5NextResidentResourceEnvelope.metadataAllowanceBytes)
    }

    private func evaluate(_ inventory: GLM5NextWeightInventory,
                          devices: [Placement.DeviceBounds], missingEvidence: Bool = false) throws -> Placement.Report {
        try Placement.evaluate(inventory: inventory, scope: BudgetTests.scope, executionPolicy: .reference,
            devices: devices, workspace: { _, _ in
                missingEvidence ? nil : try BudgetTests.workspace(inventory)
            }, transport: BudgetTests.transport,
            allocationBound: { _, bytes in bytes }, hostAllocationBound: { _, bytes in bytes })
    }

    @Test func everyStructuralCutUsesBothRankBoundsWithoutPublicAdmission() throws {
        let inventory = try GLM5NextMetadataTestFixture(layers: 8).inventory
        let report = try evaluate(inventory, devices: [device(1), device(0)])
        #expect(report.structuralCuts == Array(1..<8))
        #expect(report.candidates.map(\.cut) == report.structuralCuts)
        #expect(report.refusals.isEmpty)
        #expect(try GLM5NextStageLayout(inventory: inventory).admittedCuts.isEmpty)
        for candidate in report.candidates {
            #expect(candidate.ranks.map(\.rank) == [0, 1])
            let first = candidate.ranks[0], last = candidate.ranks[1]
            #expect(first.request.layers == 0..<candidate.cut)
            #expect(last.request.layers == candidate.cut..<8)
            #expect(first.load.selectedStoredBytes + last.load.selectedStoredBytes == inventory.bytes(in: .text))
            for rank in candidate.ranks {
                #expect(!rank.load.includesMTP && rank.load.mtpStoredBytes == 0)
                #expect(rank.load.deferredVisionStoredBytes == inventory.bytes(in: .vision))
                #expect(rank.combinedPeakBytes == rank.load.initialLoadPeakBytes + rank.request.reservedBytes)
                #expect(rank.combinedPeakBytes == rank.nativePeakBytes + rank.hostPeakBytes)
            }
        }
        // Limits come from each device and this cut's quote, not a chip name,
        // a preferred layer count or equal halves of stored artifact bytes.
        let target = try #require(report.candidates.first { $0.cut == 3 })
        let fitted = try evaluate(inventory, devices: target.ranks.map {
            device($0.rank, capacity: $0.combinedPeakBytes, memory: $0.combinedPeakBytes,
                allocator: $0.nativePeakBytes)
        })
        #expect(fitted.candidates.contains { $0.cut == target.cut })
        for constrainedRank in 0...1 {
            let below = try evaluate(inventory, devices: target.ranks.map {
                device($0.rank, capacity: $0.combinedPeakBytes - ($0.rank == constrainedRank ? 1 : 0),
                    memory: $0.combinedPeakBytes, allocator: $0.nativePeakBytes)
            })
            #expect(!below.candidates.contains { $0.cut == target.cut })
            #expect(below.refusals.contains { $0.cut == target.cut && $0.rank == constrainedRank })
        }
        #expect(!fitted.refusals.isEmpty)
        for candidate in fitted.candidates {
            for rank in candidate.ranks {
                #expect(rank.combinedPeakBytes <= target.ranks[rank.rank].combinedPeakBytes)
                #expect(rank.nativePeakBytes <= target.ranks[rank.rank].nativePeakBytes)
            }
        }
    }

    @Test func smallerCallerMetadataAllowanceCannotAdmitAnUnloadableCut() throws {
        let inventory = try GLM5NextMetadataTestFixture(layers: 8).inventory
        let wrong = Placement.DeviceBounds(rank: 1, executionEnvironmentSHA256: BudgetTests.environment,
            capacityLimitBytes: 1 << 40, availableMemoryBytes: 1 << 40,
            allocatorAvailableBytes: 1 << 40, maximumBufferBytes: 1 << 30,
            metadataAllowanceBytes: GLM5NextResidentResourceEnvelope.metadataAllowanceBytes - 1)
        #expect(throws: ProbeError.self) { try evaluate(inventory, devices: [device(0), wrong]) }
    }

    @Test func unknownEvidenceAndEachDeviceCeilingFailClosed() throws {
        let inventory = try GLM5NextMetadataTestFixture(layers: 8).inventory
        let absent = try evaluate(inventory, devices: [device(0), device(1)], missingEvidence: true)
        #expect(absent.candidates.isEmpty && absent.refusals.count == 14)
        for constrained in [device(1, capacity: 1), device(1, memory: 0),
                            device(1, allocator: 0), device(1, buffer: 1)] {
            let report = try evaluate(inventory, devices: [device(0), constrained])
            #expect(report.candidates.isEmpty)
            #expect(report.refusals.count == 7)
            #expect(report.refusals.allSatisfy { $0.rank == 1 && !$0.reason.isEmpty })
        }
        #expect(throws: ProbeError.self) {
            try evaluate(inventory, devices: [device(0), device(0)])
        }
    }

    @Test func localScanUsesTheSameExactQuotesAsTwoRankEvaluation() throws {
        let inventory = try GLM5NextMetadataTestFixture(layers: 8).inventory
        let both = try evaluate(inventory, devices: [device(0), device(1)])
        for rank in 0...1 {
            let local = try Placement.evaluateLocal(inventory: inventory, scope: BudgetTests.scope,
                executionPolicy: .reference, device: device(rank), workspace: { _, _ in try BudgetTests.workspace(inventory) },
                transport: BudgetTests.transport, allocationBound: { _, bytes in bytes }, hostAllocationBound: { _, bytes in bytes })
            #expect(local.structuralCuts == Array(1..<8))
            #expect(local.candidates.map(\.cut) == both.candidates.map(\.cut))
            for (a, b) in zip(local.candidates, both.candidates) {
                #expect(a.ranks.count == 1)
                #expect(a.ranks[0].nativePeakBytes == b.ranks[rank].nativePeakBytes)
                #expect(a.ranks[0].hostPeakBytes == b.ranks[rank].hostPeakBytes)
                #expect(a.ranks[0].combinedPeakBytes == b.ranks[rank].combinedPeakBytes)
            }
        }
    }
}
