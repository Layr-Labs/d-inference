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
                               deadline: UInt64 = 300_000_000_100) -> QwenResidentLoadConfiguration {
        let spec = QwenDenseRegisteredSpecification.all[0]
        return .init(identity: .init(membershipEpoch: UUID(), modelID: model,
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            peers: [.init(id: "a", buildSHA256: String(repeating: "a", count: 64)),
                    .init(id: "b", buildSHA256: String(repeating: "b", count: 64))]),
            modelDirectory: URL(fileURLWithPath: "/invented/model"), rank: rank,
            stageCut: cut, deadlineUptimeNanoseconds: deadline)
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
        for cut in [12, 16] { for rank in [0, 1] {
            let value = try admission(cut: cut, rank: rank)
            XCTAssertEqual(value.plan.stages[0].sourceRange.upperBound, cut)
            XCTAssertEqual(value.jaccl.rank, rank)
            let request = try value.request(reservation(), id: UUID(), now: 101)
            XCTAssertEqual(request.maximumTokens, 8320)
            XCTAssertEqual(request.forwardCount, 143)
            XCTAssertEqual(request.finalCommittedTokens, 8319)
        } }
    }

    func testWrongClosedMetadataRefusesBeforeDeviceFileRead() throws {
        let (config, manifest, _) = try fixture()
        for value in [configuration(cut: 8), configuration(rank: 2), configuration(model: "registered_qwen38_27b"),
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
