import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

/// Qwen3.8 27B on the tensor-parallel pair at its native limits (262,144
/// context, 32,768 output): LOAD and the planner quote every lane at the
/// memory plan's request (32,768 + 32,768 tokens), a longer request is charged
/// at its own context when a rank reserves it, and each rank's gate admits it
/// or refuses it alone. The registered inventory and synthetic observations
/// only: no model, no GPU.
@Suite("Qwen 27B tensor parallel at its native context (registered inventory, no model)")
struct QwenTensorParallelNativeContextTests {
    private struct Retained: Decodable {
        struct Tensor: Decodable { let name: String; let shape: [Int]; let sourceDType: String; let byteCount: Int }
        struct Profile: Decodable { let configuration: Data; let canonicalTensors: [Tensor] }
        let twentySeven: Profile
    }
    private static func input() throws -> (QwenDensePlacementFamily, [QwenDenseCanonicalTensor]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("StageMetadataChecks/Inputs/qwen-retained-inputs.json")
        let input = try JSONDecoder().decode(Retained.self, from: Data(contentsOf: url)).twentySeven
        let family = try QwenDensePlacementFamily(configuration: input.configuration)
        let tensors = try family.requireRegisteredInventory(input.canonicalTensors.map {
            ClusterPlacementStoredTensor(name: $0.name, byteCount: $0.byteCount, dtype: $0.sourceDType, shape: $0.shape)
        })
        return (family, tensors)
    }
    private static func bound(_ bytes: Int) -> Int { ((bytes + 16_383) / 16_384) * 16_384 }
    private static let gib = QwenDenseStageLoadPolicy.gib

    private static func specification() throws -> QwenDenseRegisteredSpecification {
        try #require(QwenDenseRegisteredSpecification.all.first { $0.model == .qwen38TwentySevenB })
    }
    /// The profile the 27B advertises and holds requests to.
    private static func native() throws -> QwenLayerStageGenerationProfile {
        try QwenResidentAdapterDefinition.profile(specification: specification())
    }

    /// LOAD's quote at the memory plan and the charge built on it, as the
    /// resident runtime's load builds them (`depth` nil: no assistant).
    private struct Loaded {
        let charge: QwenTensorParallelRequestCharge
        let laneBytes: Int, sharedBytes: Int, reservedBytes: Int
    }
    private static func loaded(lanes: Int, depth: Int?, rank: Int = 0) throws -> Loaded {
        let (family, tensors) = try input(), plan = try #require(family.tensorParallel)
        let memory = family.profile
        let width = lanes
        if let depth {
            let quote = try QwenTensorParallelBatchMTPBudget.derive(geometry: family.geometry, plan: plan,
                tensors: tensors, maximumTokens: memory.maximumContextTokens, promptTokens: memory.maximumPromptTokens,
                chunkSize: memory.maximumChunkTokens, lanes: lanes, depth: depth, maximumSpeculativeWidth: width,
                rank: rank, allocationBound: bound)
            return .init(charge: .init(geometry: family.geometry, plan: plan, tensors: tensors, lanes: lanes, paged: true,
                    assistant: (depth, width), rank: rank, allocationBound: bound,
                    loadSharedBytes: quote.sharedBytesExcludingCollectives,
                    collectiveScratchBytes: quote.allowance.collectiveScratchBytes),
                laneBytes: quote.perLaneStateBytes, sharedBytes: quote.sharedBytesExcludingCollectives,
                reservedBytes: quote.allowance.reservedBytes)
        }
        let quote = try QwenTensorParallelBatchBudget.derive(geometry: family.geometry, plan: plan, tensors: tensors,
            maximumTokens: memory.maximumContextTokens, chunkSize: memory.maximumChunkTokens, lanes: lanes, paged: true,
            rank: rank, allocationBound: bound)
        return .init(charge: .init(geometry: family.geometry, plan: plan, tensors: tensors, lanes: lanes, paged: true,
                assistant: nil, rank: rank, allocationBound: bound,
                loadSharedBytes: quote.sharedBytesExcludingCollectives,
                collectiveScratchBytes: quote.allowance.collectiveScratchBytes),
            laneBytes: quote.perLaneStateBytes, sharedBytes: quote.sharedBytesExcludingCollectives,
            reservedBytes: quote.allowance.reservedBytes)
    }

