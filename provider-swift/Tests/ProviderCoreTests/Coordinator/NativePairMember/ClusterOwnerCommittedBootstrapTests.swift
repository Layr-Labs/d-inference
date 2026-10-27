import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
@testable import ProviderCore

// The combined owner profile for a start the coordinator committed (S10): the
// prelude rounds go through the member's session, the mesh rounds through the
// exchange the serving host attaches, renumbered from 0. Bytes and control
// flow only; no owner, worker or mesh.

private func digest(_ label: String) -> Data { Data(SHA256.hash(data: Data(label.utf8))) }
private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

/// A mesh-only exchange that records each round and answers both ranks'
/// contributions (this rank's twice, which is what a mesh reply's shape is).
private final class RecordingMeshExchange: ClusterOwnerBootstrapExchange, @unchecked Sendable {
    let profile: ClusterOwnerBootstrapProfile
    let identity: ClusterWorkerIdentity
    let executionPlanSHA256: String
    let deadlineUptimeNanoseconds: UInt64 = .max
    private let lock = NSLock()
    private var rounds: [UInt64] = []
    private var cancelled = false
    init(profile: ClusterOwnerBootstrapProfile = .mesh2, identity: ClusterWorkerIdentity, plan: String) {
        self.profile = profile; self.identity = identity; executionPlanSHA256 = plan
    }
    var sequences: [UInt64] { lock.withLock { rounds } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    func nativeStart(rank: Int) -> ClusterNativeAuthorizationStart? { nil }
    func cancel() { lock.withLock { cancelled = true } }
    func exchange(binding: ClusterOwnerBinding, sequence: UInt64, contribution: Data) throws -> Data {
        lock.withLock { rounds.append(sequence) }
        return contribution + contribution
    }
}

private struct CommittedFixture {
    let starts: [ClusterNativeAuthorizationStart]
    let identity: ClusterWorkerIdentity
    let profile = ClusterWorkerProfile(id: "committed-bootstrap-fixture", vocabularySize: 256,
        maximumPromptTokens: 8, maximumOutputTokens: 2, maximumChunkTokens: 4, maximumContextTokens: 16)
    let plan: String
    let hellos: [ClusterNativeKeyHello]

    init() throws {
        let common = try ClusterNativeAuthorizationCommon(epoch: UUID(), membershipGeneration: 3, nativePolicyGeneration: 1,
            membershipTranscriptSHA256: digest("membership"), approvedNativeBindingSHA256: digest("approval"),
            planSHA256: digest("plan"), artifactSHA256: digest("artifact"), nativeRuntimeSHA256: digest("runtime"),
            capabilitySHA256: digest("capability"), resourcePolicySHA256: digest("resources"), profileSHA256: digest("profile"),
            schedule: .serial, maximumTransportFrameBytes: 4136,
            limits: .init(maximumPlaintextBytes: 4096, maximumRecordsPerDirection: 64, maximumCumulativePlaintextBytesPerDirection: 262144))
        starts = try (0..<2).map { try .init(common: common, rank: $0, ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID()) }
        plan = hex(common.planSHA256)
        identity = ClusterWorkerIdentity(membershipEpoch: common.epoch, modelID: "fixture-model",
            artifactSHA256: hex(common.artifactSHA256), configurationSHA256: hex(digest("configuration")),
            peers: (0..<2).map { ClusterWorkerPeer(id: "fixture-rank-\($0)", buildSHA256: hex(digest("runtime"))) })
        hellos = try starts.map { try ClusterNativeKeyHello(start: $0, publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation) }
    }

    func binding(rank: Int, lease: UUID? = nil) throws -> ClusterOwnerBinding {
        try ClusterOwnerBinding(clusterID: "committed-fixture", ownerIncarnation: starts[rank].ownerIncarnation,
            leaseID: lease ?? starts[rank].leaseID, identity: identity, profile: profile, rank: rank, executionPlanSHA256: plan)
    }

    /// The session's side of the prelude, as the coordinator relays it.
    func prelude(_ round: UInt64, _ bytes: Data) throws -> Data {
        switch round {
        case 0: return try ClusterNativeKeyBinding(hellos: hellos).canonicalBytes
        case 1: return Data(repeating: 7, count: 32)
        default: return bytes
        }
    }

