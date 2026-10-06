import Testing
@testable import MLXLMCommon
@testable import ProviderCore

@Suite("MiMo fixed workspace and usable KV admission")
struct MiMoMemoryAdmissionTests {
    private let gib = 1 << 30

    @Test func loadedZeroBudgetRecoversByReducingConcurrency() {
        // Production-scale reservation arithmetic, not a native allocation.
        let capacity = 24 * gib
        let workspace = 12 * gib
        let configured = 4
        let previousBudget = max(0, capacity - configured * workspace) / 23_040
        #expect(previousBudget == 0)
        let concurrency = EngineV2Bridge.nativeMemoryConcurrencyLimit(
            configured: configured, capacityBytes: capacity, requestOverheadBytes: workspace)
        #expect(concurrency == 1)
        let usable = capacity - concurrency * workspace
        #expect(usable >= gib)
        #expect(usable / 23_040 > 0)
        #expect(concurrency * workspace + usable == capacity)
    }

    @Test func grantShrinkAndGrowPreserveMinimumKVAndConfiguredCap() {
        let workspace = 4 * gib
        for (capacity, expected) in [
            (17 * gib, 4), (9 * gib, 2), (5 * gib, 1),
            (5 * gib - 1, 0), (0, 0), (17 * gib, 4), (40 * gib, 4),
        ] {
            let concurrency = EngineV2Bridge.nativeMemoryConcurrencyLimit(
                configured: 4, capacityBytes: capacity, requestOverheadBytes: workspace)
            #expect(concurrency == expected)
            if concurrency > 0 {
                #expect(capacity - concurrency * workspace >= gib)
            }
        }
    }

    @Test func unknownOrInvalidOverheadFailsClosed() {
        for overhead in [nil, -1, Int.max] as [Int?] {
            #expect(EngineV2Bridge.nativeMemoryConcurrencyLimit(
                configured: 4, capacityBytes: 24 * gib, requestOverheadBytes: overhead) == 0)
        }
        #expect(EngineV2Bridge.nativeMemoryConcurrencyLimit(
            configured: 0, capacityBytes: 24 * gib, requestOverheadBytes: 0) == 0)
        #expect(EngineV2Bridge.nativeMemoryConcurrencyLimit(
            configured: 4, capacityBytes: gib - 1, requestOverheadBytes: 0) == 0)
        #expect(EngineV2Bridge.nativeMemoryConcurrencyLimit(
            configured: 4, capacityBytes: gib, requestOverheadBytes: 0) == 4)
    }

    @Test func serviceabilityFloorIncludesWorkspaceWatermarkAndKV() {
        let workspace = 12 * gib
        let minimum = EngineV2Bridge.minimumNativeGrantBytes(fixedRequestBytes: workspace)
        #expect(minimum == ((workspace + gib) * 100 + 94) / 95)
        let usable = minimum - Int(Double(minimum) * 0.05)
        #expect(usable >= workspace + gib)
        #expect(EngineV2KVSizing.resliceMeetsServiceabilityFloor(
            ["mimo": minimum, "other": gib], minimumGrantBytes: ["mimo": minimum]))
        #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(
            ["mimo": minimum - 1, "other": gib], minimumGrantBytes: ["mimo": minimum]))
        #expect(!EngineV2KVSizing.resliceMeetsServiceabilityFloor(
            ["mimo": minimum, "other": gib - 1], minimumGrantBytes: ["mimo": minimum]))
        #expect(EngineV2Bridge.minimumNativeGrantBytes(fixedRequestBytes: Int.max) == Int.max)
        #expect(EngineV2Bridge.minimumNativeGrantBytes(fixedRequestBytes: -1) == Int.max)
    }

    @Test func groupedProfileMustFitAllRequestsRatherThanOne() {
        let rings = 25_559_040
        let policy = MiMoV26PrefillMemoryBudget(
            minimumKVBytes: gib, targetFixedBytesPerRequest: rings)
        let largeWorkspace = 23 * gib
        #expect(policy.admits(fixedBytesPerRequest: largeWorkspace, concurrency: 1,
            capacityBytes: 65 * gib, watermarkFraction: 0.05))
        #expect(!policy.admits(fixedBytesPerRequest: largeWorkspace, concurrency: 4,
            capacityBytes: 65 * gib, watermarkFraction: 0.05))
        #expect(policy.admits(fixedBytesPerRequest: 12 * gib, concurrency: 4,
            capacityBytes: 65 * gib, watermarkFraction: 0.05))
        #expect(!policy.admits(fixedBytesPerRequest: 12 * gib, concurrency: 4,
            capacityBytes: 24 * gib, watermarkFraction: 0.05))
    }

    @Test func groupedPolicyPreservesRingsWatermarkAndMinimumAtBoundary() {
        let policy = MiMoV26PrefillMemoryBudget(
            minimumKVBytes: 100, targetFixedBytesPerRequest: 10)
        // 1000 - 5% watermark = 950. Four (200 + 10) charges + 100 KV = 940.
        #expect(policy.admits(fixedBytesPerRequest: 200, concurrency: 4,
            capacityBytes: 1000, watermarkFraction: 0.05))
        #expect(!policy.admits(fixedBytesPerRequest: 203, concurrency: 4,
            capacityBytes: 1000, watermarkFraction: 0.05))
        #expect(!policy.admits(fixedBytesPerRequest: Int.max, concurrency: 4,
            capacityBytes: Int.max, watermarkFraction: 0.05))
        #expect(!policy.admits(fixedBytesPerRequest: 200, concurrency: 0,
            capacityBytes: 1000, watermarkFraction: 0.05))
        #expect(!policy.admits(fixedBytesPerRequest: 200, concurrency: 4,
            capacityBytes: 1000, watermarkFraction: .nan))
    }
}
