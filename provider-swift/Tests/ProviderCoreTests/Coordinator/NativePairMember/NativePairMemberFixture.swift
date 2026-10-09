import CryptoKit
import Darwin
import Foundation
import Network
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
@testable import ProviderCore

// Fixtures for the member control tests that run a REAL owner process and
// native child (the `cluster-member-fixture-child` helper, CPU only) over the
// real owner pipe and key prelude. The coordinator is the plain-WebSocket
// mock, so these prove control flow and process ownership, never TLS,
// hardware trust, a mesh or a model.

private final class MemberFixtureBundleAnchor {}

/// A software P-256 signer that can block inside one chosen `sign` call.
final class MemberFixtureSigner: AttestationSigner, @unchecked Sendable {
    let key = P256.Signing.PrivateKey()
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private let entered = DispatchGroup()
    private var pauseAt: Int?, calls = 0
    init() { entered.enter() }
    func pause(onCall number: Int) { lock.withLock { pauseAt = number } }
    var isPaused: Bool { entered.wait(timeout: .now()) == .success }
    func resume() { release.signal() }
    var publicKeyBase64: String { Data(key.publicKey.x963Representation.dropFirst()).base64EncodedString() }
    func sign(_ data: Data) throws -> Data {
        let pause = lock.withLock { calls += 1; return pauseAt == calls }
        if pause { entered.leave(); release.wait() }
        return try key.signature(for: data).derRepresentation
    }
    /// What the coordinator checks on every member frame: a strict-DER P-256
    /// signature over the frame's signing bytes, and no deadline fields.
    func verify(_ message: NativePairMessage) throws {
        let signature = try #require(message.signature.flatMap { Data(base64Encoded: $0) })
        #expect(key.publicKey.isValidSignature(try .init(derRepresentation: signature), for: try message.signingBytes()))
        #expect(message.prepareBeforeUnixNano == nil && message.expiresAtUnixNano == nil)
    }
}

final class NativePairMemberFixture: @unchecked Sendable {
    let root: URL
    let policy: Data
    let starts: [ClusterNativeAuthorizationStart]
    let installations: [NativePairMemberInstallation]
    let prepareUnix, expiresUnix: Int64
    var directories: [URL] { (0..<2).map { root.appendingPathComponent("rank-\($0)") } }

    /// The helper built beside this test bundle.
    static func helper() throws -> Data {
        let bundle = Bundle(for: MemberFixtureBundleAnchor.self).bundleURL
        let products = bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle
        let bytes = try Data(contentsOf: products.appendingPathComponent("cluster-member-fixture-child"))
        try #require(bytes.count > 0 && bytes.count < 64 * 1024 * 1024)
        return bytes
    }

