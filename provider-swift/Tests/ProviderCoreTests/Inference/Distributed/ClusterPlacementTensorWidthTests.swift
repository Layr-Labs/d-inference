import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import ProviderCore

/// The width a Qwen TP placement saves (`ClusterPlacementTensorWidth`), through the guided step's own decision
/// (`ClusterPlacementFlow.decide`) with constructed profiles and quotes. CPU metadata only; none is a hardware result.
@Suite(.serialized)
final class ClusterPlacementTensorWidthTests {
    private var homes: [URL] = []
    deinit { for home in homes { try? FileManager.default.removeItem(at: home) } }
    private let gib = 1_073_741_824
    private func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    /// A home with a recorded keyed link between the two members, so tensor parallel is planned on a measured link.
    private func home() throws -> URL {
        let result = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("tensor-width-inputs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        homes.append(result)
        let probe = ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 4096,
            pointToPointSmallMicroseconds: 1, pointToPointLargeBytes: 1_048_576, pointToPointLargeMicroseconds: 10,
            allSumSmallBytes: 4096, allSumSmallMicroseconds: 1, allSumLargeBytes: 1_048_576, allSumLargeMicroseconds: 10)
        #expect(ClusterLinkProbeHistory.record(probe, members: ["a", "b"], homeDirectory: result))
        return result
    }

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

    /// A registered Qwen TP row's identity: the 27B, whose features keep its plans to tensor parallel
    /// (`ClusterModelFeaturePolicy`), or the 9B, whose plans keep the pipeline a candidate, as the 35B A3B rows' do.
    private typealias Row = (model: String, profile: String)
    private static let twentySevenB: Row = ("registered_qwen38_27b", "registered_qwen38_27b_greedy_generation_v1")
    private static let nineB: Row = ("registered_qwen35_9b", "registered_qwen35_9b_greedy_generation_v1")

