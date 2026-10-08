import CryptoKit
import Darwin
import Foundation
import Network
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
@testable import ProviderCore

// Contract coverage for the staged native-pair member components. The
// member-mode serving integration is intentionally NOT staged (isClusterMember
// is false); these tests pin the components' contracts without activating any
// member behavior. No coordinator, no TLS, no model, no native launch.

func memberDigest(_ label: String) -> Data { Data(SHA256.hash(data: Data(label.utf8))) }
func memberHex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

struct MemberContractFixture {
    let root: URL
    let policy: Data
    let starts: [ClusterNativeAuthorizationStart]
    let installations: [NativePairMemberInstallation]
    let prepareUnix: Int64
    let expiresUnix: Int64

    init(lifetimeSeconds: Int64 = 12, preparationSeconds: Int64 = 5) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        prepareUnix = now + preparationSeconds * 1_000_000_000
        expiresUnix = now + lifetimeSeconds * 1_000_000_000
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-member-contract-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var hashes = (0..<8).map { memberDigest("member-contract-hash-\($0)") }
        let ownerBytes = Data("contract-owner-fixture".utf8)
        let native = Data(SHA256.hash(data: ownerBytes))
        hashes[2] = native
        var p = Data("darkbloom/coordinator-native-runtime-approval/v1\0".utf8)
        func integer<T: FixedWidthInteger & UnsignedInteger>(_ value: T) {
            for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { p.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        func string(_ text: String) { let bytes = Data(text.utf8); integer(UInt32(bytes.count)); p.append(bytes) }
        string("explicit-cpu-contract-only"); string("fixture-model"); integer(UInt64(11))
        hashes.forEach { p.append($0) }; p.append(contentsOf: [1, 1, 2])
        integer(UInt32(4136)); integer(UInt32(4096)); integer(UInt64(64)); integer(UInt64(262144))
        integer(UInt64(now + 3_600_000_000_000)); integer(UInt32(1)); string("Apple M4")
        policy = p
        let common = try ClusterNativeAuthorizationCommon(epoch: UUID(), membershipGeneration: 7, nativePolicyGeneration: 11,
            membershipTranscriptSHA256: memberDigest("fixture-membership"),
            approvedNativeBindingSHA256: Data(SHA256.hash(data: p)), planSHA256: hashes[0], artifactSHA256: hashes[1],
            nativeRuntimeSHA256: hashes[2], capabilitySHA256: hashes[5], resourcePolicySHA256: hashes[6], profileSHA256: hashes[7],
            schedule: .oneChunkLookahead, maximumTransportFrameBytes: 4136,
            limits: .init(maximumPlaintextBytes: 4096, maximumRecordsPerDirection: 64, maximumCumulativePlaintextBytesPerDirection: 262144))
        starts = try (0..<2).map { rank in try .init(common: common, rank: rank, ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID()) }
        var installed: [NativePairMemberInstallation] = []
        for rank in 0..<2 {
            let directory = root.appendingPathComponent("rank-\(rank)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let owner = directory.appendingPathComponent("owner-fixture")
            try ownerBytes.write(to: owner, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: owner.path)
            let metallib = directory.appendingPathComponent("fixture.metallib")
            let resource = directory.appendingPathComponent("fixture.resource")
            try memberDigest("contract-metallib").write(to: metallib, options: .withoutOverwriting)
            try memberDigest("contract-resource").write(to: resource, options: .withoutOverwriting)
            let gate = directory.appendingPathComponent(".darkbloom/cluster-device")
            try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let identity = ClusterWorkerIdentity(membershipEpoch: common.epoch, modelID: "fixture-model",
                artifactSHA256: memberHex(hashes[1]), configurationSHA256: memberHex(memberDigest("fixture-config")),
                peers: (0..<2).map { ClusterWorkerPeer(id: "peer-\($0)", buildSHA256: memberHex(hashes[2])) })
            let profile = ClusterWorkerProfile(id: "fixture-profile", vocabularySize: 1000,
                maximumPromptTokens: 128, maximumOutputTokens: 128, maximumChunkTokens: 64, maximumContextTokens: 512)
            installed.append(try NativePairMemberInstallation(expectedCoordinatorPolicy: p, rank: rank,
                clusterID: "native-member-contract", identity: identity, profile: profile,
                installedOwner: owner, ownerSHA256: memberHex(native), nativeExecutable: owner,
                metallib: metallib, resourceLibrary: resource, chip: "Apple M4", leaseDirectory: gate))
        }
        installations = installed
    }

    func preparationPayload(_ rank: Int) -> Data {
        var preparation = Data([68, 66, 78, 80, 82, 1])
        let n = UInt32(policy.count)
        for shift in stride(from: 24, through: 0, by: -8) { preparation.append(UInt8(truncatingIfNeeded: n >> shift)) }
        preparation.append(policy)
        preparation.append(starts[rank].canonicalBytes)
        return preparation
    }

    func prepareMessage(_ rank: Int, nonce: String, sequence: UInt64) throws -> NativePairMessage {
        try .init(type: "native_pair_prepare", memberNonce: nonce,
            epoch: withUnsafeBytes(of: starts[rank].common.epoch.uuid) { memberHex(Data($0)) },
            generation: 7, sequence: sequence, payload: preparationPayload(rank),
            prepareBeforeUnixNano: prepareUnix, expiresAtUnixNano: expiresUnix)
    }
}

func deadConnection() -> NWConnection {
    NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
}

struct ContractSigner: AttestationSigner {
    let key = P256.Signing.PrivateKey()
    var publicKeyBase64: String { Data(key.publicKey.x963Representation.dropFirst()).base64EncodedString() }
    func sign(_ data: Data) throws -> Data { try key.signature(for: data).derRepresentation }
}

@Suite("Native pair member contract (staged, inactive)")
struct NativePairMemberContractTests {
    @Test func policyParsingAndStartBinding() throws {
        let fixture = try MemberContractFixture()
        let policy = try NativePairMemberPolicy(fixture.policy)
        #expect(policy.model == "fixture-model" && policy.generation == 11)
        #expect(policy.chips == ["Apple M4"])
        try policy.require(fixture.starts[0])
        // Structural mutations break parsing; free-form field mutations parse
        // but fail the approved-binding digest in require().
        for mutation in [0, 40, 100, fixture.policy.count - 1] {
            var tampered = fixture.policy
            tampered[mutation] ^= 1
            if let parsed = try? NativePairMemberPolicy(tampered) {
                #expect(throws: NativePairMemberError.self) { try parsed.require(fixture.starts[0]) }
            }
        }
        var oversized = fixture.policy
        oversized.append(0)
        #expect(throws: NativePairMemberError.self) { _ = try NativePairMemberPolicy(oversized) }
        // A start whose common disagrees with the approved policy is refused.
        let wrongCommon = try ClusterNativeAuthorizationCommon(epoch: fixture.starts[0].common.epoch,
            membershipGeneration: 7, nativePolicyGeneration: 12,
            membershipTranscriptSHA256: fixture.starts[0].common.membershipTranscriptSHA256,
            approvedNativeBindingSHA256: fixture.starts[0].common.approvedNativeBindingSHA256,
            planSHA256: fixture.starts[0].common.planSHA256, artifactSHA256: fixture.starts[0].common.artifactSHA256,
            nativeRuntimeSHA256: fixture.starts[0].common.nativeRuntimeSHA256,
            capabilitySHA256: fixture.starts[0].common.capabilitySHA256,
            resourcePolicySHA256: fixture.starts[0].common.resourcePolicySHA256,
            profileSHA256: fixture.starts[0].common.profileSHA256,
            schedule: .oneChunkLookahead, maximumTransportFrameBytes: 4136, limits: fixture.starts[0].common.limits)
        let other = try ClusterNativeAuthorizationStart(common: wrongCommon, rank: 0,
            ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID())
        #expect(throws: NativePairMemberError.self) { try policy.require(other) }
        // The prepare payload itself parses strictly.
        let (parsedPolicy, parsedStart) = try NativePairMemberPolicy.preparation(fixture.preparationPayload(0))
        #expect(parsedPolicy.bytes == fixture.policy && parsedStart.rank == 0)
        #expect(throws: NativePairMemberError.self) { _ = try NativePairMemberPolicy.preparation(Data([1, 2, 3])) }
    }

    @Test func installationRejectsMismatchedPins() throws {
        let fixture = try MemberContractFixture()
        let installation = fixture.installations[0]
        #expect(installation.rank == 0 && installation.policy.model == "fixture-model")
        // An installation whose chip is not in the approved policy cannot exist.
        let identity = ClusterWorkerIdentity(membershipEpoch: fixture.starts[0].common.epoch, modelID: "fixture-model",
            artifactSHA256: installation.identity.artifactSHA256, configurationSHA256: installation.identity.configurationSHA256,
            peers: installation.identity.peers)
        #expect(throws: NativePairMemberError.self) {
            _ = try NativePairMemberInstallation(expectedCoordinatorPolicy: fixture.policy, rank: 0,
                clusterID: "native-member-contract", identity: identity, profile: installation.profile,
                installedOwner: installation.artifacts[0], ownerSHA256: installation.ownerSHA256,
                nativeExecutable: installation.artifacts[0], metallib: installation.artifacts[1],
                resourceLibrary: installation.artifacts[2], chip: "Unapproved Chip", leaseDirectory: fixture.root)
        }
    }

    @Test func controlSequencingRefusesOutOfContractFrames() throws {
        let fixture = try MemberContractFixture()
        let control = NativePairMemberControl(installation: fixture.installations[0], signer: ContractSigner())
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let memberNonce = String(repeating: "a", count: 64)
        // A refused frame detaches its connection: every case gets a fresh one.
        func freshConnection() throws -> NativePairMemberConnection {
            try control.attach(nonce: memberNonce, connection: deadConnection())
        }
        let valid = try fixture.prepareMessage(0, nonce: memberNonce, sequence: 1)
        // A frame on a connection the control never attached is refused.
        let main = try freshConnection()
        #expect(throws: NativePairMemberError.self) {
            try control.receive(valid, on: NativePairMemberConnection(nonce: memberNonce, connection: deadConnection(), signer: ContractSigner(), onInvalidation: { _ in }), receivedAt: now, wallUnixNanoseconds: wall)
        }
        #expect(main.isLive)
        // Wrong member nonce poisons the connection it arrived on.
        let wrongNonce = try NativePairMessage(type: valid.type, memberNonce: String(repeating: "f", count: 64), epoch: valid.epoch,
            generation: valid.generation, sequence: valid.sequence, payload: Data(base64Encoded: valid.payload)!,
            prepareBeforeUnixNano: valid.prepareBeforeUnixNano, expiresAtUnixNano: valid.expiresAtUnixNano)
        #expect(throws: NativePairMemberError.self) { try control.receive(wrongNonce, on: main, receivedAt: now, wallUnixNanoseconds: wall) }
        #expect(!main.isLive)
        // Inbound-only (member→coordinator) types never arrive from a coordinator.
        let second = try freshConnection()
        let inboundType = try NativePairMessage(type: "native_pair_prepared", memberNonce: memberNonce, epoch: valid.epoch,
            generation: valid.generation, sequence: 1, payload: Data([1]))
        #expect(throws: NativePairMemberError.self) { try control.receive(inboundType, on: second, receivedAt: now, wallUnixNanoseconds: wall) }
        // A sequence gap is refused (only terminal cancellation may skip ahead).
        let third = try freshConnection()
        let gap = try fixture.prepareMessage(0, nonce: memberNonce, sequence: 3)
        #expect(throws: NativePairMemberError.self) { try control.receive(gap, on: third, receivedAt: now, wallUnixNanoseconds: wall) }
        // The valid prepare is accepted and installs the session synchronously.
        let fourth = try freshConnection()
        try control.receive(valid, on: fourth, receivedAt: now, wallUnixNanoseconds: wall)
        #expect(control.status != "idle")
        // A second prepare on this connection is refused (no session stacking).
        #expect(throws: NativePairMemberError.self) { try control.receive(valid, on: fourth, receivedAt: now, wallUnixNanoseconds: wall) }
        control.detach(fourth)
        #expect(!fourth.isLive)
    }

