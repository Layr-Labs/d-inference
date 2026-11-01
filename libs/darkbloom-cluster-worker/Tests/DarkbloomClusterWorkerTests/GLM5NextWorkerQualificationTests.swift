import CryptoKit
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

final class GLM5NextWorkerQualificationTests: XCTestCase {
    typealias Qualification = GLM5NextWorkerQualification
    private let epoch = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

    private func arguments() -> [String] {
        ["--model-dir", "/invented/model", "--rank", "0", "--stage-cut", "22",
         "--membership-epoch", epoch.uuidString.lowercased(), "--model-id", Qualification.modelID,
         "--artifact-sha256", String(repeating: "a", count: 64),
         "--configuration-sha256", String(repeating: "b", count: 64),
         "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
         "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
         "--deadline-uptime-nanoseconds", "120000000100",
         "--glm-qualification", "/private/test/evidence.json", "--qualification-switches", "yes",
         "--keep-warm", "off", "--data-plane", "encrypted_v1"]
    }
    func testExplicitPrivateSelectionDoesNotRegisterModelAndRejectsUnsupportedModes() throws {
        let value = try WorkerConfiguration(arguments: arguments(), now: 100)
        XCTAssertNil(value.family)
        XCTAssertNil(ClusterResidentModelCatalog.entry(runtimeModelID: Qualification.modelID))
        XCTAssertEqual(value.load.allocatorPolicy, .disableFreedBufferCache)
        XCTAssertFalse(value.keepWarm)
        for key in ["--glm-qualification", "--qualification-switches", "--keep-warm", "--data-plane"] {
            var args = arguments(); let index = try XCTUnwrap(args.firstIndex(of: key))
            args.removeSubrange(index...index + 1)
            XCTAssertThrowsError(try WorkerConfiguration(arguments: args, now: 100))
        }
        for extra in [["--generation-mode", "pipeline_mtp_v1"], ["--mtp-depth", "1"],
                      ["--tensor-shares", "1:1"], ["--evidence-directory", "/tmp/recording"],
                      ["--prefix-ssd-key", "darkbloom/prefix-ssd-key/input-line/v1"]] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments() + extra, now: 100))
        }
        var publicArgs = arguments(); publicArgs[9] = "registered_qwen35_9b"
        XCTAssertThrowsError(try WorkerConfiguration(arguments: publicArgs, now: 100))
        for path in ["relative", "/a/../evidence", "/a//evidence", "/a/\nfile"] {
            var args = arguments(); args[25] = path
            XCTAssertThrowsError(try WorkerConfiguration(arguments: args, now: 100))
        }
    }

    private func payload() -> Qualification.Payload {
        .init(version: 1, epoch: epoch, rank: 0, expiresUnixSeconds: 1200,
            repository: "synthetic/test", revision: String(repeating: "a", count: 40), files: [:],
            artifactSHA256: String(repeating: "b", count: 64), cut: 22, profileID: "test",
            maximumPromptTokens: 128, maximumChunkTokens: 16, maximumOutputTokens: 8, maximumContextTokens: 256,
            policy: "serving_v1", storage: "nvfp4Hybrid", loadCapacityBytes: 1 << 30,
            requestCapacityBytes: 64 << 20, hostAllocationQuantum: 4096, hostAllocationOverhead: 128,
            environment: .init(binarySHA256: String(repeating: "c", count: 64),
                metallibSHA256: String(repeating: "d", count: 64), backend: "jaccl",
                allocator: "disableFreedBufferCache", os: "synthetic", deviceRegistryID: 1,
                deviceName: "synthetic", architecture: "synthetic", maximumBufferBytes: 1 << 30,
                recommendedWorkingSetBytes: 1 << 30, memoryBytes: 1 << 30, variableSHA256: [:]),
            workspaceEvidence: Data("signed-workspace".utf8))
    }
    func testMemberSignatureLaunchFreshnessAndExactPayloadAreRequiredBeforeInspection() throws {
        let key = P256.Signing.PrivateKey()
        let bytes = try JSONEncoder().encode(payload())
        let signature = try key.signature(for: Qualification.domain + bytes).rawRepresentation
        let document = try JSONEncoder().encode(Qualification.SignedDocument(payload: bytes, signature: signature))
        func decode(_ data: Data, signer: Data? = nil, epoch: UUID? = nil, rank: Int = 0, now: Int64 = 1000) throws {
            _ = try Qualification.decode(data, memberPublicKey: signer ?? key.publicKey.x963Representation,
                epoch: epoch ?? self.epoch, rank: rank, now: now)
        }
        try decode(document)
        XCTAssertThrowsError(try decode(document, signer: P256.Signing.PrivateKey().publicKey.x963Representation))
        XCTAssertThrowsError(try decode(document, epoch: UUID()))
        XCTAssertThrowsError(try decode(document, rank: 1))
        XCTAssertThrowsError(try decode(document, now: 1200))
        XCTAssertThrowsError(try decode(document, now: -3000))
        let changed = try JSONEncoder().encode(Qualification.SignedDocument(payload: bytes + Data([32]), signature: signature))
        XCTAssertThrowsError(try decode(changed))
        XCTAssertThrowsError(try decode(Data(repeating: 0, count: (256 << 10) + 1)))
        let original = try Qualification.hash(payload().environment)
        XCTAssertEqual(original, try Qualification.hash(payload().environment))
    }

    private final class UnfencedRuntime: WorkerRuntime, @unchecked Sendable {
        let readiness: ClusterWorkerReady?
        init(epoch: UUID) {
            readiness = .init(identity: .init(membershipEpoch: epoch, modelID: Qualification.modelID,
                artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
                peers: [.init(id: "one", buildSHA256: String(repeating: "c", count: 64)),
                        .init(id: "two", buildSHA256: String(repeating: "d", count: 64))]),
                rank: 0, profile: .init(id: "test", vocabularySize: 32, maximumPromptTokens: 128,
                    maximumOutputTokens: 8, maximumChunkTokens: 16, maximumContextTokens: 256),
                executionPlanSHA256: String(repeating: "e", count: 64), requestCapacityBytes: 4096)
        }
        func reserve(_ id: UUID, _ value: ClusterWorkerReservation) throws -> Int { throw WorkerFailure.invalid("unused") }
        func start(_ id: UUID, token: (Int, Int, Int) throws -> Bool) throws -> ClusterWorkerFinishReason { throw WorkerFailure.invalid("unused") }
        func cancel(_ id: UUID) {}
        func shutdown() throws { throw GLM5NextWorkerRuntime.shutdownRefusal() }
        func keepWarmPulse() throws -> UInt64 { throw WorkerFailure.invalid("unused") }
        func dataPlanePing() throws -> UInt64 { throw WorkerFailure.invalid("unused") }
    }
    private final class Exits: @unchecked Sendable {
        let lock = NSLock()
        private var values: [String] = []
        func append(_ reason: String) { lock.lock(); values.append(reason); lock.unlock() }
        var reasons: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    func testUnfencedShutdownTriggersForcedExitWithoutCleanAcknowledgement() throws {
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { XCTFail("pipe"); return }
        defer { close(input[0]); close(input[1]) }
        guard pipe(&output) == 0 else { XCTFail("pipe"); return }
        defer { close(output[0]); close(output[1]) }
        let runtime = UnfencedRuntime(epoch: epoch), exits = Exits()
        let command = try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: epoch,
            sequence: 0, requestID: nil, command: .shutdown))
        let written = command.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }
        XCTAssertEqual(written, command.count)
        do {
            let pipes = try WorkerPipes(input: input[0], output: output[1],
                deadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
            let coordinator = try WorkerCoordinator(runtime: runtime, pipes: pipes,
                exitHooks: .init(begin: { exits.append($0) }))
            XCTAssertThrowsError(try coordinator.run())
        }
        XCTAssertTrue(exits.reasons.contains("worker-failure"))
        var events = Data(), fd = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
        while poll(&fd, 1, 0) > 0 {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(output[0], &buffer, buffer.count)
            guard count > 0 else { break }
            events.append(contentsOf: buffer.prefix(count))
        }
        let frames = try events.split(separator: 10).map { try ClusterWorkerCodec.decodeEvent(Data($0) + Data([10])) }
        XCTAssertFalse(frames.isEmpty)
        for frame in frames {
            if case .shutdownComplete = frame.event { XCTFail("Unfenced shutdown published clean retirement") }
        }
    }

    func testSignedHostRoundingDoesNotOverflowOrDiscountAllocations() throws {
        XCTAssertEqual(try Qualification.hostBound(4097, quantum: 4096, overhead: 128), 8320)
        XCTAssertThrowsError(try Qualification.hostBound(Int.max, quantum: 4096, overhead: 0))
        XCTAssertThrowsError(try Qualification.hostBound(Int.max, quantum: 1, overhead: 1))
        XCTAssertThrowsError(try Qualification.hostBound(1, quantum: 0, overhead: 0))
    }
}