    /// The installed-file checks refuse symlinked path components, and the
    /// default temporary directory is reached through `/var`.
    static func privateRoot() throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        try #require(realpath(NSTemporaryDirectory(), &buffer) != nil)
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        let parent = String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let root = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent("native-member-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    init(lifetimeSeconds: Int64 = 12, preparationSeconds: Int64 = 5, behavior: String = "key-only",
         ownerServesCommittedStart: Bool = true) throws {
        let helperBytes = try Self.helper()
        root = try Self.privateRoot()
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        prepareUnix = now + preparationSeconds * 1_000_000_000
        expiresUnix = now + lifetimeSeconds * 1_000_000_000
        let native = Data(SHA256.hash(data: helperBytes))
        var hashes = (0..<8).map { memberDigest("member-fixture-hash-\($0)") }
        hashes[2] = native
        hashes[3] = memberDigest("cpu-metallib-placeholder")
        hashes[4] = memberDigest("cpu-resource-placeholder")
        var p = Data("darkbloom/coordinator-native-runtime-approval/v1\0".utf8)
        func integer<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
            for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { p.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        func string(_ text: String) { let bytes = Data(text.utf8); integer(UInt32(bytes.count)); p.append(bytes) }
        string("explicit-cpu-fixture-only"); string("fixture-model"); integer(UInt64(11))
        hashes.forEach { p.append($0) }; p.append(contentsOf: [1, 1, 2])
        integer(UInt32(4136)); integer(UInt32(4096)); integer(UInt64(64)); integer(UInt64(262144))
        integer(UInt64(now + 3_600_000_000_000)); integer(UInt32(1)); string("Apple M4")
        policy = p
        let common = try ClusterNativeAuthorizationCommon(epoch: UUID(), membershipGeneration: 7, nativePolicyGeneration: 11,
            membershipTranscriptSHA256: memberDigest("fixture-membership-only"),
            approvedNativeBindingSHA256: Data(SHA256.hash(data: p)), planSHA256: hashes[0], artifactSHA256: hashes[1],
            nativeRuntimeSHA256: hashes[2], capabilitySHA256: hashes[5], resourcePolicySHA256: hashes[6], profileSHA256: hashes[7],
            schedule: .oneChunkLookahead, maximumTransportFrameBytes: 4136,
            limits: .init(maximumPlaintextBytes: 4096, maximumRecordsPerDirection: 64, maximumCumulativePlaintextBytesPerDirection: 262144))
        starts = try (0..<2).map { rank in try .init(common: common, rank: rank,
            ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID()) }
        // These must equal what the helper's MemberFixtureConfiguration builds.
        let configurationSHA256 = memberHex(memberDigest("fixture-config"))
        let identity = ClusterWorkerIdentity(membershipEpoch: common.epoch, modelID: "fixture-model",
            artifactSHA256: memberHex(hashes[1]), configurationSHA256: configurationSHA256,
            peers: (0..<2).map { ClusterWorkerPeer(id: "fixture-rank-\($0)", buildSHA256: memberHex(native)) })
        let profile = ClusterWorkerProfile(id: "native-key-cpu-fixture", vocabularySize: 256,
            maximumPromptTokens: 8, maximumOutputTokens: 2, maximumChunkTokens: 4, maximumContextTokens: 16)
        var installed: [NativePairMemberInstallation] = []
        for rank in 0..<2 {
            let directory = root.appendingPathComponent("rank-\(rank)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let owner = directory.appendingPathComponent("owner-fixture")
            try helperBytes.write(to: owner, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: owner.path)
            let metallib = directory.appendingPathComponent("fixture.metallib"), resource = directory.appendingPathComponent("fixture.resource")
            try Data("cpu-metallib-placeholder".utf8).write(to: metallib, options: .withoutOverwriting)
            try Data("cpu-resource-placeholder".utf8).write(to: resource, options: .withoutOverwriting)
            let gate = directory.appendingPathComponent(".darkbloom/cluster-device")
            try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let configuration: [String: String] = ["startBase64": starts[rank].canonicalBytes.base64EncodedString(),
                "clusterID": "native-member-cpu-fixture", "configurationSHA256": configurationSHA256,
                "modelID": "fixture-model", "leaseDirectory": gate.path, "behavior": behavior]
            try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("fixture.json"), options: .withoutOverwriting)
            installed.append(try NativePairMemberInstallation(expectedCoordinatorPolicy: p, rank: rank,
                clusterID: "native-member-cpu-fixture", identity: identity, profile: profile,
                installedOwner: owner, ownerSHA256: memberHex(native), nativeExecutable: owner, metallib: metallib,
                resourceLibrary: resource, chip: "Apple M4", leaseDirectory: gate,
                ownerServesCommittedStart: ownerServesCommittedStart))
        }
        installations = installed
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A coordinator-to-member frame exactly as the coordinator builds it.
    func message(_ type: String, rank: Int, nonce: String, sequence: UInt64, payload: Data? = nil) throws -> NativePairMessage {
        var preparation = Data([68, 66, 78, 80, 82, 1])
        let n = UInt32(policy.count)
        for shift in stride(from: 24, through: 0, by: -8) { preparation.append(UInt8(truncatingIfNeeded: n >> shift)) }
        preparation.append(policy); preparation.append(starts[rank].canonicalBytes)
        let body = payload ?? (type == "native_pair_prepare" ? preparation : starts[rank].canonicalBytes)
        return try .init(type: type, memberNonce: nonce,
            epoch: withUnsafeBytes(of: starts[rank].common.epoch.uuid) { memberHex(Data($0)) },
            generation: 7, sequence: sequence, payload: body,
            prepareBeforeUnixNano: prepareUnix, expiresAtUnixNano: expiresUnix)
    }

    var nativeStarted: [Bool] {
        directories.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("native-started").path) }
    }

