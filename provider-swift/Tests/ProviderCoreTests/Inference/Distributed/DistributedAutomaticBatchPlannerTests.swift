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

    private func profile() throws -> ClusterDeviceProfile {
        let physical = 256 * gib, free = 200 * gib
        var p = try ClusterDeviceProfile(chip: "Constructed planner fixture", performanceCores: 8, efficiencyCores: 4,
            gpuCores: 40, osVersion: "27.0", osBuild: "CHECK", physicalMemoryBytes: physical,
            gpuRecommendedWorkingSetBytes: 192 * gib, gpuMaximumBufferBytes: 128 * gib,
            allocatorLimitBytes: 230 * gib,
            memory: .init(gatePolicy: "fixture", sampledUTC: "2026-10-23T00:00:00Z", judged: true, unjudgedReason: nil,
                physicalMemoryBytes: physical, actualFreeBytes: free, countedFileCacheBytes: 0, admissibleNowBytes: free,
                fileBackedBytes: 0, fileCacheReserveBytes: 0, fileCacheAboveReserveBytes: 0, anonymousBytes: 52 * gib,
                wiredBytes: 4 * gib, compressorBytes: 0, pageableBytes: 252 * gib, pressureLevel: 1, swapUsedBytes: 0,
                minimumAdmissibleBytes: 6 * gib, minimumTrulyFreeBytes: 16 * 1_048_576, loadingHeadroomBytes: 4 * gib,
                allocatorHeadroomBytes: 2 * gib, loadScratchBytes: 8 * 1_048_576, pageSizeBytes: 16_384),
            power: .init(onExternalPower: true, lowPowerMode: false, thermalState: "nominal"))
        p.speedIndex = .init(chip: p.chip, osBuild: p.osBuild, benchmark: "qmm_h4096_b4_g64_x16_v1",
            prefillIndex: 1_000_000, decodeIndex: 25_000)
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
        func write(model: String, ranks: [String], concurrent: Int, cached: Int = 0) throws {
            let records = (0..<3).map { index in
                ClusterPairRequestTelemetry(requestID: "fixture-\(index)", finishedAt: Date().timeIntervalSince1970,
                    modelID: model, mode: "tensor_parallel_v1", cut: "0-2|0-2", promptTokens: 1024, cachedTokens: cached,
                    completionTokens: 128, firstTokenMilliseconds: 1000, decodeTokensPerSecond: 1,
                    handoffMilliseconds: nil, handoffBytes: nil, mtpDrafted: nil, mtpAccepted: nil, outcome: "length",
                    route: "pair", ranks: ranks, concurrentRequests: concurrent)
            }
            let json: [String: Any] = ["schema": ClusterServedSpeedFile.schemaName, "updatedAt": Date().timeIntervalSince1970,
                "records": try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))]
            let file = ClusterServedSpeedFile.defaultFile(homeDirectory: home)
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        for (model, ranks, concurrent) in [("other", ["a", "b"], 0), ("fixture-model", ["a", "other"], 0),
                                           ("fixture-model", ["a", "b"], 1)] {
            try write(model: model, ranks: ranks, concurrent: concurrent)
            #expect(!(try decide(home).lines.contains("Speed records from served requests")))
        }
        try write(model: "fixture-model", ranks: ["a", "b"], concurrent: 0, cached: 128)
        #expect(!(try decide(home).lines.contains("Speed records from served requests")))
        try write(model: "fixture-model", ranks: ["a", "b"], concurrent: 0)
        let result = try decide(home)
        #expect(result.lines.contains("Speed records from served requests"))
        #expect(result.lines.contains { $0.contains("tensor_parallel_v1") && $0.contains("request(s)") })
        #expect(result.result.tensorParallel?.devices.contains { $0.split.measured } == true)
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

    @Test func testProfileChildMustReceiveIndexArgument() throws {
        let home = try home(), expected = try profile()
        try expected.encoded().write(to: home.appendingPathComponent("profile.json"))
        let child = home.appendingPathComponent("plan-helper")
        let script = """
            #!/bin/sh
            [ "$#" = 3 ] && [ "$1" = device ] && [ "$2" = --json ] && [ "$3" = --index ] || exit 17
            exec /bin/cat "\(home.path)/profile.json"
            """
        try Data(script.utf8).write(to: child)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
        let actual = try DistributedAutomaticBatchPlanner.deviceProfile(tool: child,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        #expect(actual.speedIndex == expected.speedIndex)
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
        // registration retain the ordinary cheaper-pipeline policy.
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
        #expect(ordinary.chosen?.mode == .pipeline)
        let sameTP = try #require(ordinary.alternatives.first { $0.mode == .tensorParallel })
        let requiredTP = try #require(required.chosen)
        #expect(sameTP.prediction(.rested) == requiredTP.prediction(.rested))
        #expect(ClusterModelFeaturePolicy.admissibleModes(other) == other.supportedGenerationModes)
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
