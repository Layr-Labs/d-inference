import DarkbloomClusterProtocol
import Foundation
import XCTest
@testable import DarkbloomClusterRuntime

final class ResidentFacadeTests: XCTestCase {
    private func fixture() throws -> (Data, Data, [QwenDenseCanonicalTensor]) {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["DARKBLOOM_RETAINED_PROFILE_FIXTURE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(sha256(data), "1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nine = try XCTUnwrap(root["nine"] as? [String: Any])
        let config = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(nine["configuration"] as? String)))
        let manifest = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(nine["manifest"] as? String)))
        let tensors = try JSONDecoder().decode([QwenDenseCanonicalTensor].self,
            from: JSONSerialization.data(withJSONObject: XCTUnwrap(nine["canonicalTensors"])))
        return (config, manifest, tensors)
    }
    private func configuration(cut: Int = 12, rank: Int = 0, model: String = "registered_qwen35_9b",
                               deadline: UInt64 = 300_000_000_100,
                               policy: QwenResidentAllocatorPolicy = .unchanged) -> QwenResidentLoadConfiguration {
        let spec = QwenDenseRegisteredSpecification.all[0]
        return .init(identity: .init(membershipEpoch: UUID(), modelID: model,
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            peers: [.init(id: "a", buildSHA256: String(repeating: "a", count: 64)),
                    .init(id: "b", buildSHA256: String(repeating: "b", count: 64))]),
            modelDirectory: URL(fileURLWithPath: "/invented/model"), rank: rank,
            stageCut: cut, deadlineUptimeNanoseconds: deadline, allocatorPolicy: policy)
    }
    private func environment(rank: Int = 0) -> [String: String] {
        QwenLongPrefillArithmeticEnvironment.requiredValues.merging([
            "MLX_RANK": String(rank), "MLX_IBV_DEVICES": "/invented/devices.json",
            "MLX_JACCL_COORDINATOR": "169.254.1.1:15000",
        ], uniquingKeysWith: { _, new in new })
    }
    private func admission(cut: Int = 12, rank: Int = 0) throws -> QwenResidentAdmission {
        let (config, manifest, _) = try fixture()
        return try .init(configuration: configuration(cut: cut, rank: rank), configBytes: config,
            manifestBytes: manifest, environment: environment(rank: rank), now: 100,
            read: { _, _ in Data("[[null,\"rdma_en1\"],[\"rdma_en1\",null]]".utf8) })
    }
    private func reservation(output: Int = 128, prompt: [Int] = Array(repeating: 17, count: 8192),
                             stops: [Int] = [42], deadline: UInt64 = 1000) -> ClusterWorkerReservation {
        .init(profileID: QwenResidentAdmission.profileID, promptTokenIDs: prompt, stopTokenIDs: stops,
            outputCount: output, chunkSize: 512, deadlineUptimeNanoseconds: deadline, capacityLimitBytes: 1 << 40)
    }

    func testExactCutsAndBothLocalRanks() throws {
        for cut in [4, 8, 12, 16] { for rank in [0, 1] {
            let value = try admission(cut: cut, rank: rank)
            XCTAssertEqual(value.plan.stages[0].sourceRange.upperBound, cut)
            XCTAssertEqual(value.jaccl.rank, rank)
            let request = try value.request(reservation(), id: UUID(), now: 101)
            XCTAssertEqual(request.maximumTokens, 8320)
            XCTAssertEqual(request.forwardCount, 143)
            XCTAssertEqual(request.finalCommittedTokens, 8319)
        } }
    }

    func testCut4And8UseCompleteRegisteredPartitionAndIntervalPhase() throws {
        let (config, _, tensors) = try fixture()
        let expectedPlans = [
            4: "67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f",
            8: "0f287a057042275470eeab37596b621d1134061db0c1fd9ef9b09022ea81da92",
        ]
        for cut in [4, 8] {
            let plan = try admission(cut: cut).plan
            XCTAssertEqual(plan.fingerprint, expectedPlans[cut])
            XCTAssertEqual(plan.stages.map(\.sourceRange), [0..<cut, cut..<32])
            XCTAssertEqual(plan.stages.flatMap { $0.layers.map(\.globalIndex) }, Array(0..<32))
            for stage in plan.stages {
                XCTAssertEqual(stage.layers.map(\.localIndex), Array(0..<stage.sourceRange.count))
                for layer in stage.layers {
                    XCTAssertEqual(layer.globalIndex, stage.sourceRange.lowerBound + layer.localIndex)
                    XCTAssertEqual(layer.kind, (layer.localIndex + 1) % 4 == 0 ? "full_attention" : "linear_attention")
                }
            }
            let mapping = try plan.parameters(canonicalSourceNames: tensors.map(\.name))
            let byName = Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0) })
            XCTAssertEqual(mapping.count, 927)
            XCTAssertEqual(Set(mapping.map(\.sourceName)), Set(tensors.map(\.name)))
            XCTAssertEqual(Set(mapping.map { "\($0.stage):\($0.localName)" }).count, 927)
            XCTAssertEqual([0, 1].map { rank in mapping.filter { $0.stage == rank }.count }, cut == 4 ? [118, 809] : [233, 694])
            for rank in [0, 1] {
                let selected = try mapping.filter { $0.stage == rank }.map { try XCTUnwrap(byName[$0.sourceName]) }
                let bytes = cut == 4 ? [1_058_851_136, 3_979_190_464] : [1_545_572_992, 3_492_468_608]
                XCTAssertEqual(selected.reduce(0) { $0 + $1.byteCount }, bytes[rank])
                XCTAssertEqual(selected.filter { $0.sourceDType == "F32" }.count, (cut == 4 ? [3, 21] : [6, 18])[rank])
            }
            XCTAssertEqual(try plan.parameter(canonicalSourceName: "language_model.model.embed_tokens.weight")?.stage, 0)
            XCTAssertEqual(try plan.parameter(canonicalSourceName: "language_model.model.norm.weight")?.stage, 1)
            XCTAssertEqual(try plan.parameter(canonicalSourceName: "language_model.lm_head.weight")?.stage, 1)
        }
        for ranges in [[0..<3, 3..<32], [0..<5, 5..<32], [0..<7, 7..<32], [0..<9, 9..<32], [0..<8, 9..<32], [0..<8, 7..<32]] {
            XCTAssertThrowsError(try QwenLayerStagePlan(configuration: config, ranges: ranges, activeMTP: false))
        }
    }

    func testWrongClosedMetadataRefusesBeforeDeviceFileRead() throws {
        let (config, manifest, _) = try fixture()
        for value in [configuration(cut: 7), configuration(cut: 9), configuration(cut: 10),
                      configuration(cut: 11), configuration(cut: 13), configuration(cut: 15),
                      configuration(cut: 17), configuration(cut: 20), configuration(cut: 28),
                      configuration(cut: 0), configuration(cut: 32), configuration(rank: 2), configuration(model: "registered_qwen38_27b"),
                      configuration(deadline: 100), configuration(deadline: 300_000_000_101)] {
            var reads = 0
            XCTAssertThrowsError(try QwenResidentAdmission(configuration: value, configBytes: config,
                manifestBytes: manifest, environment: environment(), now: 100,
                read: { _, _ in reads += 1; return Data() }))
            XCTAssertEqual(reads, 0)
        }
        var reads = 0
        XCTAssertThrowsError(try QwenResidentAdmission(configuration: configuration(), configBytes: config + Data([32]),
            manifestBytes: manifest, environment: environment(), now: 100,
            read: { _, _ in reads += 1; return Data() }))
        XCTAssertEqual(reads, 0)
    }

    func testEffectiveJACCLEnvironmentAndArithmeticRefuse() throws {
        let (config, manifest, _) = try fixture()
        for extra in [["JACCL_RANK":"1"], ["MLX_METAL_GPU_ARCH":""], ["MLX_ENABLE_TF32":"0"]] {
            var reads = 0
            XCTAssertThrowsError(try QwenResidentAdmission(configuration: configuration(), configBytes: config,
                manifestBytes: manifest, environment: environment().merging(extra, uniquingKeysWith: { _, v in v }), now: 100,
                read: { _, _ in reads += 1; return Data() }))
            XCTAssertEqual(reads, 0)
        }
    }

    func testReservationBoundsAndTinyPromptWithLargeChunk() throws {
        let value = try admission()
        XCTAssertEqual(try value.request(reservation(output: 1, prompt: [17]), id: UUID(), now: 101).forwardCount, 1)
        for request in [reservation(output: 129), reservation(prompt: []), reservation(stops: [42, 42]),
                        reservation(stops: [42, 17]), reservation(prompt: [248320]), reservation(deadline: 101)] {
            XCTAssertThrowsError(try value.request(request, id: UUID(), now: 101))
        }
    }

    func testNamedAllowanceUsesRealProfileAndPreservesAllocatorErrors() throws {
        let (config, manifest, tensors) = try fixture()
        let profile = try QwenRegisteredDenseModelProfile.admit(configuration: config, manifest: manifest,
            expectedArtifactAggregateSHA256: QwenDenseRegisteredSpecification.all[0].artifactSHA256, canonicalTensors: tensors)
        let plan = try profile.makePlanningPlan(stageCut: 12)
        for rank in [0, 1] {
            let logical = try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: rank,
                maximumTokens: 8320, chunkSize: 512, bound: { $0 })
            XCTAssertEqual(logical.stateBytes, 754_188_320)
            let selected = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: rank == 0 ? .stage0 : .stage1)
            XCTAssertEqual(logical.fusionBytes, selected.fusionReplacementBytes)
            XCTAssertEqual(logical.reservedBytes, logical.stateBytes + logical.fusionBytes)
            let padded = try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: rank,
                maximumTokens: 8320, chunkSize: 512, bound: { $0 + 16384 })
            XCTAssertGreaterThan(padded.reservedBytes, logical.reservedBytes)
        }
        enum Marker: Error { case original }
        XCTAssertThrowsError(try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: 0,
            maximumTokens: 8320, chunkSize: 512, bound: { _ in throw Marker.original })) { error in
                guard case Marker.original = error else { return XCTFail("Allocator error replaced") }
        }
        XCTAssertThrowsError(try QwenResidentRequestAllowance.derive(profile: profile, plan: plan, rank: 0,
            maximumTokens: 8320, chunkSize: 512, bound: { $0 - 1 }))
    }

    func testDefaultAllocatorPolicyHasNoOperationsAndExplicitZeroOrdersChecks() throws {
        XCTAssertEqual(configuration().allocatorPolicy, .unchanged)
        var calls: [String] = []
        try QwenResidentAllocatorPolicy.unchanged.configure(setCacheLimit: { _ in calls.append("set") }, check: { calls.append("check") })
        try QwenResidentAllocatorPolicy.unchanged.prepareReady(synchronize: { calls.append("sync") },
            snapshot: { calls.append("snapshot"); return .init(activeBytes: -1, cachedBytes: -1, peakBytes: -1) },
            clearCache: { calls.append("clear") }, check: { calls.append("check") })
        XCTAssertTrue(calls.isEmpty)
        try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(
            setCacheLimit: { limit in XCTAssertEqual(limit, 0); calls.append("set0") }, check: { calls.append("check") })
        XCTAssertEqual(calls, ["check", "set0", "check"])
        calls = []; var snapshots = 0
        try QwenResidentAllocatorPolicy.disableFreedBufferCache.prepareReady(synchronize: { calls.append("sync") },
            snapshot: {
                calls.append("snapshot"); snapshots += 1
                return .init(activeBytes: 100, cachedBytes: snapshots == 1 ? 200 : 0, peakBytes: 300)
            }, clearCache: { calls.append("clear") }, check: { calls.append("check") })
        XCTAssertEqual(calls, ["check", "sync", "check", "snapshot", "clear", "check", "snapshot"])
    }

    func testAllocatorPolicyRejectsChangedStorageAndInvalidSnapshots() throws {
        let before = QwenResidentAllocatorSnapshot(activeBytes: 100, cachedBytes: 200, peakBytes: 300)
        let valid = QwenResidentAllocatorSnapshot(activeBytes: 100, cachedBytes: 0, peakBytes: 300)
        let pairs: [(QwenResidentAllocatorSnapshot, QwenResidentAllocatorSnapshot)] = [
            (before, .init(activeBytes: 100, cachedBytes: 1, peakBytes: 300)),
            (before, .init(activeBytes: 101, cachedBytes: 0, peakBytes: 300)),
            (before, .init(activeBytes: 100, cachedBytes: 0, peakBytes: 301)),
            (before, .init(activeBytes: 100, cachedBytes: 0, peakBytes: 99)),
            (.init(activeBytes: -1, cachedBytes: 200, peakBytes: 300), valid),
            (.init(activeBytes: 100, cachedBytes: -1, peakBytes: 300), valid),
            (.init(activeBytes: 100, cachedBytes: 200, peakBytes: 99), valid),
        ]
        for pair in pairs {
            var snapshots = 0
            XCTAssertThrowsError(try QwenResidentAllocatorPolicy.disableFreedBufferCache.prepareReady(synchronize: {},
                snapshot: { snapshots += 1; return snapshots == 1 ? pair.0 : pair.1 }, clearCache: {}, check: {}))
        }
    }

    func testAllocatorPolicyPreservesFailureAndStopsSubsequentOperations() throws {
        enum Marker: Error { case original }
        var calls: [String] = []
        XCTAssertThrowsError(try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(
            setCacheLimit: { _ in calls.append("set"); throw Marker.original }, check: { calls.append("check") })) { error in
                guard case Marker.original = error else { return XCTFail("Setter failure replaced") }
        }
        XCTAssertEqual(calls, ["check", "set"])
        for failAt in 1...3 {
            var checks = 0, clears = 0, snapshots = 0
            XCTAssertThrowsError(try QwenResidentAllocatorPolicy.disableFreedBufferCache.prepareReady(synchronize: {},
                snapshot: { snapshots += 1; return .init(activeBytes: 1, cachedBytes: 0, peakBytes: 1) },
                clearCache: { clears += 1 }, check: { checks += 1; if checks == failAt { throw Marker.original } })) { error in
                    guard case Marker.original = error else { return XCTFail("Native/deadline check failure replaced") }
            }
            XCTAssertEqual(checks, failAt)
            XCTAssertEqual(clears, failAt == 3 ? 1 : 0)
            XCTAssertEqual(snapshots, failAt == 3 ? 1 : 0)
        }
    }

    func testLoadAgreementBindsAllocatorPolicyButExcludesLocalLabels() throws {
        let (config, manifest, _) = try fixture()
        let common = configuration(cut: 4).identity
        func admitted(rank: Int, policy: QwenResidentAllocatorPolicy, path: String, deadline: UInt64) throws -> QwenResidentAdmission {
            let value = QwenResidentLoadConfiguration(identity: common, modelDirectory: URL(fileURLWithPath: path),
                rank: rank, stageCut: 4, deadlineUptimeNanoseconds: deadline, allocatorPolicy: policy)
            var env = environment(rank: rank); env["MLX_IBV_DEVICES"] = path + "/devices.json"
            return try .init(configuration: value, configBytes: config, manifestBytes: manifest, environment: env, now: 100,
                read: { _, _ in Data("[[null,\"rdma_en1\"],[\"rdma_en1\",null]]".utf8) })
        }
        let rank0 = try admitted(rank: 0, policy: .disableFreedBufferCache, path: "/invented/left", deadline: 1000)
        let rank1 = try admitted(rank: 1, policy: .disableFreedBufferCache, path: "/invented/right", deadline: 2000)
        XCTAssertEqual(try rank0.loadAgreementFingerprint(), try rank1.loadAgreementFingerprint())
        let defaultPolicy = try admitted(rank: 0, policy: .unchanged, path: "/invented/left", deadline: 1000)
        XCTAssertNotEqual(try rank0.loadAgreementFingerprint(), try defaultPolicy.loadAgreementFingerprint())
    }

    func testLoadAgreementBindsPrefillSelectionBeforeEitherStageLoads() throws {
        let (config, manifest, _) = try fixture()
        let common = configuration(cut: 4).identity
        func admitted(rank: Int, schedule: ClusterPrefillSchedule) throws -> QwenResidentAdmission {
            let value = QwenResidentLoadConfiguration(identity: common, modelDirectory: URL(fileURLWithPath: "/invented/model"),
                rank: rank, stageCut: 4, deadlineUptimeNanoseconds: 1000, prefillSchedule: schedule)
            return try .init(configuration: value, configBytes: config, manifestBytes: manifest,
                environment: environment(rank: rank), now: 100,
                read: { _, _ in Data("[[null,\"rdma_en1\"],[\"rdma_en1\",null]]".utf8) })
        }
        let serial0 = try admitted(rank: 0, schedule: .serial)
        let serial1 = try admitted(rank: 1, schedule: .serial)
        let lookahead0 = try admitted(rank: 0, schedule: .oneChunkLookahead)
        let lookahead1 = try admitted(rank: 1, schedule: .oneChunkLookahead)
        XCTAssertEqual(try serial0.loadAgreementFingerprint(), try serial1.loadAgreementFingerprint())
        XCTAssertEqual(try lookahead0.loadAgreementFingerprint(), try lookahead1.loadAgreementFingerprint())
        XCTAssertNotEqual(try serial0.loadAgreementFingerprint(), try lookahead1.loadAgreementFingerprint())
        XCTAssertEqual(serial0.plan.fingerprint, lookahead0.plan.fingerprint)
    }

    func testCancellationCannotAffectAnotherRequestAndActiveCloseRefuses() throws {
        let state = QwenResidentControl(deadline: DispatchTime.now().uptimeNanoseconds + 300_000_000_000)
        let id = UUID()
        XCTAssertThrowsError(try state.reserve(id))
        try state.loaded(); try state.reserve(id)
        state.cancel(UUID()); try state.check(); try state.start(id)
        XCTAssertThrowsError(try state.beginClose())
        state.cancel(id)
        XCTAssertFalse(state.available)
        XCTAssertThrowsError(try state.check())
        XCTAssertThrowsError(try state.completed(id))
        state.fail(); try state.beginClose(); state.closed()
    }

    func testReplayAndFiniteRequestLifetime() throws {
        let state = QwenResidentControl(deadline: DispatchTime.now().uptimeNanoseconds + 300_000_000_000)
        try state.loaded()
        let first = UUID()
        for id in [first] + (0..<15).map({ _ in UUID() }) {
            try state.reserve(id); try state.start(id); try state.completed(id)
        }
        XCTAssertFalse(state.available)
        XCTAssertThrowsError(try state.reserve(first))
        XCTAssertThrowsError(try state.reserve(UUID()))
        try state.beginClose(); state.closed()
    }
}
