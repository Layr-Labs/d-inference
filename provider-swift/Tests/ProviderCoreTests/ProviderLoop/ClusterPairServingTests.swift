import Foundation
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
@testable import ProviderCore

// The leader member as the serving host of its committed starts (S10), on a
// member loop with the real pair installation. The pair's owner is scripted
// and the session's endpoint is inert: these prove the host's publication,
// stop and race handling, never a pair or an owner process.

/// An owner endpoint that is never driven: the scripted pair stands in for
/// the pair built over it.
final class InertWorkerEndpoint: ClusterWorkerEndpoint, @unchecked Sendable {
    let expectedIdentity: ClusterWorkerIdentity
    let expectedProfile: ClusterWorkerProfile
    let rank: Int
    let executionPlanSHA256: String
    var readiness: ClusterWorkerReady? { nil }
    var localLifetimeDeadlineUptimeNanoseconds: UInt64 { .max }
    var nativeCleanupObserved: Bool { true }
    init(identity: ClusterWorkerIdentity, profile: ClusterWorkerProfile, rank: Int, plan: String) {
        expectedIdentity = identity; expectedProfile = profile; self.rank = rank; executionPlanSHA256 = plan
    }
    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        throw ClusterWorkerOwnerError.invalid("inert")
    }
    func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        throw ClusterWorkerOwnerError.invalid("inert")
    }
    func requestNativeCleanup() {}
    func waitForNativeCleanup() {}
    func waitUntilNativeCleanup() async {}
}

/// Records each start the context was asked to build, and can hold one.
final class ScriptedPairBuilder: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [ScriptedPairOwner] = []
    var hold: DispatchSemaphore?
    var failure: Error?
    var built: [ScriptedPairOwner] { lock.withLock { owners } }

    func make(_ start: NativePairMemberServingStart) throws -> any DistributedResidentExecutionOwner {
        hold?.wait()
        if let failure { throw failure }
        let wire = start.identity
        let owner = ScriptedPairOwner(identity: .init(membershipEpoch: start.membershipEpoch, modelID: wire.modelID,
            artifactSHA256: wire.artifactSHA256, configurationSHA256: wire.configurationSHA256,
            peers: wire.peers.map { .init(id: $0.id, buildSHA256: $0.buildSHA256) }))
        lock.withLock { owners.append(owner) }
        return owner
    }
}

private struct ServingFixture {
    let contract: MemberContractFixture
    let loop: ProviderLoop
    let builder = ScriptedPairBuilder()

    static func make(rank: Int = 0) async throws -> ServingFixture {
        let contract = try MemberContractFixture()
        let hardware = HardwareInfo(machineModel: "fixture", chipName: "Apple M4", chipFamily: .m4, chipTier: .pro,
            memoryGb: 24, memoryAvailableGb: 20, cpuCores: .init(total: 12, performance: 8, efficiency: 4),
            gpuCores: 16, memoryBandwidthGbs: 200)
        let loop = try ProviderLoop(
            config: .init(coordinatorURL: "ws://127.0.0.1:9/ws", hardware: hardware,
                models: [.init(id: "fixture-model", modelType: "qwen3_5", sizeBytes: 1, estimatedMemoryGb: 1)],
                config: .init(provider: .init(name: "cluster-pair-serving", autoUpdate: false), backend: .init(),
                    coordinator: .init(url: "ws://127.0.0.1:9/ws", heartbeatIntervalSecs: 1)),
                executionRole: .clusterMember),
            attestationSigner: ServeLoopTestSigner())
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await loop.setServeUsesHostServicesForTesting(false)
        await loop.setDaemonStateFileForTesting(FileManager.default.temporaryDirectory
            .appendingPathComponent("cluster-pair-serving-\(UUID().uuidString).json"))
        try await loop.prepareClusterMemberControlForTesting()
        try await loop.installNativePairMember(contract.installations[rank])
        return .init(contract: contract, loop: loop)
    }

    func context() throws -> ClusterPairServingContext {
        let builder = self.builder
        return try .init(publicModelID: "fixture-model", modelType: "qwen3_5",
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99], profile: distributedTestProfile(),
            artifactBytes: 1 << 30, makeOwner: { try builder.make($0) })
    }

    func start(rank: Int = 0, epoch: UUID? = nil) throws -> NativePairMemberServingStart {
        let installation = contract.installations[rank]
        var start = contract.starts[rank]
        if let epoch {
            guard case .servingV1(let serving) = start.common.permission else { throw NativePairMemberError.binding }
            start = try .init(common: .init(epoch: epoch, membershipGeneration: 7, nativePolicyGeneration: 11,
                membershipTranscriptSHA256: start.common.membershipTranscriptSHA256,
                approvedNativeBindingSHA256: serving.approvedNativeBindingSHA256, planSHA256: start.common.planSHA256,
                artifactSHA256: start.common.artifactSHA256, nativeRuntimeSHA256: serving.nativeRuntimeSHA256,
                capabilitySHA256: serving.capabilitySHA256, resourcePolicySHA256: serving.resourcePolicySHA256,
                profileSHA256: start.common.profileSHA256, schedule: start.common.schedule,
                maximumTransportFrameBytes: start.common.maximumTransportFrameBytes, limits: start.common.limits),
                rank: rank, ownerIncarnation: UUID(), leaseID: UUID(), launchID: UUID())
        }
        let identity = installation.sessionIdentity(start)
        return .init(start: start, identity: identity, profile: installation.profile,
            executionPlanSHA256: installation.executionPlanSHA256,
            endpoint: InertWorkerEndpoint(identity: identity, profile: installation.profile, rank: rank,
                plan: installation.executionPlanSHA256),
            leaseDeadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 60_000_000_000)
    }
}

