import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import ProviderCore

/// The width a pipeline placement saves, through the guided step's own decision (`ClusterPlacementFlow.decide`) with
/// constructed profiles, and the number the setup screen then says the pair serves at once
/// (`ClusterSetupPlanning.loads`, the number both owners, the slot's `max_concurrency` and the local API read). CPU
/// metadata only; none is a hardware result.
struct ClusterPlacementPipelineWidthTests {
    private let gib = 1_073_741_824
    /// What the constructed layout charges every rank for one request at its planned request.
    private var lane: Int { 3 * gib }
    private func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    private func profile(free: Int) throws -> ClusterDeviceProfile {
        let physical = 256 * gib
        var p = try ClusterDeviceProfile(chip: "Constructed width fixture", performanceCores: 8, efficiencyCores: 4,
            gpuCores: 40, osVersion: "27.0", osBuild: "CHECK", physicalMemoryBytes: physical,
            gpuRecommendedWorkingSetBytes: 192 * gib, gpuMaximumBufferBytes: 128 * gib, allocatorLimitBytes: 230 * gib,
            memory: .init(gatePolicy: "fixture", sampledUTC: "2026-11-01T00:00:00Z", judged: true, unjudgedReason: nil,
                physicalMemoryBytes: physical, actualFreeBytes: free, countedFileCacheBytes: 0, admissibleNowBytes: free,
                fileBackedBytes: 0, fileCacheReserveBytes: 0, fileCacheAboveReserveBytes: 0, anonymousBytes: physical - free - 4 * gib,
                wiredBytes: 4 * gib, compressorBytes: 0, pageableBytes: 252 * gib, pressureLevel: 1, swapUsedBytes: 0,
                minimumAdmissibleBytes: 6 * gib, minimumTrulyFreeBytes: 16 * 1_048_576, loadingHeadroomBytes: 4 * gib,
                allocatorHeadroomBytes: 2 * gib, loadScratchBytes: 8 * 1_048_576, pageSizeBytes: 16_384),
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
        p.speedIndex = .init(chip: p.chip, osBuild: p.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: 1_000_000, decodeIndex: 25_000)
        return p
    }

    /// A registered row's identity on a constructed two-layer pipeline layout with one cut, both prefill schedules and
    /// a whole-model charge of `lane` a request: Gemma 4 26B by default, whose pipeline lanes are sized at placement,
    /// or the Qwen 3.5 9B, whose are not.
    private typealias Row = (model: String, profile: String, adapter: ClusterRuntimeAdapter)
    private static let gemma: Row = ("registered_gemma4_26b_qat_4bit", "registered_gemma4_26b_qat_4bit_greedy_generation_v1",
                                     .gemma4LayerStage)
    private static let nineB: Row = ("registered_qwen35_9b", "registered_qwen35_9b_greedy_generation_v1", .qwen35Dense)

    private func fixture(_ row: Row = gemma) throws -> (ClusterPairDescription, ClusterRuntimeCapability, ClusterModelLayout) {
        let part = ClusterModelLayout.Part(storedBytes: 2 * gib, loadedBytes: 2 * gib, largestTensorBytes: gib / 4, tensorCount: 16)
        let end = ClusterModelLayout.Part(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 1)
        let layout = ClusterModelLayout(runtimeModelID: row.model, artifactSHA256: hash("b"), configurationSHA256: hash("c"),
            layers: (0..<2).map { .init(index: $0, kind: "fixture", weights: part, stateFixedBytes: 1024,
                stateBytesPerToken: 1024, cost: 1) }, ingress: end, egress: end, excluded: .init(), admittedCuts: [1],
            structuralCuts: [1], generationModes: [.pipeline], prefillSchedules: [.serial, .oneChunkLookahead],
            maximumPromptTokens: 1024, maximumOutputTokens: 128, maximumChunkTokens: 128,
            boundaryBytesPerToken: 4096, requestChargeEveryRankBytes: lane)
        let cap = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: row.adapter.rawValue,
            adapterVersion: row.adapter.version, runtimeModelID: row.model, artifactSHA256: hash("b"), configurationSHA256: hash("c"),
            manifestSHA256: hash("d"), profile: .init(id: row.profile, vocabularySize: 248320,
                maximumPromptTokens: 1024, maximumOutputTokens: 128, maximumChunkTokens: 128, maximumContextTokens: 1152),
            profileFingerprint: hash("e"), partitions: [.init(planSHA256: hash("f"), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 1, stagePlanSHA256: hash("1"), constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: 1, sourceLayerEnd: 2, stagePlanSHA256: hash("3"), constructionConfigurationSHA256: hash("4"))])],
            arithmeticPolicyID: row.adapter.arithmeticPolicyID, arithmeticPolicySHA256: hash("5"),
            supportedPrefillSchedules: [.serial, .oneChunkLookahead], supportedGenerationModes: [.pipeline])
        let capHash = ClusterConfigurationCodec.sha256(try ClusterRuntimeCapabilityCodec.encode(cap))
        let pair = ClusterPairDescription(schema: ClusterPairDescription.schemaName, clusterID: "fixture-cluster",
            publicModelID: "fixture-model", capabilitySHA256: capHash, chunkTokens: 128, requestTimeoutSeconds: 315,
            coordinatorPort: 5577, members: ["a", "b"].enumerated().map { index, id in
                .init(id: id, host: "192.0.2.\(index + 1)", port: 22, user: "fixture",
                    ownerExecutable: "/fixture/darkbloom", workerExecutable: "/fixture/worker", modelDirectory: "/fixture/model",
                    runtimeBinarySHA256: hash("a"), jacclDevice: "en7", linkAddress: "192.0.2.\(index + 1)", trust: nil,
                    linkSecretFile: "/fixture/\(id).secret")
            }, tokenizerFiles: [.init(path: "tokenizer.json", sha256: hash("6"), purpose: .tokenizer)],
            linkControl: .init(port: 5578, linkEpoch: UUID().uuidString.lowercased(), edgeID: UUID().uuidString.lowercased()))
        return (pair, cap, layout)
    }

    private func decide(free: Int, peerFree: Int? = nil, row: Row = gemma) throws -> ClusterSetupPlanning.PlacementDecision {
        let (pair, cap, layout) = try fixture(row)
        return try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
            localProfile: profile(free: free), peerProfile: profile(free: peerFree ?? free), layout: layout, leader: "a",
            environment: [:], benchDebugBuild: false)
    }

    /// What both Macs saved (equal, or the test fails) and what the setup screen then says the pair serves at once.
    private func lanes(_ decision: ClusterSetupPlanning.PlacementDecision, row: Row = gemma) throws
        -> (saved: Int?, schedule: ClusterPrefillSchedule, screen: Int?) {
        let (pair, cap, _) = try fixture(row)
        let setup = try #require(decision.setup)
        let saved = try ["a", "b"].map { member in
            try ClusterConfigurationCodec.decode(try #require(setup.configurations[member]), capability: cap,
                capabilitySHA256: pair.capabilitySHA256)
        }
        #expect(saved[0].batchLanes == saved[1].batchLanes && saved[0].selectedPrefillSchedule == saved[1].selectedPrefillSchedule,
            "both Macs save one width and one schedule")
        let data = try ClusterRuntimeCapabilityCodec.encode(cap)
        let screen = ClusterSetupPlanning.loads(try #require(decision.result.chosen), setup: setup, localMemberID: "a",
            capability: (cap, data, pair.capabilitySHA256)).concurrentRequests
        #expect(screen == DistributedInstalledPlan.batchLanes(configuration: saved[0], capability: cap, environment: [:]))
        return (saved[0].batchLanes, saved[0].selectedPrefillSchedule, screen)
    }

    /// One request with serial prefill, as the planner prices it: the largest rank's need.
    private func single() throws -> Int {
        let (_, _, layout) = try fixture()
        let devices = try ["a", "b"].map { label in
            ClusterPlacementDevice(label: label, profile: try profile(free: 200 * gib), speed: .init(source: .measured,
                absolute: true, rested: .init(prefillTokensPerSecond: 1_000, decodeTokensPerSecond: 50), sustained: nil,
                explanation: "fixture"))
        }
        var serial = ClusterPlacementPolicy(); serial.modes = [.pipeline]; serial.schedules = [.serial]; serial.leader = "a"
        return try #require(try ClusterPlacementPlanner.plan(devices: devices, layout: layout, policy: serial).chosen)
            .ranks.map(\.needBytes).max()!
    }

    /// A Gemma 4 pipeline saves the widest of 8, 4 and 2 lanes both Macs admit now, each lane after the first adding its
    /// whole state at the planned request to every rank's need, with serial prefill, and the setup screen says that
    /// number; where only one request fits it saves none, keeps the one-chunk lookahead and says one.
    @Test func aGemmaPipelinePlacementSavesTheWidestWidthBothMacsAdmitNow() throws {
        let one = try single()
        func need(_ lanes: Int) -> Int { one + (lanes - 1) * lane }
        for (free, expected) in [(200 * gib, 8), (need(4) + lane / 2, 4), (need(2) + lane / 2, 2),
                                 (need(1) + lane / 2, nil)] as [(Int, Int?)] {
            let decided = try decide(free: free)
            let chosen = try #require(decided.result.chosen)
            let saved = try lanes(decided)
            #expect(saved.saved == expected && saved.screen == (expected ?? 1), "\(free / gib) GiB free")
            #expect(saved.schedule == (expected == nil ? .oneChunkLookahead : .serial), "\(free / gib) GiB free")
            #expect(chosen.mode == .pipeline && chosen.prefillSchedule == saved.schedule && chosen.ranks.first?.device == "a")
            #expect(chosen.ranks.allSatisfy { $0.fit == .now && $0.needBytes <= $0.admissibleNowBytes })
            if let expected { #expect(chosen.ranks.map(\.needBytes).max() == need(expected), "\(free / gib) GiB free") }
        }
        // Both Macs must admit it: the smaller Mac decides.
        #expect(try lanes(try decide(free: 200 * gib, peerFree: need(4) + lane / 2)).saved == 4)
    }

    /// A family whose pipeline lanes are not qualified on real Macs saves no width: its plan, its schedule and its
    /// owner's default stand, as before.
    @Test func aPipelineWhoseLanesAreNotQualifiedSavesNoWidth() throws {
        let decided = try decide(free: 200 * gib, row: Self.nineB)
        let saved = try lanes(decided, row: Self.nineB)
        #expect(saved.saved == nil && saved.schedule == .oneChunkLookahead && saved.screen == 1)
        #expect(!decided.lines.contains("Concurrent request memory"))
    }
}
