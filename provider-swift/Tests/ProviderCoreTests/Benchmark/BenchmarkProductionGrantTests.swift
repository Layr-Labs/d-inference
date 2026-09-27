import Foundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Benchmark production grant uses loaded slot facts")
struct BenchmarkProductionGrantTests {
    private let gib = 1 << 30
    private func sizing(assistant: Int = 0) -> SlotSizingSnapshot {
        .init(weightsBytes: 20 * gib, auxiliaryWeightBytes: assistant,
              fp16KVBytesPerToken: 20_480, maxContextLength: 262_144, defaultMaxTokens: 8192)
    }

    @Test func singleSlotGetsFullProductionBudgetAndAssistantRemainsCharged() throws {
        let target = try EngineV2Factory.benchmarkProductionGrant(
            modelId: "gemma-4-26b", sizing: sizing(), physicalBytes: UInt64(128 * gib), environment: [:])
        let normal = try EngineV2Factory.benchmarkProductionGrant(
            modelId: "gemma-4-26b", sizing: sizing(assistant: gib),
            physicalBytes: UInt64(128 * gib), environment: [:])
        #expect(normal.grantBytes == target.grantBytes - gib)
        #expect(normal.grantBytes > 16 * gib)
        #expect(normal.targetWeightBytes == 20 * gib && normal.assistantWeightBytes == gib)
        #expect(normal.residentWeightBytes == 21 * gib)
        #expect(normal.slotCount == 1 && normal.ramPrefixAllowanceBytes == 0)
        let production = UnifiedMemoryCap.kvBudgetBytes(physicalBytes: UInt64(128 * gib),
            residentWeightBytes: UInt64(21 * gib), activationReserveBytes: UInt64(11 * gib / 2),
            configReserveBytes: UInt64(4 * gib), capFraction: 0.90)
        #expect(UInt64(normal.grantBytes) == production)
    }

    @Test func modelFloorAndOperatorCapRemainIndependentOfAllocatorObservation() throws {
        let qwen = try EngineV2Factory.benchmarkProductionGrant(
            modelId: "qwen3.5-35b-a3b", sizing: sizing(), physicalBytes: UInt64(36 * gib), environment: [:])
        let gpt = try EngineV2Factory.benchmarkProductionGrant(
            modelId: "gpt-oss-20b", sizing: sizing(), physicalBytes: UInt64(36 * gib), environment: [:])
        #expect(gpt.grantBytes == qwen.grantBytes + 2 * gib)
        #expect(qwen.effectiveCapBytes == UInt64(32 * gib)) // operator 4 GiB is binding on 36 GiB
        let lowerOverride = try EngineV2Factory.benchmarkProductionGrant(
            modelId: "qwen3.5-35b-a3b", sizing: sizing(), physicalBytes: UInt64(36 * gib),
            environment: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "1"])
        #expect(lowerOverride.activationReserveBytes == qwen.activationReserveBytes)
        let stricter = try EngineV2Factory.benchmarkProductionGrant(
            modelId: "gpt-oss-20b", sizing: sizing(), physicalBytes: UInt64(64 * gib),
            environment: ["DARKBLOOM_MEM_CAP_FRACTION": "0.75"])
        #expect(stricter.effectiveCapBytes == UInt64(48 * gib))
        #expect(throws: EngineV2BenchmarkSession.Failure.self) {
            try EngineV2Factory.benchmarkProductionGrant(
                modelId: "gemma-4-26b", sizing: sizing(assistant: 7 * gib),
                physicalBytes: UInt64(36 * gib), environment: [:])
        }
    }

    @Test func logicalGrantDoesNotWaiveLiveMinimumAfterBuild() throws {
        let grant = try EngineV2Factory.benchmarkProductionGrant(
            modelId: "gemma-4-26b", sizing: sizing(), physicalBytes: UInt64(128 * gib), environment: [:])
        for backend in [EngineV2KVBackendKind.paged, .contiguous] {
            #expect(!KVHeadroomProbe.postBuildServeable(kvBackendKind: backend,
                pagedPoolBytes: UInt64(grant.grantBytes), activationReserveBytes: grant.activationReserveBytes,
                measuredHeadroomBytes: UInt64(gib - 1)))
            #expect(KVHeadroomProbe.postBuildServeable(kvBackendKind: backend,
                pagedPoolBytes: UInt64(grant.grantBytes), activationReserveBytes: grant.activationReserveBytes,
                measuredHeadroomBytes: UInt64(gib)))
        }
    }
}