    @Test func thePlacementFamilyPlansTheMemoryPlanNotTheNativeContext() throws {
        let (family, _) = try Self.input()
        let memory = try QwenResidentAdapterDefinition.memoryProfile(specification: Self.specification())
        #expect(family.profile == memory && family.largestContextTokens == 65_536)
        #expect(family.profile.identifier == (try Self.native()).identifier)
        #expect(try Self.native().maximumContextTokens == 262_144)
    }

    /// Within the memory plan a request is charged no more than LOAD admitted
    /// it under: the same lane and the same shared workspaces at the memory
    /// plan's own request, so nothing a pair serves today changes.
    @Test(arguments: [1, 2, 4, 8], [nil, 3] as [Int?])
    func withinTheMemoryPlanARequestIsChargedLoadsQuote(lanes: Int, depth: Int?) throws {
        let load = try Self.loaded(lanes: lanes, depth: depth)
        let atPlan = try load.charge.charge(maximumTokens: 65_536, promptTokens: 32_768, chunkSize: 512)
        #expect(atPlan.laneBytes == load.laneBytes && atPlan.sharedBytes == load.sharedBytes)
        for (context, prompt) in [(513, 512), (4_096, 3_968), (32_896, 32_768), (65_536, 32_768)] {
            let value = try load.charge.charge(maximumTokens: context, promptTokens: prompt, chunkSize: min(512, prompt))
            #expect(value.laneBytes <= load.laneBytes, "lanes=\(lanes) depth=\(String(describing: depth)) context=\(context)")
            #expect(value.sharedBytes == load.sharedBytes)
        }
    }

    /// Past the memory plan a request is charged at its own context: its lane
    /// grows by its KV pages (this rank's heads, BF16, both K and V of every
    /// attention layer) and the shared workspaces grow from LOAD's.
    @Test(arguments: [1, 8], [nil, 3] as [Int?])
    func pastTheMemoryPlanTheChargeGrowsWithTheContext(lanes: Int, depth: Int?) throws {
        let load = try Self.loaded(lanes: lanes, depth: depth)
        let (family, _) = try Self.input(), plan = try #require(family.tensorParallel)
        let local = try family.geometry.tensorParallelShard(plan: plan, rank: 0)
        let profile = try Self.native()
        let contexts = [65_537, 98_304, 131_072, 196_608, 262_144]
        let charges = try contexts.map { try load.charge.charge(contextTokens: $0, profile: profile) }
        #expect(zip(charges, charges.dropFirst()).allSatisfy { $0.laneBytes < $1.laneBytes && $0.sharedBytes <= $1.sharedBytes })
        #expect(charges.allSatisfy { $0.laneBytes > load.laneBytes && $0.sharedBytes >= load.sharedBytes })
        #expect(charges.last!.sharedBytes > load.sharedBytes)
        // Each lane's page bank: 16 tokens a page, both K and V of each of
        // this rank's attention layers, BF16.
        let pagesPerToken = 2 * local.attentionLayers * local.kvHeads * local.headDimension * 2
        #expect(charges[4].laneBytes - charges[2].laneBytes >= (262_144 - 131_072) * pagesPerToken)
        // The whole native request on an idle rank, collective scratch included.
        let whole = try load.charge.bytes(contextTokens: 262_144, profile: profile)
        #expect(whole == charges[4].laneBytes + charges[4].sharedBytes + load.charge.collectiveScratchBytes)
        // Outside the profile there is no charge.
        #expect(throws: (any Error).self) { _ = try load.charge.charge(contextTokens: 262_145, profile: profile) }
        #expect(throws: (any Error).self) { _ = try load.charge.charge(contextTokens: 1, profile: profile) }
    }