    /// A registered row's identity (the 27B's by default) on a constructed two-layer layout whose tensor parallel
    /// splits 1:1, 1:2 or 2:1.
    private func fixture(_ row: Row = twentySevenB)
        throws -> (ClusterPairDescription, ClusterRuntimeCapability, ClusterModelLayout, ClusterPlacementRequestScope) {
        let model = row.model
        let part = ClusterModelLayout.Part(storedBytes: 2 * gib, loadedBytes: 2 * gib, largestTensorBytes: gib / 4, tensorCount: 16)
        let end = ClusterModelLayout.Part(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 1)
        let raw = ClusterModelLayout(runtimeModelID: model, artifactSHA256: hash("b"), configurationSHA256: hash("c"),
            layers: (0..<2).map { .init(index: $0, kind: "fixture", weights: part, stateFixedBytes: 1024,
                stateBytesPerToken: 1024, cost: 1) }, ingress: end, egress: end, excluded: .init(), admittedCuts: [1],
            structuralCuts: [1], generationModes: [.pipeline, .tensorParallel], prefillSchedules: [.serial],
            maximumPromptTokens: 1024, maximumOutputTokens: 128, maximumChunkTokens: 128,
            boundaryBytesPerToken: 4096, requestChargeEveryRankBytes: gib)
        let tensor = ClusterTensorParallelLayout(family: .init(plan: "fixture-heads", ranks: [2], reductionsPerLayer: 1,
            reductionsPerStep: 0, partialBytesPerToken: 4096, stateDividesByHeads: true, shareOptions: [[1, 2], [2, 1]]),
            layerDividedBytes: [2 * gib, 2 * gib], layerReplicatedBytes: [0, 0],
            ingressDividedBytes: 0, ingressReplicatedBytes: gib / 2, egressDividedBytes: gib / 2, egressReplicatedBytes: 0)
        var object = try JSONSerialization.jsonObject(with: raw.encoded()) as! [String: Any]
        object["tensorParallel"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tensor))
        let layout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
        let cap = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: "qwen35-dense-layer-stage", adapterVersion: 1,
            runtimeModelID: model, artifactSHA256: hash("b"), configurationSHA256: hash("c"), manifestSHA256: hash("d"),
            profile: .init(id: row.profile, vocabularySize: 248320,
                maximumPromptTokens: 32768, maximumOutputTokens: 32768, maximumChunkTokens: 512, maximumContextTokens: 65536),
            profileFingerprint: hash("e"), partitions: [.init(planSHA256: hash("f"), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 1, stagePlanSHA256: hash("1"), constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: 1, sourceLayerEnd: 2, stagePlanSHA256: hash("3"), constructionConfigurationSHA256: hash("4"))])],
            arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1", arithmeticPolicySHA256: hash("5"),
            supportedGenerationModes: [.pipeline, .tensorParallel])
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
        let request = try ClusterPlacementRequestScope(runtimeModelID: model, artifactSHA256: hash("b"), configurationSHA256: hash("c"),
            promptTokens: 1024, outputTokens: 128, maximumPromptTokens: 32768, maximumOutputTokens: 32768,
            maximumContextTokens: 65536, requestChargeEveryRankBytes: gib)
        return (pair, cap, layout, request)
    }

    /// One owner's complete quote at `lanes`: 4 GiB a lane beside 1 GiB shared.
    private func quote(_ request: ClusterPlacementRequestScope, lanes: Int,
                       assistant: ClusterPlacementTensorAssistantQuote? = nil) throws -> ClusterPlacementTensorBatchQuote {
        let payload = max(512 * 4096, lanes * 248320 * 4)
        return try .init(request: request, lanes: lanes, chunkTokens: 128, perLaneStateBytes: 4 * gib,
            sharedBytesExcludingCollectives: gib,
            allowance: .init(maximumContextTokens: 65536, maximumChunkTokens: 512, requestBytesExcludingCollectives: lanes * 4 * gib + gib,
                maximumCollectivePayloadBytes: payload, maximumCollectiveFrameBytes: payload + 1024,
                allocationBound: { (($0 + 16383) / 16384) * 16384 }),
            assistant: assistant)
    }

    private func decide(_ home: URL, free: Int, peerFree: Int? = nil, widths: [Int] = ClusterPlacementBatchScope.tensorParallelWidths,
                        assistant: ClusterPlacementTensorAssistantQuote? = nil,
                        row: Row = twentySevenB) throws -> ClusterSetupPlanning.PlacementDecision {
        let (pair, cap, layout, request) = try fixture(row)
        return try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
            localProfile: profile(free: free), peerProfile: profile(free: peerFree ?? free), layout: layout,
            tensorAssistantQuote: try quote(request, lanes: 1, assistant: assistant),
            tensorWidthQuotes: try widths.map { try quote(request, lanes: $0, assistant: assistant) }, leader: "a",
            link: try #require(ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])),
            environment: [:], benchDebugBuild: false)
    }

    /// Both Macs' saved widths: equal, or the test fails.
    private func savedLanes(_ decision: ClusterSetupPlanning.PlacementDecision, row: Row = twentySevenB) throws -> Int? {
        let (pair, cap, _, _) = try fixture(row)
        let setup = try #require(decision.setup)
        let lanes = try ["a", "b"].map { member in
            try ClusterConfigurationCodec.decode(try #require(setup.configurations[member]), capability: cap,
                capabilitySHA256: pair.capabilitySHA256).batchLanes
        }
        #expect(lanes[0] == lanes[1], "both Macs save one width")
        return lanes[0]
    }

    /// The largest rank need of the placement at one width alone (no wider width offered).
    private func need(_ home: URL, lanes: Int) throws -> Int {
        let decided = try decide(home, free: 200 * gib, widths: lanes == 1 ? [] : [lanes])
        return try #require(decided.result.chosen).ranks.map(\.needBytes).max()!
    }

    @Test func aPlacementSavesTheWidestWidthBothMacsAdmitNow() throws {
        let home = try home()
        let needs = try Dictionary(uniqueKeysWithValues: [1, 2, 4, 6, 8].map { ($0, try need(home, lanes: $0)) })
        #expect(needs[1]! < needs[2]! && needs[2]! < needs[4]! && needs[4]! < needs[6]! && needs[6]! < needs[8]!)
        let singleton = try decide(home, free: 200 * gib, widths: [])
        #expect(try savedLanes(singleton) == nil, "no width quote: the setup saves no width, as before")
        // Every Mac admits each width's need, and nothing between it and the next wider one.
        for (free, expected) in [(200 * gib, 8), ((needs[6]! + needs[8]!) / 2, 6), ((needs[4]! + needs[6]!) / 2, 4),
                                 ((needs[2]! + needs[4]!) / 2, 2), ((needs[1]! + needs[2]!) / 2, nil)] as [(Int, Int?)] {
            let decided = try decide(home, free: free)
            let chosen = try #require(decided.result.chosen)
            #expect(try savedLanes(decided) == expected, "\(free / gib) GiB free")
            #expect(chosen.mode == .tensorParallel && DistributedAutomaticBatchPlanner.accepts(chosen, requireNow: true))
            // The saved width is priced at its own complete quote, within what each Mac admits now.
            #expect(chosen.ranks.map(\.needBytes).max() == needs[expected ?? 1], "\(free / gib) GiB free")
            #expect(chosen.ranks.allSatisfy { $0.needBytes <= $0.admissibleNowBytes })
            // The placement is the singleton's: leader and split unchanged; only the width is added.
            let alone = try #require(try decide(home, free: free, widths: []).result.chosen)
            #expect(chosen.ranks.map(\.device) == alone.ranks.map(\.device) && chosen.tensorShares == alone.tensorShares)
            #expect(decided.lines.contains("  \(expected ?? 0) independent histories, charged at the quoted request bound on both Macs. "
                + "Stage-rate predictions remain single-request estimates; no batch speed is inferred from the lane count.") == (expected != nil))
        }
        // Both Macs must admit it: the smaller Mac decides.
        #expect(try savedLanes(try decide(home, free: 200 * gib, peerFree: (needs[4]! + needs[6]!) / 2)) == 4)
        // A width the helper did not quote is not offered.
        #expect(try savedLanes(try decide(home, free: 200 * gib, widths: [2, 4])) == 4)
    }

    /// The planning runs on a stack of its own (`ClusterPlanningStack`), so a caller lends `decide` little of its stack,
    /// even for a tensor-parallel width, the deepest the planner goes. On 2026-11-10 a debug build's `decide` used 387 KiB
    /// of this suite's 512 KiB test thread here, and a merge that grew `decide`'s frame by 23 KiB ran the test above out of
    /// stack (SIGBUS).
    @Test func decideLendsItsCallerLittleStack() throws {
        let home = try home()
        let (pair, cap, layout, request) = try fixture()
        let local = try profile(free: 200 * gib), peer = try profile(free: 200 * gib)
        let singleton = try quote(request, lanes: 1)
        let widths = try ClusterPlacementBatchScope.tensorParallelWidths.map { try quote(request, lanes: $0) }
        let link = try #require(ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"]))
        var lanes: Int?
        let used = stackUsed {
            let decided = try? ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
                localProfile: local, peerProfile: peer, layout: layout, tensorAssistantQuote: singleton,
                tensorWidthQuotes: widths, leader: "a", link: link, environment: [:], benchDebugBuild: false)
            lanes = decided?.setup.flatMap { setup in
                try? ClusterConfigurationCodec.decode(setup.configurations["a"]!, capability: cap,
                    capabilitySHA256: pair.capabilitySHA256).batchLanes
            }
        }
        #expect(lanes == 8, "the widest width was planned")
        #expect(used < planningCallerStackBudget, "decide used \(used) bytes of its caller's stack")
    }

    @Test func anAssistedOwnerIsSizedAtItsOwnQuote() throws {
        let home = try home()
        let assistant = try ClusterPlacementTensorAssistantQuote(policy: .init(depth: 3, inventorySHA256: hash("8"),
            verification: .admittedCohort), residentBytes: gib, loadBytes: 2 * gib, largestAllocationBytes: gib)
        let decided = try decide(home, free: 200 * gib, assistant: assistant)
        #expect(try savedLanes(decided) == 8)
        let (pair, cap, _, _) = try fixture()
        let saved = try ClusterConfigurationCodec.decode(try #require(decided.setup?.configurations["a"]), capability: cap,
            capabilitySHA256: pair.capabilitySHA256)
        #expect(saved.tensorAssistant == assistant.policy)
        // A width of another assistant (or none) is not this owner's.
        let (_, _, layout, request) = try fixture()
        var policy = ClusterPlacementPolicy()
        try quote(request, lanes: 1, assistant: assistant).applySingleton(to: &policy, layout: layout)
        #expect(throws: (any Error).self) { try self.quote(request, lanes: 8).applyWidth(to: &policy, layout: layout) }
        #expect(throws: (any Error).self) { try self.quote(request, lanes: 1, assistant: assistant).applyWidth(to: &policy, layout: layout) }
    }

    /// A row whose pipeline stays a candidate is sized the same way, and its plan keeps the reason its mode was chosen
    /// for one request (its comparison with the pipeline); only the chosen placement's memory is the width's.
    @Test func aRowWhosePipelineStaysACandidateKeepsItsModeReason() throws {
        let home = try home(), row = Self.nineB
        let alone = try decide(home, free: 200 * gib, widths: [], row: row)
        let sized = try decide(home, free: 200 * gib, row: row)
        #expect(alone.result.chosen?.mode == .tensorParallel && alone.result.modesReason == nil)
        #expect(try savedLanes(sized, row: row) == 8)
        let reason = try #require(ClusterPlacementExplanation.deploymentReason(sized.result))
        #expect(reason == ClusterPlacementExplanation.deploymentReason(alone.result) && !reason.contains("left out"), "\(reason)")
        #expect(sized.lines.contains("  " + reason))
        let need = { (decision: ClusterSetupPlanning.PlacementDecision) in decision.result.chosen?.ranks.map(\.needBytes).max() ?? 0 }
        #expect(need(sized) > need(alone))
    }

    /// GLM tensor parallel keeps its own default; a pipeline, and a Qwen TP setup saved without a width, keep theirs.
    @Test func otherFamiliesAndUnsizedSetupsKeepTheirLanes() throws {
        typealias Plan = DistributedInstalledPlan
        #expect(Plan.defaultBatchLanes(adapter: .glm5NextLayerStage, mode: .tensorParallel, hasPrivateImages: false) == 8)
        #expect(Plan.defaultBatchLanes(adapter: .qwen35Dense, mode: .tensorParallel, hasPrivateImages: false,
            runtimeModelID: "registered_qwen38_27b") == 1)
        #expect(Plan.defaultBatchLanes(adapter: .qwen35Dense, mode: .pipeline, hasPrivateImages: false) == Plan.defaultBatchLanes)
        // Only a placement priced by its owner's singleton quote is sized: without one, width quotes change nothing.
        let home = try home()
        let (pair, cap, layout, request) = try fixture()
        let unquoted = try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
            localProfile: profile(free: 200 * gib), peerProfile: profile(free: 200 * gib), layout: layout,
            tensorWidthQuotes: try [8].map { try quote(request, lanes: $0) },
            leader: "a", link: try #require(ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])),
            environment: [:], benchDebugBuild: false)
        #expect(unquoted.result.chosen?.mode == .tensorParallel)
        #expect(try savedLanes(unquoted) == nil)
    }

    /// A pair saved for coordinator pairing serves the width its placement saved, on both Macs, from its first start:
    /// the approval is saved beside it unchanged, no approval or committed-start digest names it (only the setup's own
    /// bytes do), and the automatic replacement never plans for a setup saved with an approval.
    @Test func aCoordinatorPairKeepsTheWidthItsSetupSavedThroughApproval() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider",
                                           shape: .qwen27TensorParallel(assistant: nil, lanes: 8))
        let approval = macs.approval(), facts = try macs.facts()
        #expect(macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts).changed)
        let epoch = UUID()
        for mac in macs.macs {
            let saved = try macs.saved(mac), configuration = saved.configuration
            #expect(configuration.nativeMember?.clusterApproval == approval && configuration.batchLanes == 8, "rank \(mac.rank)")
            let plan = try DistributedInstalledPlan(saved: saved, paths: mac.paths)
            #expect(plan.batchLanes([:]) == 8 && plan.lanesRetireAlone([:]), "rank \(mac.rank)")
            #expect(plan.nativeEnvironment(matrix: URL(fileURLWithPath: "/fixture/matrix.json"), ownerEnvironment: [:])[
                DistributedInstalledPlan.batchLanesSwitch] == "8", "rank \(mac.rank)")
            // The same setup without the width: every approval and committed-start digest is the same; only the
            // setup's own bytes (its digest) differ.
            let bytes = try ClusterConfigurationCodec.encode(configuration, capability: saved.capability,
                capabilitySHA256: configuration.capabilitySHA256)
            var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            object.removeValue(forKey: "batchLanes")
            let unsizedBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let unsized = try ClusterConfigurationCodec.decode(unsizedBytes, capability: saved.capability,
                capabilitySHA256: configuration.capabilitySHA256)
            let other = try DistributedInstalledPlan(saved: .init(configuration: unsized, capability: saved.capability), paths: mac.paths)
            #expect(other.batchLanes([:]) == 1)
            #expect(try DistributedInstalledNativeStart.common(plan: plan, epoch: epoch).canonicalBytes
                == DistributedInstalledNativeStart.common(plan: other, epoch: epoch).canonicalBytes, "rank \(mac.rank)")
            #expect(DistributedInstalledNativeStart.runtimeBlock(plan: plan) == DistributedInstalledNativeStart.runtimeBlock(plan: other))
            #expect(ClusterConfigurationCodec.sha256(bytes) != ClusterConfigurationCodec.sha256(
                try ClusterConfigurationCodec.encode(unsized, capability: saved.capability, capabilitySHA256: configuration.capabilitySHA256)))
        }
        // Queued demand never re-plans an approved setup: the coordinator-approved contract stays as approved.
        let reference = try ClusterConfigurationStore.installedReference(providerConfiguration: macs.leader.provider)
        let planner = DistributedAutomaticBatchPlanner(providerConfiguration: macs.leader.provider, paths: macs.leader.paths)
        let queued = DistributedLocalBatchDemand(generationID: UUID(), waitingRequests: 8, activeRequests: 8, currentCapacity: 8,
            publicModelID: ClusterApprovalMacs.model, runtimeModelID: macs.capability.runtimeModelID,
            artifactSHA256: macs.capability.artifactSHA256, configurationSHA256: macs.capability.configurationSHA256,
            maximumPromptTokens: 32768, maximumOutputTokens: 32768, maximumContextTokens: 65536, requestTimeout: .seconds(300))
        #expect(try planner.snapshot(reference: reference, demand: queued, widths: [8], requireNow: true) == nil)
    }

    /// A Gemma 4 tensor-parallel pair serves the width its setup saved on both Macs, from its first start: both owners'
    /// lanes (the number the setup screen, the slot's `max_concurrency` and the local API admit), a started lane
    /// retiring alone, and both ranks' launch.
    @Test func aGemmaTensorParallelPairServesTheWidthItsSetupSaved() throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider", shape: .gemma4TensorParallel(lanes: 8))
        for mac in macs.macs {
            let saved = try macs.saved(mac)
            #expect(saved.configuration.batchLanes == 8 && saved.configuration.selectedGenerationMode == .tensorParallel,
                "rank \(mac.rank)")
            let plan = try DistributedInstalledPlan(saved: saved, paths: mac.paths)
            #expect(plan.batchLanes([:]) == 8 && plan.lanesRetireAlone([:]), "rank \(mac.rank)")
            #expect(plan.nativeEnvironment(matrix: URL(fileURLWithPath: "/fixture/matrix.json"), ownerEnvironment: [:])[
                DistributedInstalledPlan.batchLanesSwitch] == "8", "rank \(mac.rank)")
        }
        // Without a saved width it serves one request at a time.
        let unsized = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider", shape: .gemma4TensorParallel(lanes: nil))
        let plan = try DistributedInstalledPlan(saved: try unsized.saved(unsized.leader), paths: unsized.leader.paths)
        #expect(plan.batchLanes([:]) == 1 && !plan.lanesRetireAlone([:]))
    }

    private func demand(capacity: Int, active: Int, waiting: Int, model: String = "registered_qwen38_27b") -> DistributedLocalBatchDemand {
        .init(generationID: UUID(), waitingRequests: waiting, activeRequests: active, currentCapacity: capacity,
            publicModelID: "fixture-model", runtimeModelID: model, artifactSHA256: hash("b"), configurationSHA256: hash("c"),
            maximumPromptTokens: 32768, maximumOutputTokens: 32768, maximumContextTokens: 65536, requestTimeout: .seconds(315))
    }

    /// A pair placed at its widest admitted width is never drained for it; one placed narrower still widens past it.
    @Test func aLocalPairWidensByReplacementOnlyPastItsSavedWidth() {
        typealias Factory = DistributedAutomaticBatchFactory
        #expect(Factory.replacementWidths(for: demand(capacity: 8, active: 8, waiting: 8)).isEmpty)
        #expect(Factory.replacementWidths(for: demand(capacity: 6, active: 6, waiting: 2)) == [8])
        #expect(Factory.replacementWidths(for: demand(capacity: 4, active: 4, waiting: 4)) == [8, 6])
        #expect(Factory.replacementWidths(for: demand(capacity: 1, active: 1, waiting: 7)) == [8, 6, 4, 2])
        #expect(Factory.replacementWidths(for: demand(capacity: 4, active: 4, waiting: 0)).isEmpty)
        // A row without a request-owned TP owner keeps the pipeline's priced widths.
        #expect(Factory.replacementWidths(for: demand(capacity: 1, active: 1, waiting: 7, model: "fixture_pipeline_model")) == [8, 4, 2])
    }

    // MARK: - A family priced by its lane charge (Gemma 4)

    private static let gemmaQATRow: Row = ("registered_gemma4_26b_qat_4bit", "registered_gemma4_26b_qat_4bit_greedy_generation_v1")
    private static let gemma8BitRow: Row = ("registered_gemma4_26b_8bit", "registered_gemma4_26b_8bit_greedy_generation_v1")

    /// Gemma 4 tensor parallel's identity (the QAT 4-bit row unless `row` names another) on the constructed two-layer
    /// layout, equal shares only. Its family reserves 3 GiB a rank at LOAD for one request and the rank's reserve
    /// (`requestAllowance`), and each lane after the first adds `laneBytes`, which the layout states as the native plan
    /// tool writes it; nil states none. `fastest`: as the real Gemma layout and worker record are, the family is placed
    /// in tensor parallel only where it is faster (`ClusterTensorParallelChoice.fastest`), and both modes declare the
    /// same serving features (`ClusterModeParity`).
    private func gemmaFixture(laneBytes: Int?, row: Row = gemmaQATRow, fastest: Bool = false)
        throws -> (ClusterPairDescription, ClusterRuntimeCapability, ClusterModelLayout) {
        let (pair, _, qwenLayout, _) = try fixture()
        let model = row.model
        let allowance = try ClusterTensorParallelRequestAllowance(maximumContextTokens: 65536, maximumChunkTokens: 512,
            requestBytesExcludingCollectives: 3 * gib, maximumCollectivePayloadBytes: 512 * 4096,
            maximumCollectiveFrameBytes: 512 * 4096 + 1024, allocationBound: { (($0 + 16383) / 16384) * 16384 })
        let tensor = ClusterTensorParallelLayout(family: .init(plan: "fixture-heads", ranks: [2], reductionsPerLayer: 1,
            reductionsPerStep: 0, partialBytesPerToken: 4096, stateDividesByHeads: true, requestAllowance: allowance,
            choice: fastest ? .fastest : nil),
            layerDividedBytes: [2 * gib, 2 * gib], layerReplicatedBytes: [0, 0],
            ingressDividedBytes: 0, ingressReplicatedBytes: gib / 2, egressDividedBytes: gib / 2, egressReplicatedBytes: 0)
        var tensorObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tensor)) as! [String: Any]
        var family = tensorObject["family"] as! [String: Any]
        family["laneBytes"] = laneBytes
        tensorObject["family"] = family
        var object = try JSONSerialization.jsonObject(with: qwenLayout.encoded()) as! [String: Any]
        object["runtimeModelID"] = model
        object["tensorParallel"] = tensorObject
        let layout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
        let cap = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: ClusterRuntimeAdapter.gemma4LayerStage.rawValue,
            adapterVersion: 1, runtimeModelID: model, artifactSHA256: hash("b"), configurationSHA256: hash("c"), manifestSHA256: hash("d"),
            profile: .init(id: row.profile, vocabularySize: 262144,
                maximumPromptTokens: 32768, maximumOutputTokens: 32768, maximumChunkTokens: 512, maximumContextTokens: 65536),
            profileFingerprint: hash("e"), partitions: [.init(planSHA256: hash("f"), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 1, stagePlanSHA256: hash("1"), constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: 1, sourceLayerEnd: 2, stagePlanSHA256: hash("3"), constructionConfigurationSHA256: hash("4"))])],
            arithmeticPolicyID: ClusterRuntimeAdapter.gemma4LayerStage.arithmeticPolicyID, arithmeticPolicySHA256: hash("5"),
            supportedGenerationModes: [.pipeline, .tensorParallel], modeFeatures: fastest ? [
                .pipeline: .init(promptPrefixReuse: true, ssdPrefixTier: true, speculativeRounds: false, maximumLanes: 8, logprobs: false),
                .tensorParallel: .init(promptPrefixReuse: true, ssdPrefixTier: true, speculativeRounds: false, maximumLanes: 8, logprobs: true),
            ] : nil)
        let capHash = ClusterConfigurationCodec.sha256(try ClusterRuntimeCapabilityCodec.encode(cap))
        let gemmaPair = ClusterPairDescription(schema: pair.schema, clusterID: pair.clusterID, publicModelID: "fixture-gemma",
            capabilitySHA256: capHash, chunkTokens: pair.chunkTokens, requestTimeoutSeconds: pair.requestTimeoutSeconds,
            coordinatorPort: pair.coordinatorPort, members: pair.members, tokenizerFiles: pair.tokenizerFiles,
            linkControl: pair.linkControl)
        return (gemmaPair, cap, layout)
    }

    private func decideGemma(_ home: URL, free: Int, peerFree: Int? = nil, laneBytes: Int? = 2 * 1_073_741_824,
                             row: Row = gemmaQATRow, fastest: Bool = false,
                             incumbentMode: ClusterGenerationMode? = nil) throws -> ClusterSetupPlanning.PlacementDecision {
        let (pair, cap, layout) = try gemmaFixture(laneBytes: laneBytes, row: row, fastest: fastest)
        return try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
            localProfile: profile(free: free), peerProfile: profile(free: peerFree ?? free), layout: layout, leader: "a",
            link: try #require(ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])),
            incumbentMode: incumbentMode, environment: [:], benchDebugBuild: false)
    }

    /// What both Macs saved and what the setup screen then says the pair serves at once (`ClusterSetupPlanning.loads`,
    /// the number the slot's `max_concurrency` and both owners read): equal, or the test fails.
    private func gemmaLanes(_ decision: ClusterSetupPlanning.PlacementDecision, row: Row = gemmaQATRow,
                            fastest: Bool = false) throws -> (saved: Int?, screen: Int?) {
        let (pair, cap, _) = try gemmaFixture(laneBytes: nil, row: row, fastest: fastest)
        let setup = try #require(decision.setup)
        let saved = try ["a", "b"].map { member in
            try ClusterConfigurationCodec.decode(try #require(setup.configurations[member]), capability: cap,
                capabilitySHA256: pair.capabilitySHA256)
        }
        #expect(saved[0].batchLanes == saved[1].batchLanes, "both Macs save one width")
        let data = try ClusterRuntimeCapabilityCodec.encode(cap)
        let screen = ClusterSetupPlanning.loads(try #require(decision.result.chosen), setup: setup, localMemberID: "a",
            capability: (cap, data, pair.capabilitySHA256)).concurrentRequests
        #expect(screen == DistributedInstalledPlan.batchLanes(configuration: saved[0], capability: cap, environment: [:]))
        return (saved[0].batchLanes, screen)
    }

    /// The width `ClusterPlacementTensorWidth` sizes the Gemma placement at with a cap of eight, on two Macs that each
    /// admit `free` now, and that plan.
    private func gemmaWidest(_ home: URL, free: Int) throws -> (lanes: Int?, plan: ClusterPlacementCandidate) {
        let (_, _, layout) = try gemmaFixture(laneBytes: 2 * gib)
        let devices = try ["a", "b"].map { ClusterPlacementDevice(label: $0, profile: try profile(free: free), speed: .assumedEqual) }
        var policy = ClusterPlacementPolicy()
        policy.modes = [.tensorParallel]
        var lanes: Int?
        let result = try ClusterPlacementTensorWidth.plan(devices: devices, layout: layout, policy: policy,
            link: try #require(ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])), quotes: [],
            maximumLanes: 8, lanes: &lanes)
        return (lanes, try #require(result.chosen))
    }

    /// Gemma 4 tensor parallel saves the widest width both Macs admit now, up to the width the M5 Ultra pair qualified
    /// for its row (`ClusterPlacementTensorWidth.qualifiedLanes`), and the setup screen says that number; where only one
    /// request fits it saves none and says one. A width is priced as its LOAD reserves it: each lane after the first adds
    /// the family's lane charge to every rank's request need, and the whole reservation (the allowance and those
    /// charges) is held while the shard is read, so it is in the load peak too.
    @Test func aGemmaTensorParallelPlacementSavesTheWidestWidthItsLaneChargeAdmitsNow() throws {
        let home = try home(), lane = 2 * gib
        #expect(ClusterPlacementTensorWidth.qualifiedLanes(adapter: .gemma4LayerStage, runtimeModelID: Self.gemmaQATRow.model) == 2)
        let alone = try #require(try decideGemma(home, free: 200 * gib, laneBytes: nil).result.chosen)
        #expect(alone.mode == .tensorParallel)
        let (_, _, layout) = try gemmaFixture(laneBytes: lane)
        let allowance = try #require(layout.tensorParallel?.family.requestAllowance).reservedBytes
        func need(_ lanes: Int) -> Int {
            alone.ranks.map { rank in
                lanes == 1 ? rank.needBytes
                    : max(rank.needBytes + (lanes - 1) * lane, rank.loadNeedBytes + allowance + (lanes - 1) * lane)
            }.max()!
        }
        #expect(need(2) > need(1) + lane, "the load peak holds the whole reservation")
        // Up to eight, every width both Macs admit, and nothing between it and the next wider one.
        for (free, expected) in [(200 * gib, 8), ((need(6) + need(8)) / 2, 6), ((need(4) + need(6)) / 2, 4),
                                 ((need(2) + need(4)) / 2, 2), ((need(1) + need(2)) / 2, nil)] as [(Int, Int?)] {
            let sized = try gemmaWidest(home, free: free)
            #expect(sized.lanes == expected, "\(free / gib) GiB free")
            #expect(sized.plan.mode == .tensorParallel && sized.plan.admitted(requireNow: true))
            #expect(sized.plan.ranks.map(\.needBytes).max() == need(expected ?? 1), "\(free / gib) GiB free")
            #expect(sized.plan.ranks.allSatisfy { $0.needBytes <= $0.admissibleNowBytes })
        }
        // The setup saves at most the qualified width.
        for (free, expected) in [(200 * gib, 2), ((need(2) + need(4)) / 2, 2), ((need(1) + need(2)) / 2, nil)] as [(Int, Int?)] {
            let decided = try decideGemma(home, free: free)
            let chosen = try #require(decided.result.chosen)
            let lanes = try gemmaLanes(decided)
            #expect(lanes.saved == expected && lanes.screen == (expected ?? 1), "\(free / gib) GiB free")
            #expect(chosen.mode == .tensorParallel && chosen.admitted(requireNow: true))
            #expect(chosen.ranks.map(\.needBytes).max() == need(expected ?? 1), "\(free / gib) GiB free")
            // The singleton's placement: leader and split unchanged.
            #expect(chosen.ranks.map(\.device) == alone.ranks.map(\.device) && chosen.tensorShares == alone.tensorShares)
        }
        // Both Macs must admit it: the smaller Mac decides.
        #expect(try gemmaLanes(try decideGemma(home, free: 200 * gib, peerFree: (need(1) + need(2)) / 2)).saved == nil)
        // A layout that states no lane charge prices no width: the setup saves none and serves one request at a time.
        let unpriced = try gemmaLanes(try decideGemma(home, free: 200 * gib, laneBytes: nil))
        #expect(unpriced.saved == nil && unpriced.screen == 1)
    }

    /// Only the row the pair qualified saves a width: the 8-bit rows run the same lanes on kernels nothing qualified at
    /// these widths, so they serve one request at a time.
    @Test func aGemmaRowThePairDidNotQualifySavesNoWidth() throws {
        let home = try home(), row = Self.gemma8BitRow
        #expect(ClusterPlacementTensorWidth.qualifiedLanes(adapter: .gemma4LayerStage, runtimeModelID: row.model) == 1)
        let decided = try decideGemma(home, free: 200 * gib, row: row)
        #expect(decided.result.chosen?.mode == .tensorParallel)
        let lanes = try gemmaLanes(decided, row: row)
        #expect(lanes.saved == nil && lanes.screen == 1)
    }

    /// A sized plan keeps the reasons its mode was chosen for one request. After an update the pair keeps the mode it
    /// served (`ClusterServedModes.hold`), here tensor parallel ahead of a pipeline its share steps were not measured
    /// against; the width is priced in tensor parallel alone, where nothing is held, so only the singleton's plan
    /// carries why.
    @Test func aSizedPlanKeepsTheSingletonsReasons() throws {
        let home = try home()
        let alone = try decideGemma(home, free: 200 * gib, laneBytes: nil, fastest: true, incumbentMode: .tensorParallel)
        let sized = try decideGemma(home, free: 200 * gib, fastest: true, incumbentMode: .tensorParallel)
        #expect(alone.result.chosen?.mode == .tensorParallel && sized.result.chosen?.mode == .tensorParallel)
        #expect(try gemmaLanes(sized, fastest: true).saved == 2)
        let kept = try #require(alone.result.keptModeReason)
        #expect(kept.hasPrefix("kept after the update"), "\(kept)")
        #expect(sized.result.keptModeReason == kept && sized.result.modesReason == alone.result.modesReason)
        let reason = try #require(ClusterPlacementExplanation.deploymentReason(sized.result))
        #expect(reason == ClusterPlacementExplanation.deploymentReason(alone.result), "\(reason)")
    }
}
