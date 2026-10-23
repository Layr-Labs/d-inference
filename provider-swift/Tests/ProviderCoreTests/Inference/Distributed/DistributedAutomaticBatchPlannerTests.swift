import Darwin
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import Foundation
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
        #expect(before.result.chosen?.mode == .pipeline)
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

    @Test func testForeignStaleMalformedAndNonPrivateMeasurementsKeepFallback() throws {
        for kind in ["foreign", "stale", "malformed", "public"] {
            let home = try home()
            record(home, members: kind == "foreign" ? ["a", "other"] : ["a", "b"],
                now: Date().timeIntervalSince1970 - (kind == "stale" ? ClusterLinkProbeHistory.maximumAgeSeconds + 1 : 0))
            let file = ClusterLinkProbeHistory.defaultFile(homeDirectory: home)
            if kind == "malformed" { try Data("{}".utf8).write(to: file) }
            if kind == "public" { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
            let result = try decide(home)
            #expect(result.result.chosen?.mode == .pipeline, Comment(rawValue: kind))
            #expect(result.result.tensorParallel?.verdict == .reductionNotMeasured, Comment(rawValue: kind))
        }
    }

    @Test func testUnkeyedMeasurementDoesNotEnableTensorPlacement() throws {
        let home = try home(); record(home, keyed: false)
        let result = try decide(home)
        #expect(result.result.chosen?.mode == .pipeline)
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
}