    /// Widening is unchanged: LOAD's quote for eight lanes with the assistant
    /// is the memory plan's, and a native request beside seven standard ones
    /// stays within one M5 Ultra (256 GB, 257,698,037,760 bytes recommended
    /// working set) with this rank's whole weights resident.
    @Test func eightLanesAndOneNativeRequestFitAnM5Ultra() throws {
        let load = try Self.loaded(lanes: 8, depth: 3)
        let profile = try Self.native()
        let native = try load.charge.charge(contextTokens: 262_144, profile: profile)
        let weights = try Self.specification().manifestBytes  // both ranks' weights: an upper bound for one
        let mixed = 7 * load.laneBytes + native.laneBytes + native.sharedBytes + load.charge.collectiveScratchBytes
        let workingSet = 257_698_037_760
        print("darkbloom-qwen27-native-charge-v1 lanes=8 depth=3 load_lane=\(load.laneBytes) load_shared=\(load.sharedBytes)"
            + " load_reserved=\(load.reservedBytes) native_lane=\(native.laneBytes) native_shared=\(native.sharedBytes)"
            + " collective=\(load.charge.collectiveScratchBytes) mixed=\(mixed) weights_bound=\(weights)")
        #expect(load.reservedBytes + weights < workingSet)
        #expect(mixed + weights < workingSet)
    }

    private static func request(prompt: Int, outputs: Int) throws -> QwenLayerStageGenerationRequest {
        try QwenLayerStageGenerationRequest(profile: native(), requestID: UUID(),
            promptTokenIDs: Array(repeating: 1000, count: prompt), chunkSize: min(512, prompt), outputCount: outputs,
            stopTokenIDs: [])
    }

    /// A paged request reserves its prompt and one 1,024-token granule when
    /// it opens, never its whole output (GLM's granule and margin).
    @Test func aRequestOpensWithItsPromptAndOneGranule() throws {
        typealias Session = QwenTensorParallelBatchSession
        #expect(Session.pageGrowthTokens == 1024 && Session.pageGrowthMargin == 64)
        #expect(Session.initialReservedTokens(try Self.request(prompt: 229_376, outputs: 32_768)) == 230_400)
        #expect(Session.initialReservedTokens(try Self.request(prompt: 900, outputs: 100)) == 1_000)
        // No growth while the margin is covered, or at the request's length.
        #expect(Session.pageGrowthTarget(reserved: 2_048, needed: 1_984, limit: 10_000) == nil)
        #expect(Session.pageGrowthTarget(reserved: 1_000, needed: 990, limit: 1_000) == nil)
        // A granule on, never past the length; a window past the margin, to its end and the margin.
        #expect(Session.pageGrowthTarget(reserved: 2_048, needed: 1_985, limit: 10_000) == 3_072)
        #expect(Session.pageGrowthTarget(reserved: 2_048, needed: 1_985, limit: 2_500) == 2_500)
        #expect(Session.pageGrowthTarget(reserved: 2_048, needed: 4_000, limit: 10_000) == 4_064)
    }

    /// Every step of the decode loop, and every MTP window (at most depth + 1
    /// tokens), is covered after at most one growth; growths are a granule
    /// apart and reach the request's length, up to the native context.
    @Test(arguments: [(229_376, 32_768), (7, 24), (262_143, 1), (32_768, 32_768), (300, 1_025), (40_000, 30_000)])
    func everyStepIsCoveredAndGrowthReachesTheLength(prompt: Int, outputs: Int) throws {
        typealias Session = QwenTensorParallelBatchSession
        let request = try Self.request(prompt: prompt, outputs: outputs)
        var reserved = Session.initialReservedTokens(request)
        #expect(reserved >= prompt && reserved <= request.maximumTokens)
        var growths = 0, committed = prompt
        while committed < request.finalCommittedTokens {
            // A decode step writes one token; an assistant window up to four.
            let writes = min(1 + committed % 4, request.maximumTokens - committed)
            if let target = Session.pageGrowthTarget(reserved: reserved, needed: committed + writes, limit: request.maximumTokens) {
                #expect(target > reserved && target <= request.maximumTokens)
                #expect(target == request.maximumTokens || target - reserved == Session.pageGrowthTokens)
                reserved = target; growths += 1
            }
            #expect(committed + writes <= reserved)
            committed += max(1, writes - 1)
        }
        #expect(growths <= (outputs + Session.pageGrowthTokens - 1) / Session.pageGrowthTokens)
    }