    /// The native child that started is gone, the owner's lease journal is
    /// empty and the device gate can be taken again.
    func requireRetired(_ rank: Int, confirmed: Bool) throws {
        let directory = directories[rank]
        let raw = try String(contentsOf: directory.appendingPathComponent("native-started"), encoding: .utf8)
        let pid = try #require(Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        let journal = directory.appendingPathComponent(".darkbloom/cluster-device/native-device.lease")
        #expect(try Data(contentsOf: journal).isEmpty)
        let gate = try ClusterDeviceExclusion(directoryURL: journal.deletingLastPathComponent())
        withExtendedLifetime(gate) {}
        let report = directory.appendingPathComponent("native-public.json")
        if confirmed {
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
            #expect(Set(object.keys) == Set(["rank", "pid", "ownerPID", "transcriptSHA256", "confirmed", "recordTransportConstructed", "modelReadyPublished"]))
            #expect(object["confirmed"] as? Bool == true && object["recordTransportConstructed"] as? Bool == true)
            #expect(object["modelReadyPublished"] as? Bool == false && object["pid"] as? Int == Int(pid))
        } else { #expect(!FileManager.default.fileExists(atPath: report.path)) }
    }
}

func memberFixtureHardware() -> HardwareInfo {
    .init(machineModel: "fixture", chipName: "Apple M4", chipFamily: .m4, chipTier: .pro,
        memoryGb: 24, memoryAvailableGb: 20, cpuCores: .init(total: 12, performance: 8, efficiency: 4), gpuCores: 16, memoryBandwidthGbs: 200)
}
func memberFixtureClient(url: String, membership: ClusterMembership? = nil) -> CoordinatorClient {
    .init(config: .init(url: url, hardware: memberFixtureHardware(),
        models: [.init(id: "fixture-model", modelType: "qwen3", sizeBytes: 1, estimatedMemoryGb: 1)],
        backendName: "mlx-swift", heartbeatInterval: 60, executionRole: .clusterMember, clusterMembership: membership),
        stats: .init(), state: .init(), liveAPNsToken: { nil })
}

/// One member: its control, signer, client and the mock coordinator it reaches.
final class MemberFixturePeer: @unchecked Sendable {
    let mock = MockCoordinator()
    let control: NativePairMemberControl
    let signer: MemberFixtureSigner
    var client: CoordinatorClient!
    var nonce = ""
    var context: NativePairMemberConnection!
    init(installation: NativePairMemberInstallation) {
        let signer = MemberFixtureSigner()
        self.signer = signer; control = .init(installation: installation, signer: signer)
    }
    /// With `installProductionGate` the control is installed the way the serve
    /// loop installs it and nothing bypasses the TLS requirement.
    func connect(installProductionGate: Bool = false) async throws {
        let url = try await mock.start()
        client = memberFixtureClient(url: url.mockProviderWebSocketURL(),
            membership: installProductionGate ? try control.installation.membership : nil)
        if installProductionGate { try await client.installNativePairMember(control) }
        _ = await client.start()
        let registration = try #require(try await mock.awaitFirstRegister(timeout: .seconds(3)))
        nonce = try #require(registration.memberRegistrationNonce)
        try await mock.pushClusterMemberAcceptance(nonce: nonce)
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < end {
            let registered = await client.sessionRegistered, failed = await client.memberRoleFailure
            if registered || failed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        if !installProductionGate { context = try await client.attachFixtureControl(control) }
    }
    func wait(_ type: String) async throws -> NativePairMessage {
        let snapshot = try #require(try await mock.waitForSnapshot(timeout: .seconds(8)) { $0.nativePairs.contains { $0.type == type } })
        let message = try #require(snapshot.nativePairs.first { $0.type == type })
        try signer.verify(message); return message
    }
    func close() async { if let client { await client.shutdown() }; await mock.shutdown() }
}

/// A one-way flag set from a callback queue and read from a test.
final class MemberFixtureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

func memberFixtureWaitUntil(_ condition: () -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(8))
    while !condition() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}