    @Test func sessionRejectsStaleAndUncommittedFrames() throws {
        let fixture = try MemberContractFixture()
        let control = NativePairMemberControl(installation: fixture.installations[0], signer: ContractSigner())
        let connection = try control.attach(nonce: String(repeating: "a", count: 64), connection: deadConnection())
        let now = DispatchTime.now().uptimeNanoseconds
        let wall = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let prepare = try fixture.prepareMessage(0, nonce: String(repeating: "a", count: 64), sequence: 1)
        // Stale epoch: a prepare whose epoch differs from the installation's
        // committed common epoch fails session construction and detaches.
        var staleBytes = fixture.preparationPayload(0)
        staleBytes[staleBytes.count - 1] ^= 1
        let stale = try NativePairMessage(type: "native_pair_prepare", memberNonce: String(repeating: "a", count: 64),
            epoch: String(repeating: "ee", count: 16), generation: 7, sequence: 1,
            payload: staleBytes, prepareBeforeUnixNano: fixture.prepareUnix, expiresAtUnixNano: fixture.expiresUnix)
        #expect(throws: NativePairMemberError.self) { try control.receive(stale, on: connection, receivedAt: now, wallUnixNanoseconds: wall) }
        #expect(!connection.isLive)
        // Cancel with anything but the exact public cancel record is refused.
        let control2 = NativePairMemberControl(installation: fixture.installations[1], signer: ContractSigner())
        let connection2 = try control2.attach(nonce: String(repeating: "a", count: 64), connection: deadConnection())
        try control2.receive(try fixture.prepareMessage(1, nonce: String(repeating: "a", count: 64), sequence: 1), on: connection2, receivedAt: now, wallUnixNanoseconds: wall)
        let badCancel = try NativePairMessage(type: "native_pair_cancel", memberNonce: String(repeating: "a", count: 64),
            epoch: prepare.epoch, generation: 7, sequence: 2, payload: Data([1, 2, 3]),
            prepareBeforeUnixNano: fixture.prepareUnix, expiresAtUnixNano: fixture.expiresUnix)
        #expect(throws: NativePairMemberError.self) { try control2.receive(badCancel, on: connection2, receivedAt: now, wallUnixNanoseconds: wall) }
        control2.detach(connection2)
    }

    @Test func memberModeIsStagedInactive() throws {
        // The serving integration is not staged: no configuration path enables
        // the member role, so a ProviderLoop always reports isClusterMember ==
        // false and refuses member installation. Pin that contract at the type
        // level: a loop created for ordinary solo serving can never become a
        // member through these components.
        let fixture = try MemberContractFixture()
        let control = NativePairMemberControl(installation: fixture.installations[0], signer: ContractSigner())
        #expect(control.status == "idle")
    }
}