extension ProviderLoop {
    var clusterPairServingSnapshot: (epoch: UUID?, slotEpoch: UUID?, refusing: Bool) {
        (clusterPairServingEpoch, clusterPairSlot?.membershipEpoch, state.refusingNewWork)
    }
}

@Suite("Cluster pair serving of committed starts", .serialized, .timeLimit(.minutes(1)))
struct ClusterPairServingTests {
    @Test func theLeaderPublishesItsCommittedStartAndRetiresItWhenTheSessionEnds() async throws {
        let fixture = try await ServingFixture.make()
        try await fixture.loop.installClusterPairServing(fixture.context())
        let first = try fixture.start()
        try await fixture.loop.serveCommittedStart(first)
        var snapshot = await fixture.loop.clusterPairServingSnapshot
        #expect(snapshot.epoch == first.membershipEpoch && snapshot.slotEpoch == first.membershipEpoch && !snapshot.refusing)
        #expect(await fixture.loop.clusterPairSlotServes("fixture-model"))
        #expect(await fixture.loop.state.backendCapacity?.slots.map(\.model) == ["fixture-model"])
        // One start at a time.
        await #expect(throws: ClusterPairSlotError.self) { try await fixture.loop.serveCommittedStart(try fixture.start(epoch: UUID())) }

        await fixture.loop.stopServingCommittedStart(epoch: UUID()) // another epoch: nothing
        #expect(await fixture.loop.clusterPairServingSnapshot.slotEpoch == first.membershipEpoch)
        await fixture.loop.stopServingCommittedStart(epoch: first.membershipEpoch)
        snapshot = await fixture.loop.clusterPairServingSnapshot
        #expect(snapshot.epoch == nil && snapshot.slotEpoch == nil && snapshot.refusing)
        #expect(fixture.builder.built.first?.shutdownCount == 1)

        // The next committed start publishes a fresh slot.
        let second = try fixture.start(epoch: UUID())
        try await fixture.loop.serveCommittedStart(second)
        #expect(await fixture.loop.clusterPairServingSnapshot.slotEpoch == second.membershipEpoch)
        await fixture.loop.stopServingCommittedStart(epoch: second.membershipEpoch)
        #expect(fixture.builder.built.count == 2 && fixture.builder.built[1].shutdownCount == 1)
    }

    @Test func aLostRankRetiresTheSlotAndTheSessionsStopThenClearsTheStart() async throws {
        let fixture = try await ServingFixture.make()
        try await fixture.loop.installClusterPairServing(fixture.context())
        let first = try fixture.start()
        try await fixture.loop.serveCommittedStart(first)
        let owner = try #require(fixture.builder.built.first)
        owner.losePeer()
        #expect(await clusterPairWait { await fixture.loop.clusterPairServingSnapshot.slotEpoch == nil })
        #expect(owner.shutdownCount == 1)
        // Still this start's until its session ends.
        #expect(await fixture.loop.clusterPairServingSnapshot.epoch == first.membershipEpoch)
        await fixture.loop.stopServingCommittedStart(epoch: first.membershipEpoch)
        #expect(await fixture.loop.clusterPairServingSnapshot.epoch == nil)
        try await fixture.loop.serveCommittedStart(try fixture.start(epoch: UUID()))
        #expect(await fixture.loop.clusterPairServingSnapshot.slotEpoch != nil)
    }

    /// The session ends while the pair is still forming: nothing publishes and
    /// the formed owner is shut down.
    @Test func aStopWhileThePairFormsPublishesNothing() async throws {
        let fixture = try await ServingFixture.make()
        try await fixture.loop.installClusterPairServing(fixture.context())
        let hold = DispatchSemaphore(value: 0)
        fixture.builder.hold = hold
        let start = try fixture.start()
        let serve = Task { try await fixture.loop.serveCommittedStart(start) }
        #expect(await clusterPairWait { await fixture.loop.clusterPairServingSnapshot.epoch == start.membershipEpoch })
        await fixture.loop.stopServingCommittedStart(epoch: start.membershipEpoch)
        hold.signal()
        await #expect(throws: ClusterPairSlotError.self) { try await serve.value }
        let snapshot = await fixture.loop.clusterPairServingSnapshot
        #expect(snapshot.epoch == nil && snapshot.slotEpoch == nil && snapshot.refusing)
        #expect(fixture.builder.built.first?.shutdownCount == 1)
    }

    @Test func onlyTheLeaderWithAContextServesAndAFailedPairLeavesNothing() async throws {
        let leader = try await ServingFixture.make()
        await #expect(throws: ClusterPairSlotError.self) { try await leader.loop.serveCommittedStart(try leader.start()) }
        try await leader.loop.installClusterPairServing(leader.context())
        await #expect(throws: ClusterPairSlotError.self) { try await leader.loop.installClusterPairServing(leader.context()) }
        await #expect(throws: ClusterPairSlotError.self) { try await leader.loop.serveCommittedStart(try leader.start(rank: 1)) }
        leader.builder.failure = ClusterWorkerOwnerError.invalid("pair did not form")
        await #expect(throws: ClusterWorkerOwnerError.self) { try await leader.loop.serveCommittedStart(try leader.start()) }
        #expect(await leader.loop.clusterPairServingSnapshot.epoch == nil)

        let follower = try await ServingFixture.make(rank: 1)
        await #expect(throws: ClusterPairSlotError.self) { try await follower.loop.installClusterPairServing(follower.context()) }
    }
}
