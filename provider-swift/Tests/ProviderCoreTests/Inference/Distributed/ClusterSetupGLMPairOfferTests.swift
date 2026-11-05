import DarkbloomClusterPlacement
import Foundation
import Testing

@testable import ProviderCore

/// What the model list says for GLM-5.3-Flash when no mode fits a pair as its Macs are
/// (`ClusterSetupPlanning.gpuLimitSteps`, `refusalWords`): the `darkbloom cluster gpu-limit` step where running it
/// on the Macs it runs on makes a placement fit, and "needs more memory" with the reason otherwise; never a load
/// that would fail. The recorded M5 Max's hardware idle, renamed for the M4 Max; GLM's recorded layout.
@Suite("GLM pair offer: gpu-limit step or needs more memory")
struct ClusterSetupGLMPairOfferTests {
    static let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("libs/darkbloom-cluster/Tests/PlacementChecks/Golden", isDirectory: true)
    static let gib = 1 << 30

    static func layout() throws -> ClusterModelLayout {
        try ClusterModelLayout.decode(Data(contentsOf: golden.appendingPathComponent("layouts/GLM-5.3-Flash-MLX-NVFP4-mtp.json")))
    }

    /// An idle Mac of the recorded M5 Max's hardware, under `chip`, at `gpuBytes` (its default limit, or raised).
    static func mac(chip: String, physicalGiB: Int = 128, gpuBytes: Int, raised: Bool = false) throws -> ClusterDeviceProfile {
        let recorded = try ClusterDeviceProfile.decode(Data(contentsOf: golden.appendingPathComponent("profile-mac-b.json")))
        let physical = physicalGiB * gib, wired = 4_123_000_832, cache = gib, free = physical - wired - cache - 5 * gib
        let memory = ClusterDeviceMemory(gatePolicy: "registered_dense_selected_stage_load_resources_v3",
            sampledUTC: "2026-11-05T00:00:00Z", judged: true, unjudgedReason: nil, physicalMemoryBytes: physical,
            actualFreeBytes: free, countedFileCacheBytes: cache, admissibleNowBytes: free + cache, fileBackedBytes: cache,
            fileCacheReserveBytes: (physical - wired) * 10 / 27, fileCacheAboveReserveBytes: 0,
            anonymousBytes: physical - wired - cache - free, wiredBytes: wired, compressorBytes: 0, pageableBytes: physical - wired,
            pressureLevel: 1, swapUsedBytes: 0, minimumAdmissibleBytes: 6 * gib, minimumTrulyFreeBytes: 16 * 1_048_576,
            loadingHeadroomBytes: 4 * gib, allocatorHeadroomBytes: 2 * gib, loadScratchBytes: recorded.memory.loadScratchBytes,
            pageSizeBytes: 16_384)
        return try ClusterDeviceProfile(chip: chip, performanceCores: recorded.performanceCores,
            efficiencyCores: recorded.efficiencyCores, gpuCores: recorded.gpuCores, osVersion: recorded.osVersion,
            osBuild: recorded.osBuild, physicalMemoryBytes: physical, gpuRecommendedWorkingSetBytes: gpuBytes,
            gpuMaximumBufferBytes: recorded.gpuMaximumBufferBytes, allocatorLimitBytes: min(recorded.allocatorLimitBytes, physical / 100 * 95),
            memory: memory, power: recorded.power, wiredLimitBytes: raised ? gpuBytes : nil)
    }

    static func plan(_ profiles: [(String, ClusterDeviceProfile)]) throws -> ClusterPlacementResult {
        var policy = ClusterPlacementPolicy(); policy.tensorParallelFirst = true; policy.tensorParallelAssumesUnmeasuredLink = true
        return try ClusterPlacementPlanner.plan(devices: profiles.map { .init(label: $0.0, profile: $0.1, speed: .assumedEqual) },
            layout: layout(), policy: policy)
    }

    static let names = ["m4": "Apple M4 Max, 128 GB", "m5": "Apple M5 Max, 128 GB"]
    static let defaultLimit = 115_448_725_504

    @Test("an M4 Max that keeps 101 or 96 GiB beside an M5 Max: nothing fits now, and the row names gpu-limit on the M4 Max")
    func gpuLimitStepOnTheM4Max() throws {
        for keeps in [101, 96] {
            let m4 = try Self.mac(chip: "Apple M4 Max", gpuBytes: keeps * Self.gib), m5 = try Self.mac(chip: "Apple M5 Max", gpuBytes: Self.defaultLimit)
            #expect(try Self.plan([("m4", m4), ("m5", m5)]).chosen == nil)
            let raised = try #require(try m4.withGPUMemoryLimitRaised())
            let after = try #require(try Self.plan([("m4", raised), ("m5", m5)]).chosen)
            #expect(after.possible && after.mode == .pipeline)
            let steps = try #require(ClusterSetupPlanning.gpuLimitSteps(after, profiles: ["m4": m4, "m5": m5], names: Self.names))
            #expect(steps.hasPrefix("Needs `darkbloom cluster gpu-limit` first: on Apple M4 Max, 128 GB its part needs "))
            #expect(steps.contains("GB of GPU memory, and macOS allows \(keeps) GB; `darkbloom cluster gpu-limit` raises it to 112 GB."))
            #expect(steps.hasSuffix("Run it on that Mac (it asks once, then macOS asks an administrator), then `darkbloom cluster` again."))
        }
    }

    @Test("the words for a GPU limit no raise helps name Apple silicon Macs with 128 GB or more")
    func needsMoreMemoryNamesTheRule() {
        #expect(GLM5NextGPULimitEligibility.macs == "Apple silicon Macs with 128 GB or more")
    }

    @Test("two 64 GB Macs: needs more memory, by the model's size, not a GPU step")
    func needsMoreMemoryBySize() throws {
        let a = try Self.mac(chip: "Apple M5 Max", physicalGiB: 64, gpuBytes: 48 * Self.gib)
        let b = try Self.mac(chip: "Apple M5 Max", physicalGiB: 64, gpuBytes: 48 * Self.gib)
        let words = ClusterSetupPlanning.refusalWords(try Self.plan([("a", a), ("b", b)]), localMemberID: "a",
            profiles: ["a": a, "b": b])
        #expect(words.hasPrefix("Needs more memory: these Macs together cannot hold its "))
        #expect(words.hasSuffix(", even with every application closed."))
    }
}