    static let meshRounds: [Data] = [Data([2, 0, 0, 0]), Data(repeating: 1, count: 64), Data([0, 0, 0, 0]), Data([0, 0, 0, 0])]
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class RoundLog: @unchecked Sendable {
    private let lock = NSLock(); private var values: [UInt64] = []
    func append(_ round: UInt64) { lock.withLock { values.append(round) } }
    var rounds: [UInt64] { lock.withLock { values } }
}

@Suite("Committed start bootstrap (prelude through the session, mesh through the host)", .timeLimit(.minutes(1)))
struct ClusterOwnerCommittedBootstrapTests {
    @Test func preludeGoesToTheSessionAndMeshRoundsWaitForTheAttachedRelayRenumbered() async throws {
        let f = try CommittedFixture()
        let seen = RoundLog()
        let invalidated = Counter()
        let bootstrap = try ClusterOwnerCommittedBootstrap(start: f.starts[0], identity: f.identity, executionPlanSHA256: f.plan,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 20_000_000_000,
            prelude: { round, bytes in seen.append(round); return try f.prelude(round, bytes) },
            invalidated: { invalidated.bump() })
        #expect(bootstrap.profile == .nativeKeyPreludeMesh2)
        #expect(bootstrap.nativeStart(rank: 0)?.canonicalBytes == f.starts[0].canonicalBytes)
        #expect(bootstrap.nativeStart(rank: 1) == nil)
        let binding = try f.binding(rank: 0)
        _ = try bootstrap.exchange(binding: binding, sequence: 0, contribution: f.hellos[0].canonicalBytes)
        #expect(try bootstrap.exchange(binding: binding, sequence: 1, contribution: Data(repeating: 3, count: 32)) == Data(repeating: 7, count: 32))
        let transcript = Data(repeating: 9, count: 32)
        #expect(try bootstrap.exchange(binding: binding, sequence: 2, contribution: transcript) == transcript)
        #expect(seen.rounds == [0, 1, 2])

        // The first mesh round waits: no relay is attached yet.
        let mesh = RecordingMeshExchange(identity: f.identity, plan: f.plan)
        let round3 = Task.detached { try bootstrap.exchange(binding: binding, sequence: 3, contribution: CommittedFixture.meshRounds[0]) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(mesh.sequences.isEmpty && !bootstrap.meshAttached)
        try bootstrap.attachMesh(mesh)
        #expect(try await round3.value == CommittedFixture.meshRounds[0] + CommittedFixture.meshRounds[0])
        for round in 1..<4 {
            _ = try bootstrap.exchange(binding: binding, sequence: UInt64(3 + round), contribution: CommittedFixture.meshRounds[round])
        }
        #expect(mesh.sequences == [0, 1, 2, 3])
        #expect(seen.rounds == [0, 1, 2])
        #expect(invalidated.count == 0)
    }

    @Test func anotherOwnerOrASkippedRoundFailsCancelsTheMeshAndInvalidatesOnce() throws {
        let f = try CommittedFixture()
        let invalidated = Counter()
        let bootstrap = try ClusterOwnerCommittedBootstrap(start: f.starts[1], identity: f.identity, executionPlanSHA256: f.plan,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 20_000_000_000,
            prelude: { round, bytes in try f.prelude(round, bytes) }, invalidated: { invalidated.bump() })
        let mesh = RecordingMeshExchange(identity: f.identity, plan: f.plan)
        try bootstrap.attachMesh(mesh)
        // Another lease than the committed start names.
        #expect(throws: (any Error).self) {
            try bootstrap.exchange(binding: f.binding(rank: 1, lease: UUID()), sequence: 0, contribution: f.hellos[1].canonicalBytes)
        }
        #expect(invalidated.count == 1 && mesh.wasCancelled)
        // Cancelled: nothing more, and no second notice.
        #expect(throws: (any Error).self) {
            try bootstrap.exchange(binding: f.binding(rank: 1), sequence: 0, contribution: f.hellos[1].canonicalBytes)
        }
        bootstrap.cancel()
        #expect(invalidated.count == 1)

        let skipping = try ClusterOwnerCommittedBootstrap(start: f.starts[1], identity: f.identity, executionPlanSHA256: f.plan,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 20_000_000_000,
            prelude: { round, bytes in try f.prelude(round, bytes) }, invalidated: { invalidated.bump() })
        #expect(throws: (any Error).self) {
            try skipping.exchange(binding: f.binding(rank: 1), sequence: 1, contribution: Data(repeating: 3, count: 32))
        }
        #expect(invalidated.count == 2)
    }

    @Test func onlyOneMeshOnlyExchangeOfTheSameMembershipAttaches() throws {
        let f = try CommittedFixture()
        let bootstrap = try ClusterOwnerCommittedBootstrap(start: f.starts[0], identity: f.identity, executionPlanSHA256: f.plan,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 20_000_000_000,
            prelude: { round, bytes in try f.prelude(round, bytes) }, invalidated: {})
        #expect(throws: (any Error).self) { try bootstrap.attachMesh(RecordingMeshExchange(profile: .nativeKeyPreludeMesh2, identity: f.identity, plan: f.plan)) }
        #expect(throws: (any Error).self) { try bootstrap.attachMesh(RecordingMeshExchange(identity: f.identity, plan: hex(digest("other plan")))) }
        try bootstrap.attachMesh(RecordingMeshExchange(identity: f.identity, plan: f.plan))
        let second = RecordingMeshExchange(identity: f.identity, plan: f.plan)
        #expect(throws: (any Error).self) { try bootstrap.attachMesh(second) }
        #expect(second.wasCancelled)
        // A start of another plan is refused at construction.
        #expect(throws: (any Error).self) {
            try ClusterOwnerCommittedBootstrap(start: f.starts[0], identity: f.identity, executionPlanSHA256: hex(digest("other plan")),
                deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
                prelude: { _, bytes in bytes }, invalidated: {})
        }
    }

    @Test func aMeshRoundWaitsOnlyUntilTheBootstrapDeadline() throws {
        let f = try CommittedFixture()
        let invalidated = Counter()
        let bootstrap = try ClusterOwnerCommittedBootstrap(start: f.starts[0], identity: f.identity, executionPlanSHA256: f.plan,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_500_000_000,
            prelude: { round, bytes in try f.prelude(round, bytes) }, invalidated: { invalidated.bump() })
        let binding = try f.binding(rank: 0)
        _ = try bootstrap.exchange(binding: binding, sequence: 0, contribution: f.hellos[0].canonicalBytes)
        _ = try bootstrap.exchange(binding: binding, sequence: 1, contribution: Data(repeating: 3, count: 32))
        _ = try bootstrap.exchange(binding: binding, sequence: 2, contribution: Data(repeating: 9, count: 32))
        let began = ContinuousClock.now
        #expect(throws: (any Error).self) { try bootstrap.exchange(binding: binding, sequence: 3, contribution: CommittedFixture.meshRounds[0]) }
        #expect(ContinuousClock.now - began < .seconds(5))
        #expect(invalidated.count == 1)
    }
}
