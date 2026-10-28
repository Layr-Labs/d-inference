import Darwin
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// CPU metadata only. Constructed profiles and measurements exercise the
/// production replacement decision; none is a hardware performance result.
@Suite(.serialized)
final class DistributedAutomaticBatchPlannerTests {
    private var temporaryHomes: [URL] = []
    deinit { for home in temporaryHomes { try? FileManager.default.removeItem(at: home) } }
    private let gib = 1_073_741_824
    private func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    private func home() throws -> URL {
        let result = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("automatic-batch-inputs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        temporaryHomes.append(result)
        return result
    }

    private func profile(free: Int = 200 * 1_073_741_824, decodeIndex: Double = 25_000,
                         osBuild: String = "CHECK") throws -> ClusterDeviceProfile {
        let physical = 256 * gib
        var p = try ClusterDeviceProfile(chip: "Constructed planner fixture", performanceCores: 8, efficiencyCores: 4,
            gpuCores: 40, osVersion: "27.0", osBuild: osBuild, physicalMemoryBytes: physical,
            gpuRecommendedWorkingSetBytes: 192 * gib, gpuMaximumBufferBytes: 128 * gib,
            allocatorLimitBytes: 230 * gib,
            memory: .init(gatePolicy: "fixture", sampledUTC: "2026-10-23T00:00:00Z", judged: true, unjudgedReason: nil,
                physicalMemoryBytes: physical, actualFreeBytes: free, countedFileCacheBytes: 0, admissibleNowBytes: free,
                fileBackedBytes: 0, fileCacheReserveBytes: 0, fileCacheAboveReserveBytes: 0, anonymousBytes: physical - free - 4 * gib,
                wiredBytes: 4 * gib, compressorBytes: 0, pageableBytes: 252 * gib, pressureLevel: 1, swapUsedBytes: 0,
                minimumAdmissibleBytes: 6 * gib, minimumTrulyFreeBytes: 16 * 1_048_576, loadingHeadroomBytes: 4 * gib,
                allocatorHeadroomBytes: 2 * gib, loadScratchBytes: 8 * 1_048_576, pageSizeBytes: 16_384),
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
        p.speedIndex = .init(chip: p.chip, osBuild: p.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: 1_000_000, decodeIndex: decodeIndex)
        return p
    }

    private func fixture() throws -> (ClusterPairDescription, ClusterRuntimeCapability, ClusterModelLayout, ClusterPlacementBatchScope) {
        let model = "registered_qwen38_27b"
        let part = ClusterModelLayout.Part(storedBytes: 2 * gib, loadedBytes: 2 * gib, largestTensorBytes: gib / 4, tensorCount: 16)
        let end = ClusterModelLayout.Part(storedBytes: gib / 2, loadedBytes: gib / 2, largestTensorBytes: gib / 2, tensorCount: 1)
        let raw = ClusterModelLayout(runtimeModelID: model, artifactSHA256: hash("b"), configurationSHA256: hash("c"),
            layers: (0..<2).map { .init(index: $0, kind: "fixture", weights: part, stateFixedBytes: 1024,
                stateBytesPerToken: 1024, cost: 1) }, ingress: end, egress: end, excluded: .init(), admittedCuts: [1],
            structuralCuts: [1], generationModes: [.pipeline, .tensorParallel], prefillSchedules: [.serial],
            maximumPromptTokens: 1024, maximumOutputTokens: 128, maximumChunkTokens: 128,
            boundaryBytesPerToken: 4096, requestChargeEveryRankBytes: gib)
        let tensor = ClusterTensorParallelLayout(family: .init(plan: "fixture-heads", ranks: [2], reductionsPerLayer: 1,
            reductionsPerStep: 0, partialBytesPerToken: 4096, stateDividesByHeads: true),
            layerDividedBytes: [2 * gib, 2 * gib], layerReplicatedBytes: [0, 0],
            ingressDividedBytes: 0, ingressReplicatedBytes: gib / 2, egressDividedBytes: gib / 2, egressReplicatedBytes: 0)
        var object = try JSONSerialization.jsonObject(with: raw.encoded()) as! [String: Any]
        object["tensorParallel"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tensor))
        let layout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
        let cap = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: "qwen35-dense-layer-stage", adapterVersion: 1,
            runtimeModelID: model, artifactSHA256: hash("b"), configurationSHA256: hash("c"), manifestSHA256: hash("d"),
            profile: .init(id: "registered_qwen38_27b_greedy_generation_v1", vocabularySize: 248320,
                maximumPromptTokens: 32768, maximumOutputTokens: 32768, maximumChunkTokens: 512, maximumContextTokens: 65536),
            profileFingerprint: hash("e"), partitions: [.init(planSHA256: hash("f"), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 1, stagePlanSHA256: hash("1"), constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: 1, sourceLayerEnd: 2, stagePlanSHA256: hash("3"), constructionConfigurationSHA256: hash("4"))])],
            arithmeticPolicyID: "qwen_cbv2_query128_bf16_tf32_default_v1", arithmeticPolicySHA256: hash("5"), supportedGenerationModes: [.pipeline, .tensorParallel])
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
        let quote = try ClusterPlacementTensorBatchQuote(request: request, lanes: 4, chunkTokens: 128,
            perLaneStateBytes: gib, sharedBytesExcludingCollectives: gib,
            allowance: .init(maximumContextTokens: 65536, maximumChunkTokens: 512, requestBytesExcludingCollectives: 5 * gib,
                maximumCollectivePayloadBytes: 4 * 248320 * 4, maximumCollectiveFrameBytes: 4 * 248320 * 4 + 1024,
                allocationBound: { (($0 + 16383) / 16384) * 16384 }))
        return (pair, cap, layout, try ClusterPlacementBatchScope(request: request, lanes: 4, tensorParallelQuote: quote))
    }

    private func decide(_ home: URL) throws -> (lines: [String], result: ClusterPlacementResult, setup: ClusterPlacementSetup?) {
        let (pair, cap, layout, scope) = try fixture()
        return try DistributedAutomaticBatchPlanner.decide(description: pair, capability: cap, localMemberID: "a",
            localProfile: profile(), peerProfile: profile(), layout: layout, scope: scope, homeDirectory: home)
    }

    private func record(_ home: URL, members: [String] = ["a", "b"], keyed: Bool = true,
                        now: Double = Date().timeIntervalSince1970) {
        let probe = ClusterWorkerLinkProbe(transport: "jaccl", keyed: keyed, pointToPointSmallBytes: 4096,
            pointToPointSmallMicroseconds: 1, pointToPointLargeBytes: 1_048_576, pointToPointLargeMicroseconds: 10,
            allSumSmallBytes: 4096, allSumSmallMicroseconds: 1, allSumLargeBytes: 1_048_576, allSumLargeMicroseconds: 10)
        #expect(ClusterLinkProbeHistory.record(probe, members: members, homeDirectory: home, now: now))
    }

    /// Three records of the leader's served-speed file, as the product writes it. `builds`: each rank's worker build;
    /// nil writes a record as an earlier build did, without any. The fixture's pair runs build hash("a").
    private func writeServed(_ home: URL, model: String = "fixture-model", ranks: [String] = ["a", "b"], concurrent: Int = 0,
                             cached: Int = 0, prompt: Int = 1024, completion: Int = 128, builds: [String]?) throws {
        let records = (0..<3).map { index in
            ClusterPairRequestTelemetry(requestID: "fixture-\(index)", finishedAt: Date().timeIntervalSince1970,
                modelID: model, mode: "tensor_parallel_v1", cut: "0-2|0-2", promptTokens: prompt, cachedTokens: cached,
                completionTokens: completion, firstTokenMilliseconds: 1000, decodeTokensPerSecond: 1,
                handoffMilliseconds: nil, handoffBytes: nil, mtpDrafted: nil, mtpAccepted: nil, outcome: "length",
                route: "pair", ranks: ranks, concurrentRequests: concurrent, rankBuildSHA256: builds)
        }
        let json: [String: Any] = ["schema": ClusterServedSpeedFile.schemaName, "updatedAt": Date().timeIntervalSince1970,
            "records": try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))]
        let file = ClusterServedSpeedFile.defaultFile(homeDirectory: home)
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    @Test func profileEnvelopeSingletonQuoteCoversThePlannedReference() throws {
        let home = try home(); record(home)
        let (pair, cap, layout, _) = try fixture()
        // Automatic discovery prices the native profile's envelope, which exceeds
        // the layout's planned request (installed Qwen27: 32768/32768 vs 8192/128).
        let envelope = try ClusterPlacementRequestScope(runtimeModelID: cap.runtimeModelID,
            artifactSHA256: cap.artifactSHA256, configurationSHA256: cap.configurationSHA256,
            promptTokens: cap.profile.maximumPromptTokens, outputTokens: cap.profile.maximumOutputTokens,
            maximumPromptTokens: cap.profile.maximumPromptTokens, maximumOutputTokens: cap.profile.maximumOutputTokens,
            maximumContextTokens: cap.profile.maximumContextTokens, requestChargeEveryRankBytes: gib)
        #expect(envelope.promptTokens != layout.maximumPromptTokens || envelope.outputTokens != layout.maximumOutputTokens)
        let quote = try ClusterPlacementTensorBatchQuote(request: envelope, lanes: 1, chunkTokens: 128,
            perLaneStateBytes: gib, sharedBytesExcludingCollectives: gib,
            allowance: .init(maximumContextTokens: 65536, maximumChunkTokens: 512,
                requestBytesExcludingCollectives: 2 * gib,
                maximumCollectivePayloadBytes: 512 * 4096, maximumCollectiveFrameBytes: 512 * 4096 + 1024,
                allocationBound: { (($0 + 16383) / 16384) * 16384 }))
        let decided = try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
            localProfile: profile(), peerProfile: profile(), layout: layout, tensorAssistantQuote: quote,
            leader: "a", link: ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])!,
            environment: [:], benchDebugBuild: false)
        #expect(decided.result.chosen?.mode == .tensorParallel && decided.setup != nil)
        // Memory is charged for the envelope; speed and shares keep the planned request.
        #expect(decided.result.promptTokens == layout.maximumPromptTokens && decided.result.outputTokens == layout.maximumOutputTokens)
        // An envelope that does not cover the reference request is refused.
        let short = try ClusterPlacementRequestScope(runtimeModelID: cap.runtimeModelID,
            artifactSHA256: cap.artifactSHA256, configurationSHA256: cap.configurationSHA256,
            promptTokens: layout.maximumPromptTokens / 2, outputTokens: layout.maximumOutputTokens / 2,
            maximumPromptTokens: cap.profile.maximumPromptTokens, maximumOutputTokens: cap.profile.maximumOutputTokens,
            maximumContextTokens: cap.profile.maximumContextTokens, requestChargeEveryRankBytes: gib)
        let shortQuote = try ClusterPlacementTensorBatchQuote(request: short, lanes: 1, chunkTokens: 128,
            perLaneStateBytes: gib, sharedBytesExcludingCollectives: gib, allowance: quote.allowance)
        #expect(throws: (any Error).self) {
            try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
                localProfile: profile(), peerProfile: profile(), layout: layout, tensorAssistantQuote: shortQuote,
                leader: "a", link: ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])!,
                environment: [:], benchDebugBuild: false)
        }
    }

    @Test func singletonQuoteCoversTheServedReferenceOnAPairWithServedHistory() throws {
        let home = try home(); record(home)
        let (pair, cap, layout, scope) = try fixture()
        // Served requests unlike the quoted envelope: before the fix the served
        // mix replaced the reference and the quote's scope refused planning.
        // Served by the pair's own worker build, so the plan takes them.
        try writeServed(home, model: pair.publicModelID, prompt: 700, completion: 90, builds: [hash("a"), hash("a")])
        let served = ClusterServedSpeedHistory.entries(homeDirectory: home)
        #expect(!served.isEmpty)
        #expect(scope.request.promptTokens != 700 || scope.request.outputTokens != 90)
        let quote = try ClusterPlacementTensorBatchQuote(request: scope.request, lanes: 1, chunkTokens: 128,
            perLaneStateBytes: gib, sharedBytesExcludingCollectives: gib,
            allowance: .init(maximumContextTokens: 65536, maximumChunkTokens: 512,
                requestBytesExcludingCollectives: 2 * gib,
                maximumCollectivePayloadBytes: 512 * 4096, maximumCollectiveFrameBytes: 512 * 4096 + 1024,
                allocationBound: { (($0 + 16383) / 16384) * 16384 }))
        let decided = try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
            localProfile: profile(), peerProfile: profile(), layout: layout, tensorAssistantQuote: quote,
            leader: "a", served: served, link: ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])!,
            environment: [:], benchDebugBuild: false)
        #expect(decided.result.chosen?.mode == .tensorParallel && decided.setup != nil)
        // The served mix stays the reference; the quote's envelope covers it.
        #expect(decided.result.promptTokens == 700 && decided.result.outputTokens == 90)
    }

    @Test func plainSingletonQuoteAndRetainedGeometryUseCompleteMemoryGates() throws {
        let home = try home(); record(home)
        let (pair, cap, originalLayout, scope) = try fixture()
        var object = try JSONSerialization.jsonObject(with: originalLayout.encoded()) as! [String: Any]
        var tensor = object["tensorParallel"] as! [String: Any]
        var family = tensor["family"] as! [String: Any]
        family["shareOptions"] = [[1, 2], [2, 1]]
        tensor["family"] = family; object["tensorParallel"] = tensor
        let layout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
        let plain = try ClusterPlacementTensorBatchQuote(request: scope.request, lanes: 1, chunkTokens: 128,
            perLaneStateBytes: gib, sharedBytesExcludingCollectives: gib,
            allowance: .init(maximumContextTokens: 65536, maximumChunkTokens: 512,
                requestBytesExcludingCollectives: 2 * gib,
                maximumCollectivePayloadBytes: 512 * 4096, maximumCollectiveFrameBytes: 512 * 4096 + 1024,
                allocationBound: { (($0 + 16383) / 16384) * 16384 }))
        let first = try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
            localProfile: profile(), peerProfile: profile(), layout: layout, tensorAssistantQuote: plain,
            leader: "a", link: ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])!,
            environment: [:], benchDebugBuild: false)
        #expect(first.result.chosen?.mode == .tensorParallel && first.setup != nil)
        for bytes in try #require(first.setup).configurations.values {
            let config = try ClusterConfigurationCodec.decode(bytes, capability: cap, capabilitySHA256: pair.capabilitySHA256)
            #expect(config.tensorAssistant == nil && (config.batchLanes ?? 1) == 1)
        }
        func replacement(_ shares: [Int]?, free: Int = 200 * 1_073_741_824) throws
            -> (lines: [String], result: ClusterPlacementResult, setup: ClusterPlacementSetup?) {
            try DistributedAutomaticBatchPlanner.decide(description: pair, capability: cap, localMemberID: "a",
                localProfile: profile(free: free), peerProfile: profile(), layout: layout,
                scope: scope, homeDirectory: home, incumbentTensorShares: shares)
        }
        let oldChoice = try replacement(nil), held = try replacement([1, 2])
        let old = try #require(oldChoice.result.chosen), retained = try #require(held.result.chosen)
        #expect((old.tensorShares ?? [1, 1]) != [1, 2], "negative control: re-ranking can change the arithmetic split")
        #expect(retained.tensorShares == [1, 2] && retained.ranks.map(\.device) == ["a", "b"])
        #expect(held.result.alternatives.allSatisfy { $0.tensorShares == [1, 2] })
        #expect(retained.ranks.allSatisfy { $0.requestNeedBytes >= scope.tensorParallelQuote!.allowance.reservedBytes })
        #expect(DistributedAutomaticBatchPlanner.accepts(retained, requireNow: true))
        let blocked = try replacement([1, 2], free: 6 * gib)
        let unavailable = try #require(blocked.result.chosen)
        #expect(unavailable.tensorShares == [1, 2])
        #expect(!DistributedAutomaticBatchPlanner.accepts(unavailable, requireNow: true))
        #expect(throws: (any Error).self) { try replacement([1, 3]) }
        let beforeBytes = try #require(held.setup?.configurations["a"])
        let afterBytes = try #require(oldChoice.setup?.configurations["a"])
        let before = try ClusterConfigurationCodec.decode(beforeBytes, capability: cap, capabilitySHA256: pair.capabilitySHA256)
        let after = try ClusterConfigurationCodec.decode(afterBytes, capability: cap, capabilitySHA256: pair.capabilitySHA256)
        try ClusterAutomaticSetupHandoff.requireCompatible(before, before, runtimeModelID: cap.runtimeModelID)
        #expect(throws: (any Error).self) {
            try ClusterAutomaticSetupHandoff.requireCompatible(before, after, runtimeModelID: cap.runtimeModelID)
        }
    }

    @Test func testRecordedKeyedReductionReachesActualDecisionAndCanSelectTP() throws {
        let home = try home()
        let before = try decide(home)
        #expect(before.result.chosen == nil)
        #expect(before.setup == nil)
        #expect(before.result.tensorParallel?.verdict == .reductionNotMeasured)
        record(home, members: ["b", "a"])
        let after = try decide(home)
        #expect(after.result.tensorParallel?.reductionKeyed == true)
        #expect(after.result.chosen?.mode == .tensorParallel)
        let (_, cap, _, _) = try fixture()
        let setup = try #require(after.setup)
        #expect(setup.configurations.count == 2)
        for bytes in setup.configurations.values {
            let value = try ClusterConfigurationCodec.decode(bytes, capability: cap,
                capabilitySHA256: ClusterConfigurationCodec.sha256(try ClusterRuntimeCapabilityCodec.encode(cap)))
            #expect(value.selectedGenerationMode == .tensorParallel)
            #expect(value.batchLanes == 4)
        }
    }

    @Test func testCurrentFitPreviewRejectsHigherWidthAndKeepsLowerWidthEligible() throws {
        let home = try home(); record(home)
        let (pair, cap, layout, original) = try fixture()
        func scope(_ lanes: Int) throws -> ClusterPlacementBatchScope {
            let payload = max(512 * 4096, lanes * 248320 * 4)
            let quote = try ClusterPlacementTensorBatchQuote(request: original.request, lanes: lanes,
                chunkTokens: 128, perLaneStateBytes: gib, sharedBytesExcludingCollectives: gib,
                allowance: .init(maximumContextTokens: 65536, maximumChunkTokens: 512,
                    requestBytesExcludingCollectives: (lanes + 1) * gib,
                    maximumCollectivePayloadBytes: payload, maximumCollectiveFrameBytes: payload + 1024,
                    allocationBound: { (($0 + 16383) / 16384) * 16384 }))
            return try ClusterPlacementBatchScope(request: original.request, lanes: lanes, tensorParallelQuote: quote)
        }
        func choose(_ lanes: Int, free: Int) throws -> ClusterPlacementCandidate {
            let decision = try DistributedAutomaticBatchPlanner.decide(description: pair, capability: cap,
                localMemberID: "a", localProfile: profile(free: free), peerProfile: profile(), layout: layout,
                scope: scope(lanes), homeDirectory: home)
            return try #require(decision.result.chosen)
        }
        let two = try choose(2, free: 200 * gib), four = try choose(4, free: 200 * gib)
        let eight = try choose(8, free: 200 * gib)
        let available = (two.ranks[0].needBytes + four.ranks[0].needBytes) / 2
        let currentTwo = try choose(2, free: available), currentFour = try choose(4, free: available)
        #expect(DistributedAutomaticBatchPlanner.accepts(currentFour, requireNow: false))
        #expect(!DistributedAutomaticBatchPlanner.accepts(currentFour, requireNow: true))
        #expect(DistributedAutomaticBatchPlanner.accepts(currentTwo, requireNow: true))
        #expect(currentTwo.mode == .tensorParallel && currentFour.mode == .tensorParallel)
        let widths = ClusterPlacementBatchScope.candidateWidths(waitingRequests: 8)
        #expect(widths == [8, 4, 2])
        for (free, expected) in [(200 * gib, 8),
                                 ((four.ranks[0].needBytes + eight.ranks[0].needBytes) / 2, 4),
                                 (available, 2)] {
            let admitted = try widths.first { lanes in
                DistributedAutomaticBatchPlanner.accepts(try choose(lanes, free: free), requireNow: true)
            }
            #expect(admitted == expected)
        }
        let noWidthFits = two.ranks[0].needBytes - 1
        #expect(try widths.allSatisfy { lanes in
            !DistributedAutomaticBatchPlanner.accepts(try choose(lanes, free: noWidthFits), requireNow: true)
        })
        // These are exact admission capacities, never measured kernel widths.
        #expect(try scope(2).lanes == 2 && scope(4).lanes == 4)
    }

    /// The preview may credit the running owner's resident weights on a Mac
    /// (released before the replacement loads), never its unallocated request
    /// reservation and never a hardware bound: a width short by less than
    /// those weights is proposed, one short by more is not, and the uncredited
    /// predicate the post-release recheck applies is unchanged. A credited
    /// width that recheck refused is not credited again until the refusal
    /// expires, and every refusal line carries each rank's numbers.
    @Test func testPreviewCreditsOnlyTheRunningOwnersWeightsAndRemembersRefusals() throws {
        let home = try home(); record(home)
        let (pair, cap, layout, original) = try fixture()
        func scope(_ lanes: Int) throws -> ClusterPlacementBatchScope {
            let payload = max(512 * 4096, lanes * 248320 * 4)
            let quote = try ClusterPlacementTensorBatchQuote(request: original.request, lanes: lanes,
                chunkTokens: 128, perLaneStateBytes: gib, sharedBytesExcludingCollectives: gib,
                allowance: .init(maximumContextTokens: 65536, maximumChunkTokens: 512,
                    requestBytesExcludingCollectives: (lanes + 1) * gib,
                    maximumCollectivePayloadBytes: payload, maximumCollectiveFrameBytes: payload + 1024,
                    allocationBound: { (($0 + 16383) / 16384) * 16384 }))
            return try ClusterPlacementBatchScope(request: original.request, lanes: lanes, tensorParallelQuote: quote)
        }
        func choose(_ lanes: Int, free: Int) throws -> ClusterPlacementCandidate {
            let decision = try DistributedAutomaticBatchPlanner.decide(description: pair, capability: cap,
                localMemberID: "a", localProfile: profile(free: free), peerProfile: profile(), layout: layout,
                scope: scope(lanes), homeDirectory: home)
            return try #require(decision.result.chosen)
        }
        let roomy = try choose(4, free: 200 * gib)
        let need = roomy.ranks[0].needBytes, weights = roomy.ranks[0].weightsBytes
        #expect(weights > 0 && roomy.mode == .tensorParallel)
        let short = try choose(4, free: need - weights / 2)
        #expect(short.mode == .tensorParallel && short.ranks[0].fit != .now)
        let shares = short.tensorShares ?? [1, 1]
        #expect(!DistributedAutomaticBatchPlanner.accepts(short, requireNow: true))
        #expect(DistributedAutomaticBatchPlanner.acceptsCreditingIncumbentWeights(short, incumbentShares: shares))
        // Another split's weights are not the running owner's: never credited.
        #expect(!DistributedAutomaticBatchPlanner.acceptsCreditingIncumbentWeights(short,
            incumbentShares: shares.map { $0 + 1 }))
        let shorter = try choose(4, free: need - weights - gib)
        #expect(!DistributedAutomaticBatchPlanner.acceptsCreditingIncumbentWeights(shorter, incumbentShares: shares))
        #expect(DistributedAutomaticBatchPlanner.acceptsCreditingIncumbentWeights(roomy, incumbentShares: shares))

        let refusals = DistributedAutomaticBatchCreditRefusals(), start = ContinuousClock.now
        #expect(refusals.allowsCredit(setup: "setup", lanes: 4, now: start))
        refusals.record(setup: "setup", lanes: 4, now: start)
        #expect(!refusals.allowsCredit(setup: "setup", lanes: 4, now: start.advanced(by: .seconds(30))))
        #expect(refusals.allowsCredit(setup: "setup", lanes: 2, now: start))
        #expect(refusals.allowsCredit(setup: "other", lanes: 4, now: start))
        #expect(refusals.allowsCredit(setup: "setup", lanes: 4,
            now: start.advanced(by: DistributedAutomaticBatchCreditRefusals.hold)))

        let fields = DistributedAutomaticBatchPlanner.refusalFields(short, lanes: 4, previous: 2,
            requireNow: true, planned: true)
        #expect(fields["reason"] == "not_now" && fields["requested_lanes"] == "4" && fields["previous_lanes"] == "2")
        #expect(fields["phase"] == "preview" && fields["require_now"] == "1")
        #expect(fields["rank0_need_bytes"] == String(short.ranks[0].needBytes))
        #expect(fields["rank0_load_need_bytes"] == String(short.ranks[0].loadNeedBytes))
        #expect(fields["rank0_admissible_now_bytes"] == String(short.ranks[0].admissibleNowBytes))
        #expect(short.ranks[0].needBytes > short.ranks[0].admissibleNowBytes
            && fields["rank0_short_bytes"] == String(short.ranks[0].needBytes - short.ranks[0].admissibleNowBytes))
        #expect(fields["rank1_short_bytes"] == "0")
        #expect(DistributedAutomaticBatchPlanner.refusalFields(short, lanes: 4, previous: 2, requireNow: true,
            planned: true, phase: "post_release")["phase"] == "post_release")
        #expect(fields["rank0_weights_bytes"] == String(weights) && fields["rank1_fit"] == "now")
        #expect(DistributedAutomaticBatchPlanner.refusalFields(nil, lanes: 8, previous: 2,
            requireNow: true, planned: false)["reason"] == "no_placement")
    }

    @Test func testForeignStaleMalformedAndNonPrivateMeasurementsCannotLoseFeatures() throws {
        for kind in ["foreign", "stale", "malformed", "public"] {
            let home = try home()
            record(home, members: kind == "foreign" ? ["a", "other"] : ["a", "b"],
                now: Date().timeIntervalSince1970 - (kind == "stale" ? ClusterLinkProbeHistory.maximumAgeSeconds + 1 : 0))
            let file = ClusterLinkProbeHistory.defaultFile(homeDirectory: home)
            if kind == "malformed" { try Data("{}".utf8).write(to: file) }
            if kind == "public" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
            let result = try decide(home)
            #expect(result.result.chosen == nil, Comment(rawValue: kind))
            #expect(result.setup == nil, Comment(rawValue: kind))
            #expect(result.result.tensorParallel?.verdict == .reductionNotMeasured, Comment(rawValue: kind))
        }
    }

    @Test func testUnkeyedMeasurementDoesNotEnableTensorPlacement() throws {
        let home = try home(); record(home, keyed: false)
        let result = try decide(home)
        #expect(result.result.chosen == nil)
        #expect(result.setup == nil)
        #expect(result.result.tensorParallel?.reductionKeyed == false)
    }

    @Test func testServedHistoryReachesCalibrationButForeignAndConcurrentRecordsDoNot() throws {
        let home = try home(); record(home)
        let own = [hash("a"), hash("a")]
        for (model, ranks, concurrent) in [("other", ["a", "b"], 0), ("fixture-model", ["a", "other"], 0),
                                           ("fixture-model", ["a", "b"], 1)] {
            try writeServed(home, model: model, ranks: ranks, concurrent: concurrent, builds: own)
            #expect(!(try decide(home).lines.contains("Speed records from served requests")))
        }
        try writeServed(home, cached: 128, builds: own)
        #expect(!(try decide(home).lines.contains("Speed records from served requests")))
        try writeServed(home, builds: own)
        let result = try decide(home)
        #expect(result.lines.contains("Speed records from served requests"))
        #expect(result.lines.contains { $0.contains("tensor_parallel_v1") && $0.contains("request(s)") })
        #expect(!result.lines.contains { $0.contains("other worker builds") })
        #expect(result.result.tensorParallel?.devices.contains { $0.split.measured } == true)
    }

    /// A served speed counts only for the worker build that served it: what an earlier build served (or a record
    /// written before builds were recorded, or one whose ranks ran different builds) never reaches the replacement's
    /// calibration; the plan says how many records it left out.
    @Test func testServedHistoryOfAnotherWorkerBuildDoesNotReachCalibration() throws {
        let home = try home(); record(home)
        for builds in [nil, [hash("9"), hash("9")], [hash("a"), hash("9")]] as [[String]?] {
            try writeServed(home, builds: builds)
            let result = try decide(home)
            #expect(result.lines.contains("Speed records from served requests"))
            #expect(result.lines.contains { $0.hasPrefix("  3 record(s) from other worker builds ignored") && $0.contains(String(hash("a").prefix(12))) })
            #expect(!result.lines.contains { $0.contains("tensor_parallel_v1") && $0.contains("request(s)") })
            #expect(result.result.tensorParallel?.devices.contains { $0.split.measured } != true)
        }
        try writeServed(home, builds: [hash("a"), hash("a")])
        let current = try decide(home)
        #expect(current.result.tensorParallel?.devices.contains { $0.split.measured } == true)
        #expect(!current.lines.contains { $0.contains("other worker builds") })
    }

    @Test func testGLMRemainsOutsideAutomaticBatchEligibility() async throws {
        let request = try ClusterPlacementRequestScope(runtimeModelID: "registered_glm53_flash",
            artifactSHA256: hash("b"), configurationSHA256: hash("c"), promptTokens: 1024, outputTokens: 128,
            maximumPromptTokens: 32768, maximumOutputTokens: 32768, maximumContextTokens: 65536,
            requestChargeEveryRankBytes: gib)
        #expect(throws: ClusterPlacementError.self) { try ClusterPlacementBatchScope(request: request, lanes: 4) }
        let factory = try DistributedAutomaticBatchFactory(providerConfiguration: URL(fileURLWithPath: "/fixture/absent.toml"),
            stopNotice: { _ in })
        let replacement = try await factory.replacement(for: .init(generationID: UUID(), waitingRequests: 4,
            activeRequests: 1, currentCapacity: 1, publicModelID: "fixture-glm", runtimeModelID: "registered_glm53_flash",
            artifactSHA256: hash("b"), configurationSHA256: hash("c"), maximumPromptTokens: 32768,
            maximumOutputTokens: 32768, maximumContextTokens: 65536, requestTimeout: .seconds(315)))
        #expect(replacement == nil)
    }

    /// The plan helper's speed index is about a second of GPU work: it runs only while no model is loaded on this
    /// Mac (`ClusterLocalDeviceProfile`). While one is (a replacement is always previewed beside its running owner,
    /// and a serving member answers the leader's update check every minute), the index this Mac last measured
    /// stands in, and only for the chip and OS build it was measured on; memory is read now either way.
    @Test func testProfileChildMeasuresTheIndexOnlyWhileNoModelIsLoaded() throws {
        let home = try home(), expected = try profile()
        var plain = expected; plain.speedIndex = nil
        var updated = try profile(osBuild: "OTHER"); updated.speedIndex = nil
        try expected.encoded().write(to: home.appendingPathComponent("indexed.json"))
        try plain.encoded().write(to: home.appendingPathComponent("plain.json"))
        try updated.encoded().write(to: home.appendingPathComponent("updated.json"))
        let child = home.appendingPathComponent("plan-helper"), calls = home.appendingPathComponent("calls.txt")
        let answer = home.appendingPathComponent("answer")
        let script = """
            #!/bin/sh
            echo "$*" >> "\(calls.path)"
            [ "$1" = device ] && [ "$2" = --json ] || exit 17
            if [ "$#" = 3 ] && [ "$3" = --index ]; then exec /bin/cat "\(home.path)/indexed.json"; fi
            [ "$#" = 2 ] || exit 18
            exec /bin/cat "\(home.path)/$(/bin/cat "\(answer.path)").json"
            """
        try Data(script.utf8).write(to: child)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
        func read(loaded: Bool, answering name: String = "plain") throws -> ClusterDeviceProfile {
            try Data(name.utf8).write(to: answer)
            return try DistributedAutomaticBatchPlanner.deviceProfile(tool: child,
                deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000, homeDirectory: home, modelLoaded: loaded)
        }
        func called() throws -> [String] {
            String(decoding: try Data(contentsOf: calls), as: UTF8.self).split(separator: "\n").map(String.init)
        }
        // Serving before this Mac ever measured its index: no benchmark, and no index.
        let first = try read(loaded: true)
        #expect(first.speedIndex == nil && first == plain)
        #expect(try called() == ["device --json"])
        #expect(ClusterDeviceIndexRecord.read(homeDirectory: home) == nil)
        // Idle: measured now, and kept owner-only.
        let idle = try read(loaded: false)
        #expect(idle.speedIndex == expected.speedIndex)
        #expect(try called() == ["device --json", "device --json --index"])
        #expect(ClusterDeviceIndexRecord.read(homeDirectory: home)?.index == expected.speedIndex)
        let mode = try FileManager.default.attributesOfItem(atPath: ClusterDeviceIndexRecord.file(homeDirectory: home).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Serving: no benchmark, the kept index stands in beside the memory read now.
        let serving = try read(loaded: true)
        #expect(serving == expected)
        #expect(try called() == ["device --json", "device --json --index", "device --json"])
        // After an OS update the kept index is not this Mac's any more: none stands in.
        let afterUpdate = try read(loaded: true, answering: "updated")
        #expect(afterUpdate.speedIndex == nil && afterUpdate.osBuild == "OTHER")
    }

    private var slowReduction: ClusterLinkCosts {
        .init(measured: true, perChunkSeconds: 0, perDecodeStepSeconds: [:], handoffSecondsPerByte: 0,
            provenance: "constructed slow reduction", reduction: .init(fixedSeconds: 0.2,
                secondsPerByte: 0.000001, keyed: true, provenance: "constructed, not hardware"))
    }

    @Test func testCheaperPipelineExcludedForExactContractWithoutChangingRates() throws {
        let (pair, cap, layout, _) = try fixture()
        func plan(_ cap: ClusterRuntimeCapability, _ layout: ClusterModelLayout) throws -> ClusterPlacementResult {
            try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
                localProfile: profile(), peerProfile: profile(), layout: layout, promptTokens: 1024, outputTokens: 128,
                link: slowReduction, incumbentMode: .pipeline, environment: [:]).result
        }
        let required = try plan(cap, layout)
        #expect(required.chosen?.mode == .tensorParallel)
        #expect(required.alternatives.allSatisfy { $0.mode == .tensorParallel })
        // Identical geometry, devices and link under another existing dense
        // registration keep the pipeline as a candidate; tensor parallel still
        // goes first where it fits (owner, 2026-10-24), its gain never claimed.
        var co = try JSONSerialization.jsonObject(with: ClusterRuntimeCapabilityCodec.encode(cap)) as! [String: Any]
        co["runtimeModelID"] = "registered_qwen35_9b"
        var cp = co["profile"] as! [String: Any]; cp["id"] = "registered_qwen35_9b_greedy_generation_v1"; co["profile"] = cp
        let other = try ClusterRuntimeCapabilityCodec.decode(JSONSerialization.data(withJSONObject: co, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10]))
        var lo = try JSONSerialization.jsonObject(with: layout.encoded()) as! [String: Any]
        lo["runtimeModelID"] = other.runtimeModelID
        let otherLayout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: lo))
        // No setup is synthesized with the pair's old capability digest: compare
        // actual planner selection with an equally pinned pair for the other row.
        var po = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pair)) as! [String: Any]
        po["capabilitySHA256"] = ClusterConfigurationCodec.sha256(try ClusterRuntimeCapabilityCodec.encode(other))
        let otherPair = try ClusterPairDescription.decode(JSONSerialization.data(withJSONObject: po))
        let ordinary = try ClusterPlacementFlow.decide(description: otherPair, capability: other, localMemberID: "a",
            localProfile: profile(), peerProfile: profile(), layout: otherLayout, promptTokens: 1024, outputTokens: 128,
            link: slowReduction, environment: [:]).result
        #expect(ordinary.chosen?.mode == .tensorParallel)
        #expect(ordinary.alternatives.contains { $0.mode == .pipeline })
        let sameTP = try #require(ordinary.chosen)
        let requiredTP = try #require(required.chosen)
        #expect(sameTP.prediction(.rested) == requiredTP.prediction(.rested))
        #expect(ClusterModelFeaturePolicy.admissibleModes(other) == other.supportedGenerationModes)
        // The reason line says why the 27B has no pipeline (its features), never that none fits (2026-10-24); the
        // other row, which keeps the pipeline as a candidate, gives the rule, not a gain it does not predict.
        #expect(ClusterPlacementExplanation.deploymentReason(required) == "Tensor parallel: pipeline is left out "
            + "(Qwen3.8 27B keeps images, video and committed-token logprobs only in tensor parallel).")
        #expect(required.modesReason != nil && ordinary.modesReason == nil)
        #expect(ClusterPlacementExplanation.tensorParallelNote(required) == nil)
        let listed = ClusterSetupPlanning.summary(ordinary, chosen: try #require(ordinary.chosen), lines: [], localMemberID: "a",
            profiles: [:])
        #expect(listed.tensorParallelNote == nil)
        #expect(ClusterPlacementExplanation.deploymentReason(ordinary)
            == "Tensor parallel: the model fits, so both Macs share every layer of every token.")
    }

    @Test func testLinkHistoryKeepsRecentLoadsAndPlansOnTheirMedian() throws {
        let home = try home(), now = Date().timeIntervalSince1970
        func probe(_ fixed: Int) -> ClusterWorkerLinkProbe {
            ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64, pointToPointSmallMicroseconds: 170,
                pointToPointLargeBytes: 4_194_304, pointToPointLargeMicroseconds: 2_600, allSumSmallBytes: 20_480,
                allSumSmallMicroseconds: fixed, allSumLargeBytes: 10_485_760, allSumLargeMicroseconds: fixed + 1_260)
        }
        // Ten loads, the reduction's fixed part as the pair's loads spread (43 to 109 us); either member order.
        let loads = [43, 109, 72, 60, 95, 51, 88, 101, 66, 79]
        for (index, fixed) in loads.enumerated() {
            #expect(ClusterLinkProbeHistory.record(probe(fixed), members: index % 2 == 0 ? ["a", "b"] : ["b", "a"],
                homeDirectory: home, now: now - Double(loads.count - index) * 600))
        }
        let file = ClusterLinkProbeHistory.defaultFile(homeDirectory: home)
        let saved = try #require(ClusterLinkProbeHistory.read(file))
        #expect(saved.measurements(members: ["a", "b"], now: now).map(\.probe.allSumSmallMicroseconds) == Array(loads.suffix(8).reversed()))
        let costs = try #require(ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["b", "a"], now: now))
        // The last eight sorted: 51 60 66 72 79 88 95 101; the median lies between the 72 and 79 us loads.
        let middle = [72, 79].map { ClusterLinkCosts(probe: probe($0), measuredUTC: "t")!.reduction!.fixedSeconds }.reduce(0, +) / 2
        #expect(abs((costs.reduction?.fixedSeconds ?? 0) - middle) < 1e-12)
        #expect(costs.reduction?.keyed == true && costs.provenance.hasPrefix("the median of 8 loads' probes"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // An earlier build reads the latest load where it always did.
        struct EarlierEntry: Decodable { let measuredAt: Double; let probe: ClusterWorkerLinkProbe }
        struct Earlier: Decodable { let schema: String; let pairs: [String: EarlierEntry] }
        let earlier = try JSONDecoder().decode(Earlier.self, from: Data(contentsOf: file))
        #expect(earlier.schema == ClusterLinkProbeHistory.schemaName && earlier.pairs["a|b"]?.probe == probe(79))
    }

    /// Each Mac's own share steps, as its last load timed them alone and the
    /// serving leader kept them (`ClusterShareProbeHistory`, in this home), are
    /// what a replacement balances the tensor-parallel split by: the device
    /// index alone gives the faster-indexed "a" two thirds; "a" measured 9 ms at
    /// 2/3 and "b" 4 ms at 1/3 move the plan to 1:1. Another model's probes and
    /// an unrelated member's change nothing.
    @Test func testRecordedShareProbesBalanceTheTensorSplit() throws {
        let home = try home(); record(home)
        let (pair, cap, original, scope) = try fixture()
        var object = try JSONSerialization.jsonObject(with: original.encoded()) as! [String: Any]
        var tensor = object["tensorParallel"] as! [String: Any], family = tensor["family"] as! [String: Any]
        family["shareOptions"] = [[1, 2], [2, 1]]; tensor["family"] = family; object["tensorParallel"] = tensor
        let layout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
        func shares() throws -> [Int] {
            let decided = try DistributedAutomaticBatchPlanner.decide(description: pair, capability: cap, localMemberID: "a",
                localProfile: profile(decodeIndex: 50_000), peerProfile: profile(), layout: layout, scope: scope, homeDirectory: home)
            #expect(decided.result.chosen?.mode == .tensorParallel && decided.setup != nil)
            return decided.result.chosen?.tensorShares ?? [1, 1]
        }
        func probe(_ share: Int, _ microseconds: Int) -> ClusterWorkerShareProbe {
            .init(sharePerMille: share, plainStepMicroseconds: microseconds, rounds: 7)
        }
        #expect(try shares() == [2, 1])
        #expect(ClusterShareProbeHistory.record([.init(member: "a", buildSHA256: hash("a"), probe: probe(667, 9_000)),
            .init(member: "c", buildSHA256: hash("a"), probe: probe(333, 4_000))], artifactSHA256: hash("9"), homeDirectory: home))
        #expect(ClusterShareProbeHistory.record([.init(member: "c", buildSHA256: hash("a"), probe: probe(333, 4_000))],
            artifactSHA256: hash("b"), homeDirectory: home))
        #expect(try shares() == [2, 1], "another model's or another member's probes moved the split")
        #expect(ClusterShareProbeHistory.record([.init(member: "a", buildSHA256: hash("a"), probe: probe(667, 9_000)),
            .init(member: "b", buildSHA256: hash("a"), probe: probe(333, 4_000))], artifactSHA256: hash("b"), homeDirectory: home))
        #expect(try shares() == [1, 1])
    }

    @Test func testSingleProbeFileAnEarlierBuildWroteStillPlansAndGrows() throws {
        let home = try home(), now = Date().timeIntervalSince1970
        let probe = ClusterWorkerLinkProbe(transport: "jaccl", keyed: true, pointToPointSmallBytes: 64, pointToPointSmallMicroseconds: 167,
            pointToPointLargeBytes: 4_194_304, pointToPointLargeMicroseconds: 2_622, allSumSmallBytes: 20_480,
            allSumSmallMicroseconds: 38, allSumLargeBytes: 10_485_760, allSumLargeMicroseconds: 1_296)
        let directory = home.appendingPathComponent(".darkbloom/cluster", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let measuredAt = now - 3_600
        let old: [String: Any] = ["schema": "darkbloom_cluster_link_probes_v1", "pairs": ["a|b": ["measuredAt": measuredAt,
            "probe": try JSONSerialization.jsonObject(with: JSONEncoder().encode(probe))]]]
        let file = ClusterLinkProbeHistory.defaultFile(homeDirectory: home)
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let utc = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: measuredAt))
        #expect(ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["b", "a"], now: now)
            == ClusterLinkCosts(probe: probe, measuredUTC: utc))
        #expect(ClusterLinkProbeHistory.record(probe, members: ["a", "b"], homeDirectory: home, now: now))
        #expect(ClusterLinkProbeHistory.read(file)?.measurements(members: ["a", "b"], now: now).count == 2)
    }

    @Test func testMissingShapeAndMemoryCannotFallBackToPipeline() throws {
        let (pair, cap, layout, _) = try fixture()
        var lo = try JSONSerialization.jsonObject(with: layout.encoded()) as! [String: Any]
        lo.removeValue(forKey: "tensorParallel")
        let noShape = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: lo))
        for (candidate, memory) in [(noShape, try profile()), (layout, try profile().cappedForBench(admissibleBytes: 6 * gib))] {
            let value = try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
                localProfile: memory, peerProfile: memory, layout: candidate, link: slowReduction, environment: [:])
            #expect(value.result.chosen == nil)
            #expect(value.setup == nil)
            #expect(value.lines.contains { $0.contains("No reduced-feature setup was saved") })
        }
    }

    @Test func testOldPipelineRecordLoadsForReplanButCannotBeStartedOrSavedAgain() throws {
        let root = try home(), paths = try ClusterUserPaths(homeDirectory: root)
        let (pair, cap, layout, _) = try fixture()
        let capData = try ClusterRuntimeCapabilityCodec.encode(cap), capSHA = ClusterConfigurationCodec.sha256(capData)
        let selected = try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
            localProfile: profile(), peerProfile: profile(), layout: layout, link: slowReduction,
            incumbentMode: .pipeline, environment: [:])
        let setup = try #require(selected.setup), bytes = try #require(setup.configurations["a"])
        var old = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        old.removeValue(forKey: "generationMode"); old.removeValue(forKey: "tensorShares")
        let secret = root.appendingPathComponent("paired.secret")
        try Data(repeating: 7, count: 32).write(to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        var attachment = old["linkControl"] as! [String: Any]; attachment["secretFile"] = secret.path; old["linkControl"] = attachment
        let oldConfig = try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: old), capability: cap, capabilitySHA256: capSHA)
        let oldBytes = try ClusterConfigurationCodec.encode(oldConfig, capability: cap, capabilitySHA256: capSHA)
        let oldSHA = ClusterConfigurationCodec.sha256(oldBytes), oldURL = try paths.configurationURL(sha256: oldSHA)
        try FileManager.default.createDirectory(at: paths.configurationsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let capURL = try paths.capabilityURL(sha256: capSHA)
        try capData.write(to: capURL); try oldBytes.write(to: oldURL)
        for file in [capURL, oldURL] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let store = ClusterConfigurationStore(paths: paths)
        let saved = try store.load(reference: .init(configuration: oldURL.path, sha256: oldSHA))
        #expect(saved.configuration.selectedGenerationMode == .pipeline)
        #expect(throws: ClusterConfigurationError.self) { try DistributedInstalledPlan(saved: saved, paths: paths) }
        var pointer: ClusterConfigurationReference?
        #expect(throws: ClusterConfigurationError.self) {
            try store.save(configurationInput: oldURL, capabilityInput: capURL, capabilitySHA256: capSHA) { pointer = $0 }
        }
        #expect(pointer == nil)
        let replanned = try ClusterPlacementFlow.decide(description: pair, capability: saved.capability, localMemberID: "a",
            localProfile: profile(), peerProfile: profile(), layout: layout, link: slowReduction,
            incumbentMode: saved.configuration.selectedGenerationMode, environment: [:])
        let replacement = try #require(replanned.setup?.configurations["a"])
        var next = try JSONSerialization.jsonObject(with: replacement) as! [String: Any]; next["linkControl"] = attachment
        let nextURL = root.appendingPathComponent("replacement.json")
        try JSONSerialization.data(withJSONObject: next).write(to: nextURL)
        _ = try store.save(configurationInput: nextURL, capabilityInput: capURL, capabilitySHA256: capSHA) { pointer = $0 }
        let adopted = try store.load(reference: #require(pointer))
        #expect(adopted.configuration.selectedGenerationMode == .tensorParallel)
        _ = try DistributedInstalledPlan(saved: adopted, paths: paths)
        #expect(try Data(contentsOf: oldURL) == oldBytes)
    }

    @Test func testActualBridgeRejectsMissingOrMismatchedReadinessBeforeMetadataIO() throws {
        let id = DistributedResidentIdentity(membershipEpoch: UUID(), modelID: "registered_qwen38_27b",
            artifactSHA256: hash("a"), configurationSHA256: hash("b"), peers: [
                .init(id: "a", buildSHA256: hash("c")), .init(id: "b", buildSHA256: hash("d"))])
        let profileID = "registered_qwen38_27b_greedy_generation_v1"
        let foreign = DistributedResidentIdentity(membershipEpoch: UUID(), modelID: id.modelID,
            artifactSHA256: id.artifactSHA256, configurationSHA256: id.configurationSHA256, peers: id.peers)
        let valid = DistributedResidentReadiness(identity: id, profileID: profileID, requestCapacityBytes: 1024,
            media: ClusterQwenMedia.contract)
        let cases: [(DistributedResidentReadiness?, Bool)] = [(nil, true),
            (.init(identity: id, profileID: profileID, requestCapacityBytes: 1024), true),
            (.init(identity: foreign, profileID: profileID, requestCapacityBytes: 1024, media: ClusterQwenMedia.contract), true),
            (.init(identity: id, profileID: "foreign", requestCapacityBytes: 1024, media: ClusterQwenMedia.contract), true),
            (valid, false)]
        for (ready, logprobs) in cases {
            let profile = try DistributedResidentExecutionProfile(id: profileID, vocabularySize: 64,
                maxPromptTokens: 32, maxOutputTokens: 8, maxContextTokens: 40, requestTimeout: .seconds(10), supportsLogprobs: logprobs)
            #expect(throws: DistributedEngineError.invalidConfiguration("Qwen3.8 27B requires matching native media readiness and committed-token logprobs before serving")) {
                try DistributedEngineFactory.makeBridge(owner: FeatureReadyOwner(ready), expectedIdentity: id,
                    profile: profile, tokenizer: TokenizerHandle(FeatureTokenizer()), eosTokenIDs: [63],
                    modelType: "qwen3_5", modelDirectory: URL(fileURLWithPath: "/nonexistent-feature-fixture"))
            }
        }
        let profile = try DistributedResidentExecutionProfile(id: profileID, vocabularySize: 64,
            maxPromptTokens: 32, maxOutputTokens: 8, maxContextTokens: 40, requestTimeout: .seconds(10), supportsLogprobs: true)
        try ClusterModelFeaturePolicy.requireReady(valid, identity: id, profile: profile)
    }

    @Test func automaticAssistantUsesVerifiedInlineArtifactAndRespectsDisabledModes() throws {
        let directory = try home(), modelID = "fixture-inline-qwen"
        let header = try JSONSerialization.data(withJSONObject: ["mtp.weight": ["dtype": "F32", "shape": [1], "data_offsets": [0, 4]]])
        var length = UInt64(header.count).littleEndian
        var shard = withUnsafeBytes(of: &length) { Data($0) }; shard.append(header); shard.append(Data(repeating: 0, count: 4))
        try shard.write(to: directory.appendingPathComponent("model.safetensors"))
        let config = try JSONSerialization.data(withJSONObject: ["mtplx_mtp": ["included": true], "mtplx_mtp_quantization": [:]])
        try config.write(to: directory.appendingPathComponent("config.json"))
        let index = try JSONSerialization.data(withJSONObject: ["weight_map": ["mtp.weight": "model.safetensors"]])
        try index.write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        let files: [ClusterCatalogArtifact.File] = [.init(path: "model.safetensors", sizeBytes: Int64(shard.count),
            sha256: ClusterConfigurationCodec.sha256(shard))]
        let aggregate = ClusterCatalogArtifact.aggregateDigest(files)
        let manifest = try JSONSerialization.data(withJSONObject: ["model_id": modelID, "version": "fixture",
            "aggregate_sha256": aggregate, "total_size_bytes": shard.count,
            "files": [["path": files[0].path, "size_bytes": files[0].sizeBytes, "sha256": files[0].sha256]]])
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        func candidate(_ mode: MTPMode, id: String? = nil, digest: String? = nil,
                       environment: [String: String] = [:]) throws -> Bool {
            try ClusterPlacementTensorAssistantSelection.automaticCandidate(mode: mode,
                runtimeModelID: ClusterQwenTensorAssistantPolicy.runtimeModelID,
                modelDirectory: directory, publicModelID: id ?? modelID, artifactSHA256: digest ?? aggregate,
                manifestSHA256: ClusterConfigurationCodec.sha256(manifest), environment: environment)
        }
        let automatic = try candidate(.auto), forced = try candidate(.on), off = try candidate(.off)
        let killed = try candidate(.auto, environment: ["DARKBLOOM_CBV2_MTP": "0"])
        #expect(automatic && forced && !off && !killed)
        #expect(throws: (any Error).self) { try candidate(.auto, id: "foreign-entry") }
        #expect(throws: (any Error).self) { try candidate(.auto, digest: hash("f")) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        let absent = try candidate(.auto)
        #expect(!absent)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("config.json"))
        #expect(throws: (any Error).self) { try candidate(.auto) }
        let disabledMalformed = try candidate(.off)
        #expect(!disabledMalformed)
    }

    @Test func automaticQuotePinsNativeInventoryAndCompleteWidthOneScope() throws {
        let (_, cap, _, _) = try fixture()
        func quote(_ verification: ClusterQwenTensorAssistantPolicy.Verification = .admittedCohort,
                   depth: Int = ClusterPlacementTensorAssistantSelection.automaticDepth, artifact: String? = nil,
                   assistant: Bool = true) throws -> ClusterPlacementTensorBatchQuote {
            let original = try assistantQuote(1, depth: depth, verification: verification)
            let request = try ClusterPlacementRequestScope(runtimeModelID: cap.runtimeModelID,
                artifactSHA256: artifact ?? cap.artifactSHA256, configurationSHA256: cap.configurationSHA256,
                promptTokens: cap.profile.maximumPromptTokens, outputTokens: cap.profile.maximumOutputTokens,
                maximumPromptTokens: cap.profile.maximumPromptTokens, maximumOutputTokens: cap.profile.maximumOutputTokens,
                maximumContextTokens: cap.profile.maximumContextTokens, requestChargeEveryRankBytes: gib)
            return try .init(request: request, lanes: 1, chunkTokens: original.chunkTokens,
                perLaneStateBytes: original.perLaneStateBytes, sharedBytesExcludingCollectives: original.sharedBytesExcludingCollectives,
                allowance: original.allowance, assistant: assistant ? original.assistant : nil)
        }
        let native = try quote()
        try ClusterPlacementTensorAssistantSelection.requireDiscoveredQuote(native, capability: cap, chunkTokens: 128)
        #expect(native.assistant?.policy.inventorySHA256 == hash("8"))
        for invalid in [try quote(.singleton), try quote(depth: 2), try quote(artifact: hash("9"))] {
            #expect(throws: (any Error).self) {
                try ClusterPlacementTensorAssistantSelection.requireDiscoveredQuote(invalid, capability: cap, chunkTokens: 128)
            }
        }
        let plain = try quote(assistant: false)
        try ClusterPlacementTensorAssistantSelection.requireDiscoveredQuote(plain, capability: cap, chunkTokens: 128, assistant: false)
        #expect(throws: (any Error).self) {
            try ClusterPlacementTensorAssistantSelection.requireDiscoveredQuote(native, capability: cap, chunkTokens: 128, assistant: false)
        }
        let args = try ClusterPlacementTensorAssistantSelection.discoveryArguments(modelDirectory: "/fixture/model",
            promptTokens: 32768, outputTokens: 32768, chunkTokens: 128)
        #expect(args.suffix(4) == ["--mtp-depth", "3", "--tp-mtp-verification", "admitted_target_cohort_v1"])
        #expect(!args.contains(ClusterQwenTensorAssistantPolicy.inventoryArgument))
        let plainArgs = try ClusterPlacementTensorAssistantSelection.discoveryArguments(modelDirectory: "/fixture/model",
            promptTokens: 32768, outputTokens: 32768, chunkTokens: 128, assistant: false)
        #expect(!plainArgs.contains("--mtp-depth") && plainArgs.contains("--batch-lanes"))
    }

    private func assistantQuote(_ lanes: Int, depth: Int = ClusterPlacementTensorAssistantSelection.automaticDepth,
                                verification: ClusterQwenTensorAssistantPolicy.Verification = .singleton) throws -> ClusterPlacementTensorBatchQuote {
        let (_, _, _, scope) = try fixture()
        return try .init(request: scope.request, lanes: lanes, chunkTokens: 128,
            perLaneStateBytes: gib, sharedBytesExcludingCollectives: 2 * gib,
            allowance: .init(maximumContextTokens: 65536, maximumChunkTokens: 512,
                requestBytesExcludingCollectives: (lanes + 2) * gib,
                maximumCollectivePayloadBytes: max(512 * 4096, lanes * 248320 * 4),
                maximumCollectiveFrameBytes: max(512 * 4096, lanes * 248320 * 4) + 1024,
                allocationBound: { (($0 + 16383) / 16384) * 16384 }),
            assistant: .init(policy: .init(depth: depth, inventorySHA256: hash("8"), verification: verification),
                residentBytes: gib, loadBytes: 2 * gib, largestAllocationBytes: gib))
    }

    @Test func wideningQuoteSteersTheRetainedSplitTowardOneThatCanWiden() throws {
        let home = try home(); record(home)
        let (pair, cap, originalLayout, scope) = try fixture()
        var object = try JSONSerialization.jsonObject(with: originalLayout.encoded()) as! [String: Any]
        var tensor = object["tensorParallel"] as! [String: Any]
        var family = tensor["family"] as! [String: Any]
        family["shareOptions"] = [[1, 2], [2, 1]]
        tensor["family"] = family; object["tensorParallel"] = tensor
        let layout = try ClusterModelLayout.decode(JSONSerialization.data(withJSONObject: object))
        func quote(_ lanes: Int) throws -> ClusterPlacementTensorBatchQuote {
            try .init(request: scope.request, lanes: lanes, chunkTokens: 128,
                perLaneStateBytes: 8 * gib, sharedBytesExcludingCollectives: gib,
                allowance: .init(maximumContextTokens: 65536, maximumChunkTokens: 512,
                    requestBytesExcludingCollectives: lanes * 8 * gib + gib,
                    maximumCollectivePayloadBytes: 512 * 4096, maximumCollectiveFrameBytes: 512 * 4096 + 1024,
                    allocationBound: { (($0 + 16383) / 16384) * 16384 }))
        }
        let single = try quote(1), wide = try quote(2)
        func decide(free: Int, widening: ClusterPlacementTensorBatchQuote?) throws -> ClusterSetupPlanning.PlacementDecision {
            try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
                localProfile: profile(), peerProfile: profile(free: free), layout: layout, tensorAssistantQuote: single,
                tensorWideningQuote: widening, leader: "a",
                link: ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])!,
                environment: [:], benchDebugBuild: false)
        }
        let growth = wide.allowance.reservedBytes - single.allowance.reservedBytes
        // Mac b is rank 1: the running owner's weights and its own request
        // (the replacement is previewed while it serves), plus the replacement's need.
        func widen(_ c: ClusterPlacementCandidate) -> Int {
            c.ranks[1].weightsBytes + single.allowance.reservedBytes + c.ranks[1].needBytes + growth
        }
        func splits(_ d: ClusterSetupPlanning.PlacementDecision) -> [ClusterPlacementCandidate] {
            ([d.result.chosen].compactMap { $0 } + d.result.alternatives).filter { $0.mode == .tensorParallel }
        }
        let open = splits(try decide(free: 200 * gib, widening: nil))
        let lightest = try #require(open.min { widen($0) < widen($1) })
        let heaviest = try #require(open.max { widen($0) < widen($1) })
        #expect(widen(lightest) < widen(heaviest))
        // b admits exactly what the lightest split needs to widen beside its owner.
        let steered = try decide(free: widen(lightest), widening: wide)
        #expect(steered.result.chosen?.tensorShares == lightest.tensorShares)
        #expect(splits(steered).allSatisfy { widen($0) <= widen(lightest) })
        // Without the widening quote every split stays a candidate.
        let unsteered = splits(try decide(free: widen(lightest), widening: nil))
        #expect(unsteered.contains { widen($0) > widen(lightest) })
        // A widening quote must widen the same request.
        #expect(throws: (any Error).self) { try decide(free: widen(lightest), widening: single) }
    }

    @Test func discoveredAssistantThatCannotBePlacedGivesWayToTheOrdinaryTarget() throws {
        let home = try home(); record(home)
        let (pair, cap, layout, scope) = try fixture()
        let allowance = { (bytes: Int) throws in try ClusterTensorParallelRequestAllowance(maximumContextTokens: 65536,
            maximumChunkTokens: 512, requestBytesExcludingCollectives: bytes,
            maximumCollectivePayloadBytes: 512 * 4096, maximumCollectiveFrameBytes: 512 * 4096 + 1024,
            allocationBound: { (($0 + 16383) / 16384) * 16384 }) }
        // Larger than either constructed Mac can admit, as the installed
        // full-context assistant reservation is on a busy M5.
        let assistant = try ClusterPlacementTensorBatchQuote(request: scope.request, lanes: 1, chunkTokens: 128,
            perLaneStateBytes: 100 * gib, sharedBytesExcludingCollectives: 200 * gib, allowance: try allowance(300 * gib),
            assistant: .init(policy: .init(depth: 3, inventorySHA256: hash("8"), verification: .admittedCohort),
                residentBytes: gib, loadBytes: 2 * gib, largestAllocationBytes: gib))
        let target = try ClusterPlacementTensorBatchQuote(request: scope.request, lanes: 1, chunkTokens: 128,
            perLaneStateBytes: gib, sharedBytesExcludingCollectives: gib, allowance: try allowance(2 * gib))
        func decide(_ quote: ClusterPlacementTensorBatchQuote?) throws -> ClusterSetupPlanning.PlacementDecision {
            try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
                localProfile: profile(), peerProfile: profile(), layout: layout, tensorAssistantQuote: quote,
                leader: "a", link: ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])!,
                environment: [:], benchDebugBuild: false)
        }
        #expect(try decide(assistant).result.chosen == nil)
        let discovered = try ClusterSetupPlanning.assistantOrTarget(assistant, fallback: target, decide)
        #expect(discovered.quote == target && discovered.decision.result.chosen?.mode == .tensorParallel)
        #expect(discovered.decision.lines.first == ClusterSetupPlanning.assistantDoesNotFit)
        for bytes in try #require(discovered.decision.setup).configurations.values {
            let config = try ClusterConfigurationCodec.decode(bytes, capability: cap, capabilitySHA256: pair.capabilitySHA256)
            #expect(config.tensorAssistant == nil)
        }
        // An explicitly requested assistant has no fallback and keeps its refusal.
        let requested = try ClusterSetupPlanning.assistantOrTarget(assistant, fallback: nil, decide)
        #expect(requested.quote == assistant && requested.decision.result.chosen == nil)
        // A placeable assistant is kept.
        let fits = try assistantQuote(1, verification: .admittedCohort)
        let kept = try ClusterSetupPlanning.assistantOrTarget(fits, fallback: target, decide)
        #expect(kept.quote == fits && kept.decision.result.chosen != nil)
    }

    @Test func testAssistantSingletonAndWiderPlansPersistSamePolicyAndBilateralArguments() throws {
        for verification in [ClusterQwenTensorAssistantPolicy.Verification.singleton, .admittedCohort] {
            let home = try home(); record(home)
            let (pair, cap, layout, _) = try fixture()
            let singleton = try assistantQuote(1, verification: verification)
            let first = try ClusterPlacementFlow.decide(description: pair, capability: cap, localMemberID: "a",
                localProfile: profile(), peerProfile: profile(), layout: layout, tensorAssistantQuote: singleton,
                leader: "a", link: ClusterLinkProbeHistory.costs(homeDirectory: home, members: ["a", "b"])!,
                environment: [:], benchDebugBuild: false)
            let firstSetup = try #require(first.setup)
            #expect(first.result.chosen?.mode == .tensorParallel)
            let policy = try #require(singleton.assistant?.policy)
            for width in [2, 4, 8] {
                let quote = try assistantQuote(width, verification: verification)
                let scope = try ClusterPlacementBatchScope(request: quote.request, lanes: width, tensorParallelQuote: quote)
                let next = try DistributedAutomaticBatchPlanner.decide(description: pair, capability: cap, localMemberID: "a",
                    localProfile: profile(), peerProfile: profile(), layout: layout, scope: scope, homeDirectory: home)
                let nextSetup = try #require(next.setup)
                for member in ["a", "b"] {
                    let initial = try ClusterConfigurationCodec.decode(firstSetup.configurations[member]!, capability: cap,
                        capabilitySHA256: pair.capabilitySHA256)
                    let widened = try ClusterConfigurationCodec.decode(nextSetup.configurations[member]!, capability: cap,
                        capabilitySHA256: pair.capabilitySHA256)
                    #expect(initial.tensorAssistant == policy && widened.tensorAssistant == policy)
                    #expect(initial.batchLanes == nil && widened.batchLanes == width)
                    try ClusterAutomaticSetupHandoff.requireCompatible(initial, widened)
                    let argv = try DistributedInstalledGenerationSelection.workerArguments(configuration: widened, capability: cap)
                    let expected = ["--mtp-depth", "3", ClusterQwenTensorAssistantPolicy.inventoryArgument, hash("8")] + policy.verificationArguments
                    #expect(Array(argv.suffix(expected.count)) == expected)
                    let quoteArguments = try ClusterPlacementTensorAssistantSelection.arguments(modelDirectory: "/fixture/model",
                        policy: policy, promptTokens: 1024, outputTokens: 128, lanes: width, chunkTokens: 128)
                    let quoteSuffix = ["--mtp-depth", "3"] + policy.verificationArguments
                    #expect(Array(quoteArguments.suffix(quoteSuffix.count)) == quoteSuffix)
                    let expectedReady = try ClusterQwenTensorAssistantReady(policy: policy, capacity: width)
                    #expect(expectedReady.maximumSpeculativeWidth == (verification == .admittedCohort ? width : 1))
                    #expect(DistributedInstalledSpeculation(configuration: widened, capability: cap).enabled)
                    let canonical = try ClusterConfigurationCodec.encode(widened, capability: cap, capabilitySHA256: pair.capabilitySHA256)
                    #expect(try ClusterConfigurationCodec.decode(canonical, capability: cap,
                        capabilitySHA256: pair.capabilitySHA256) == widened)
                    var object = try JSONSerialization.jsonObject(with: canonical) as! [String: Any]
                    object.removeValue(forKey: "tensorAssistant")
                    let dropped = try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: object),
                        capability: cap, capabilitySHA256: pair.capabilitySHA256)
                    #expect(throws: (any Error).self) { try ClusterAutomaticSetupHandoff.requireCompatible(widened, dropped) }
                    object["tensorAssistant"] = try ClusterQwenTensorAssistantPolicy(depth: 4, inventorySHA256: hash("8")).object
                    let changed = try ClusterConfigurationCodec.decode(JSONSerialization.data(withJSONObject: object),
                        capability: cap, capabilitySHA256: pair.capabilitySHA256)
                    #expect(throws: (any Error).self) { try ClusterAutomaticSetupHandoff.requireCompatible(widened, changed) }
                }
            }
        }
    }

    @Test func testSavedAssistantStrictScopeAndBinaryCompatibilityRefusals() throws {
        let home = try home(); record(home)
        let (pair, cap, layout, _) = try fixture(), quote = try assistantQuote(4)
        let scope = try ClusterPlacementBatchScope(request: quote.request, lanes: 4, tensorParallelQuote: quote)
        let decision = try DistributedAutomaticBatchPlanner.decide(description: pair, capability: cap, localMemberID: "a",
            localProfile: profile(), peerProfile: profile(), layout: layout, scope: scope, homeDirectory: home)
        let bytes = try #require(decision.setup?.configurations["a"])
        let valid = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        func rejects(_ edit: (inout [String: Any]) -> Void) throws {
            var object = valid; edit(&object)
            let malformed = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) {
                _ = try ClusterConfigurationCodec.decode(malformed, capability: cap, capabilitySHA256: pair.capabilitySHA256)
            }
        }
        try rejects { $0["tensorAssistant"] = NSNull() }
        try rejects { $0["generationMode"] = ClusterGenerationMode.pipeline.rawValue }
        try rejects { var a = $0["tensorAssistant"] as! [String: Any]; a["depth"] = true; $0["tensorAssistant"] = a }
        try rejects { var a = $0["tensorAssistant"] as! [String: Any]; a["depth"] = 1.5; $0["tensorAssistant"] = a }
        try rejects { var a = $0["tensorAssistant"] as! [String: Any]; a["inventorySHA256"] = self.hash("G"); $0["tensorAssistant"] = a }
        try rejects { var a = $0["tensorAssistant"] as! [String: Any]; a["extra"] = "ignored"; $0["tensorAssistant"] = a }
        let text = String(decoding: bytes, as: UTF8.self)
        let depthKey = "\"depth\":\(ClusterPlacementTensorAssistantSelection.automaticDepth)"
        #expect(text.contains(depthKey))
        #expect(throws: (any Error).self) {
            _ = try ClusterConfigurationCodec.decode(Data(text.replacingOccurrences(of: depthKey, with: depthKey + "," + depthKey).utf8),
                capability: cap, capabilitySHA256: pair.capabilitySHA256)
        }
        var features = DistributedInstalledWorkerFeatures(hasProgressGuard: true, acceptsStartupDeadline: true,
            acceptsDataPlane: true)
        #expect(throws: (any Error).self) { try features.requireTensorAssistantPolicy(required: true) }
        try features.requireTensorAssistantPolicy(required: false)
        features.acceptsTensorAssistantPolicy = true
        try features.requireTensorAssistantPolicy(required: true)
        #expect(throws: (any Error).self) { try features.requireTensorAssistantPolicy(required: true, cohortRequired: true) }
        features.acceptsTensorAssistantCohort = true
        try features.requireTensorAssistantPolicy(required: true, cohortRequired: true)
        #expect(throws: (any Error).self) { try features.requireTensorAssistantPolicy(required: false, cohortRequired: true) }
        features.acceptsDataPlane = false
        #expect(throws: (any Error).self) { try features.requireTensorAssistantPolicy(required: true) }
        let policy = try #require(quote.assistant?.policy)
        for width in [1, 2, 4, 8] {
            let args = try ClusterPlacementTensorAssistantSelection.arguments(modelDirectory: "/fixture/model", policy: policy,
                promptTokens: 32768, outputTokens: 32768, lanes: width, chunkTokens: 128)
            #expect(args.suffix(2) == ["--mtp-depth", "3"])
        }
        #expect(throws: (any Error).self) {
            _ = try ClusterPlacementTensorAssistantSelection.arguments(modelDirectory: "/fixture/model", policy: policy,
                promptTokens: 32768, outputTokens: 32768, lanes: 3, chunkTokens: 128)
        }
        #expect(throws: (any Error).self) { try quote.requireAssistant(nil) }
        #expect(throws: (any Error).self) {
            try quote.requireAssistant(.init(depth: 2, inventorySHA256: hash("9")))
        }
    }

}

private final class FeatureReadyOwner: DistributedResidentExecutionOwner, @unchecked Sendable {
    let ready: DistributedResidentReadiness?
    init(_ ready: DistributedResidentReadiness?) { self.ready = ready }
    func readiness() -> DistributedResidentReadiness? { ready }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork { .unbounded(reason: nil) }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity, profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease { throw DistributedEngineError.unavailable }
    func shutdown() async {}
}
private struct FeatureTokenizer: Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String) throws -> [Int] { [] }

}