    /// A consistent observation: `free` GiB of actual free pages, nothing else counted.
    private static func observation(freeGiB: Int, physicalGiB: Int = 256, activeGiB: Int = 12,
                                    limitGiB: Int = 360) -> QwenTensorParallelRequestCharge.GateObservation {
        let page = 16_384, free = freeGiB * gib / page, inactive = 1_000, speculative = 500
        let os = QwenDenseStageLoadOSObservation(startedNanoseconds: 900, completedNanoseconds: 1_000,
            timestampUTC: "2026-10-26T00:00:00Z", physicalMemoryBytes: physicalGiB * gib, pageSizeBytes: page,
            kernelFreePages: free + speculative, freePages: free, inactivePages: inactive,
            speculativePages: speculative, actualFreeBytes: free * page,
            estimatedReclaimableBytes: (free + inactive + speculative) * page, pressureLevel: 1, swapUsedBytes: 0)
        return .init(os: os, uptimeNanoseconds: 1_100, activeBytes: activeGiB * gib, cacheBytes: 0,
            memoryLimitBytes: limitGiB * gib)
    }

    /// The gate admits the longest context whose whole charge fits now and
    /// refuses a longer one alone; the memory plan's request still fits where
    /// LOAD admitted it; an allocator limit refuses as the OS gate does; and
    /// what the owner already holds since LOAD counts against the charge.
    @Test func theGateAdmitsTheLongestContextThatFitsAndRefusesALongerOneAlone() throws {
        let load = try Self.loaded(lanes: 8, depth: 3)
        let profile = try Self.native()
        let headroom = QwenDenseStageLoadPolicy.loadingHeadroomBytes(physicalMemoryBytes: 256 * Self.gib)
        let full = try load.charge.bytes(contextTokens: 262_144, profile: profile)
        let standard = try load.charge.bytes(contextTokens: 65_536, profile: profile)
        // Room for the whole native request.
        let roomy = Self.observation(freeGiB: (full + headroom) / Self.gib + 2)
        #expect(try load.charge.admits(contextTokens: 262_144, profile: profile, grownBytes: 0, on: roomy))
        #expect(try load.charge.servingContextTokens(profile: profile, grownBytes: 0, on: roomy) == 262_144)
        // Room between the standard request and the native one: the longest
        // that fits is served, the next token's request is refused alone.
        let middle = (standard + full) / 2 + headroom
        let tight = Self.observation(freeGiB: middle / Self.gib)
        #expect(!(try load.charge.admits(contextTokens: 262_144, profile: profile, grownBytes: 0, on: tight)))
        #expect(try load.charge.admits(contextTokens: 65_536, profile: profile, grownBytes: 0, on: tight))
        let serving = try #require(try load.charge.servingContextTokens(profile: profile, grownBytes: 0, on: tight))
        #expect(serving > 65_536 && serving < 262_144)
        #expect(try load.charge.admits(contextTokens: serving, profile: profile, grownBytes: 0, on: tight))
        #expect(!(try load.charge.admits(contextTokens: serving + 1, profile: profile, grownBytes: 0, on: tight)))
        // What the owner allocated since LOAD's baseline (kept prefix entries)
        // is part of the charge, so the same free pages serve longer.
        let held = try #require(try load.charge.servingContextTokens(profile: profile, grownBytes: 4 * Self.gib, on: tight))
        #expect(held > serving)
        // The allocator's limit refuses what free pages alone would admit.
        let capped = Self.observation(freeGiB: (full + headroom) / Self.gib + 2, activeGiB: 12,
            limitGiB: 12 + 2 + (standard + full) / 2 / Self.gib)
        #expect(!(try load.charge.admits(contextTokens: 262_144, profile: profile, grownBytes: 0, on: capped)))
        #expect(try load.charge.admits(contextTokens: 65_536, profile: profile, grownBytes: 0, on: capped))
        // Below the smallest useful request nothing is admitted, and the search says so.
        let starved = Self.observation(freeGiB: 2)
        #expect(try load.charge.servingContextTokens(profile: profile, grownBytes: 0, on: starved) == nil)
    }
}
