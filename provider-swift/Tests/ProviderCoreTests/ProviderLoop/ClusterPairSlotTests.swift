import Foundation
import Testing
import MLXLMCommon
@testable import ProviderCore

// The cluster pair as an ordinary provider slot (S09), on a member loop. The
// execution owner is scripted (no process, model or GPU): these prove the
// slot's publication, routing, capacity and retirement, never a pair.

let clusterPairFixtureModel = "fixture/cluster-pair-qwen"

/// One request on the scripted pair: it commits token after token until the
/// engine declines one (its output limit or a stop), then both "ranks"
/// retire. `cancel` is the failure path and retires at once.
final class ScriptedPairLease: DistributedResidentRequestLease, @unchecked Sendable {
    let identity: DistributedResidentIdentity
    let requestID: CBv2RequestID
    let reservedBytes = 64
    var bytesInUse: Int { 0 }
    private let retired = DistributedRetirementLatch()
    private let lock = NSLock()
    private var cancels = 0, releases = 0
    private let hold: DispatchSemaphore?
    private var cleanStops = 0
    /// Like the worker pair's lease: a stop asked for by the host ends the
    /// request at its next token, with no native cancel.
    let acceptsCleanStop: Bool
    var cancelCount: Int { lock.withLock { cancels } }
    var releaseCount: Int { lock.withLock { releases } }
    var cleanStopCount: Int { lock.withLock { cleanStops } }

    init(identity: DistributedResidentIdentity, requestID: CBv2RequestID, hold: DispatchSemaphore?, acceptsCleanStop: Bool) {
        self.identity = identity; self.requestID = requestID; self.hold = hold; self.acceptsCleanStop = acceptsCleanStop
    }
    func start(emit: @escaping @Sendable (DistributedResidentEvent) -> Bool) throws {
        let hold = self.hold
        DispatchQueue.global().async { [retired] in
            hold?.wait()
            var token = 5
            while emit(.token(token)) { token += 1 }
            retired.complete()
        }
    }
    func cancel() { lock.withLock { cancels += 1 }; retired.complete() }
    func requestCleanStop() -> Bool {
        lock.withLock { guard acceptsCleanStop, cancels == 0 else { return false }; cleanStops += 1; return true }
    }
    func waitUntilRetired() async { await retired.wait() }
    func releaseResources() { lock.withLock { releases += 1 } }
}

/// A pair owner whose two ranks are always loaded until `losePeer`.
final class ScriptedPairOwner: DistributedResidentExecutionOwner, @unchecked Sendable {
    let identity: DistributedResidentIdentity
    let profileID = "fabricated-greedy"
    private let lock = NSLock()
    private var available = true
    private var invalidation: (@Sendable () -> Void)?
    private var leases: [ScriptedPairLease] = []
    private var shutdowns = 0
    /// When set, every request waits for one signal before its first token.
    var hold: DispatchSemaphore?
    var leasesAcceptCleanStop = true
    /// The first this many reservations fail (the warmup canary is the first).
    var failFirstReservations = 0

    init(model: String = clusterPairFixtureModel) {
        identity = .init(membershipEpoch: UUID(), modelID: model,
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
            peers: [.init(id: "rank-0", buildSHA256: String(repeating: "c", count: 64)),
                    .init(id: "rank-1", buildSHA256: String(repeating: "d", count: 64))])
    }
    init(identity: DistributedResidentIdentity) { self.identity = identity }
    var reserveCount: Int { lock.withLock { leases.count } }
    var shutdownCount: Int { lock.withLock { shutdowns } }
    var lastLease: ScriptedPairLease? { lock.withLock { leases.last } }

    func readiness() -> DistributedResidentReadiness? {
        lock.withLock { available ? .init(identity: identity, profileID: profileID, requestCapacityBytes: 1 << 20) : nil }
    }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { invalidation = handler }
    }
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        .unbounded(reason: nil)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        try lock.withLock {
            guard available, identity == self.identity, profileID == self.profileID else { throw DistributedEngineError.unavailable }
            if failFirstReservations > 0 { failFirstReservations -= 1; throw DistributedEngineError.unavailable }
            let lease = ScriptedPairLease(identity: identity, requestID: request.id, hold: hold,
                acceptsCleanStop: leasesAcceptCleanStop)
            leases.append(lease)
            return lease
        }
    }
    func shutdown() async { lock.withLock { shutdowns += 1; available = false } }
    /// A rank is gone: readiness ends and the one observer is told.
    func losePeer() {
        let handler = lock.withLock { available = false; return invalidation }
        handler?()
    }
}

func clusterPairSpecification(_ owner: ScriptedPairOwner, model: String = clusterPairFixtureModel,
                              modelType: String = "qwen3_5") throws -> ClusterPairSlotSpecification {
    .init(publicModelID: model, modelType: modelType, tokenizer: TokenizerHandle(DistributedTestTokenizer()),
          eosTokenIDs: [99], expectedIdentity: owner.identity, profile: try distributedTestProfile(),
          artifactBytes: 1 << 30)
}

/// A member loop with no coordinator, the way `run()` prepares it.
/// The warmup canary (S18) is off unless `warmupTimeoutSeconds` is given, so
/// these tests count only their own reservations.
func clusterPairMemberLoop(models: [String] = [clusterPairFixtureModel], role: ProviderExecutionRole = .clusterMember,
                           modelType: String = "qwen3_5", warmupTimeoutSeconds: Double? = nil) async throws -> ProviderLoop {
    let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 64, memoryAvailableGb: 64, cpuCores: .init(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)
    let loop = try ProviderLoop(
        config: .init(coordinatorURL: "ws://127.0.0.1:9/ws", hardware: hardware,
            models: models.map { .init(id: $0, modelType: modelType, sizeBytes: 1, estimatedMemoryGb: 1) },
            config: .init(provider: .init(name: "cluster-pair-slot", autoUpdate: false), backend: .init(),
                coordinator: .init(url: "ws://127.0.0.1:9/ws", heartbeatIntervalSecs: 1)),
            executionRole: role),
        attestationSigner: ServeLoopTestSigner())
    await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
    await loop.setServeUsesHostServicesForTesting(false)
    await loop.setDaemonStateFileForTesting(FileManager.default.temporaryDirectory
        .appendingPathComponent("cluster-pair-slot-\(UUID().uuidString).json"))
    if role == .clusterMember { try await loop.prepareClusterMemberControlForTesting() }
    await loop.setClusterPairWarmupForTesting(timeoutSeconds: warmupTimeoutSeconds)
    return loop
}

extension ProviderLoop {
    func prepareClusterMemberControlForTesting() throws { try prepareClusterMemberControl() }
    var clusterPairSlotSnapshot: (id: UUID?, model: String?, slots: [String], containerless: Bool, refusing: Bool) {
        let slot = clusterPairSlot.flatMap { modelSlots[$0.modelID] }
        return (clusterPairSlot?.id, clusterPairSlot?.modelID, modelSlots.keys.sorted(),
                slot.map { $0.container == nil && $0.modelContainer.clusterPair != nil } ?? false,
                state.refusingNewWork)
    }
}

func clusterPairWait(_ timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let end = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Suite("Cluster pair slot", .serialized, .timeLimit(.minutes(1)))
struct ClusterPairSlotTests {
    @Test func publishedSlotIsContainerlessLoadedAndOpensAdmission() async throws {
        let loop = try await clusterPairMemberLoop()
        #expect(await loop.state.refusingNewWork)
        let owner = ScriptedPairOwner()
        let id = try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        let snapshot = await loop.clusterPairSlotSnapshot
        #expect(snapshot.id == id && snapshot.model == clusterPairFixtureModel)
        #expect(snapshot.slots == [clusterPairFixtureModel] && snapshot.containerless)
        #expect(!snapshot.refusing)
        #expect(await loop.state.warmModels == [clusterPairFixtureModel])
        let capacity = try #require(await loop.state.backendCapacity)
        #expect(capacity.slots.map(\.model) == [clusterPairFixtureModel])
        #expect(capacity.slots.first?.state == "idle")
        #expect(capacity.freeForLoadGb == 0)
        #expect(await loop.clusterPairSlotServes(clusterPairFixtureModel))
        #expect(!(await loop.clusterPairSlotServes("other/model")))
        #expect(await loop.retireClusterPairSlot(reason: "test"))
    }

    /// S18 warmup canary: one throwaway generation through the pair before
    /// admission opens (the owner's m3_warmup.py).
    @Test func theWarmupCanaryGeneratesOnceBeforeAdmissionOpens() async throws {
        let loop = try await clusterPairMemberLoop(warmupTimeoutSeconds: 30)
        let owner = ScriptedPairOwner()
        try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        let warmup = try #require(await loop.clusterPairWarmup)
        #expect(warmup.succeeded && warmup.tokens > 0 && warmup.tokens <= ProviderLoop.clusterWarmupMaxTokens, "\(warmup)")
        #expect(owner.reserveCount == 1, "the canary is the only request so far")
        #expect(await clusterPairWait { owner.lastLease?.releaseCount == 1 })
        let snapshot = await loop.clusterPairSlotSnapshot
        #expect(snapshot.model == clusterPairFixtureModel && !snapshot.refusing)
        #expect(await loop.retireClusterPairSlot(reason: "test"))
    }

    @Test func aFailedWarmupRetiresTheSlotWithoutOpeningAdmission() async throws {
        let loop = try await clusterPairMemberLoop(warmupTimeoutSeconds: 30)
        let owner = ScriptedPairOwner()
        owner.failFirstReservations = 1
        let id = try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        let warmup = try #require(await loop.clusterPairWarmup)
        #expect(!warmup.succeeded, "\(warmup)")
        #expect(await clusterPairWait { await loop.clusterPairSlotSnapshot.id == nil })
        let snapshot = await loop.clusterPairSlotSnapshot
        #expect(snapshot.slots.isEmpty && snapshot.refusing)
        #expect(await clusterPairWait { owner.shutdownCount == 1 })
        #expect(!(await loop.retireClusterPairSlot(id, reason: "late")))
        // The next formation warms up and serves.
        let next = ScriptedPairOwner()
        let nextID = try await loop.publishClusterPairSlot(clusterPairSpecification(next), owner: next)
        #expect(await loop.clusterPairWarmup?.succeeded == true)
        let reopened = await loop.clusterPairSlotSnapshot
        #expect(reopened.id == nextID && !reopened.refusing)
        #expect(await loop.retireClusterPairSlot(nextID, reason: "test"))
    }

    @Test func aWarmupThatNeverGeneratesTimesOutAndRetiresTheSlot() async throws {
        let loop = try await clusterPairMemberLoop(warmupTimeoutSeconds: 1)
        let owner = ScriptedPairOwner()
        let hold = DispatchSemaphore(value: 0)
        owner.hold = hold
        // The canary gives up at its deadline and cancels its request; the
        // slot then retires, which waits for that request to retire before
        // the owner shuts down (a wedged pair's cancel lands only at the
        // engine's safety deadline). Release the held request once the canary
        // has given up, as the cancel finally landing would.
        let release = Task {
            _ = await clusterPairWait(.seconds(30)) { await loop.clusterPairWarmup != nil }
            hold.signal()
        }
        try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        await release.value
        let warmup = try #require(await loop.clusterPairWarmup)
        #expect(!warmup.succeeded && (warmup.detail ?? "").contains("timed out"), "\(warmup)")
        #expect(warmup.seconds < 10, "the canary's own deadline bounds it: \(warmup)")
        #expect(await clusterPairWait { await loop.clusterPairSlotSnapshot.id == nil })
        #expect(await loop.state.refusingNewWork)
        #expect(await clusterPairWait { owner.shutdownCount == 1 })
    }

    @Test func aSecondPublicationIsRefusedAndAnUnreadyOwnerStaysWithTheCaller() async throws {
        let loop = try await clusterPairMemberLoop()
        let owner = ScriptedPairOwner()
        try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        let second = ScriptedPairOwner()
        await #expect(throws: ClusterPairSlotError.self) {
            try await loop.publishClusterPairSlot(clusterPairSpecification(second), owner: second)
        }
        #expect(second.shutdownCount == 0)
        #expect(await loop.retireClusterPairSlot(reason: "test"))

        let unready = ScriptedPairOwner(); unready.losePeer()
        await #expect(throws: ClusterPairSlotError.ownerUnavailable) {
            try await loop.publishClusterPairSlot(clusterPairSpecification(unready), owner: unready)
        }
        #expect(unready.shutdownCount == 0)
        #expect(await loop.clusterPairSlotSnapshot.slots.isEmpty)
        let mismatch = ScriptedPairOwner()
        var specification = try clusterPairSpecification(mismatch)
        specification = .init(publicModelID: specification.publicModelID, modelType: specification.modelType,
            tokenizer: specification.tokenizer, eosTokenIDs: specification.eosTokenIDs,
            expectedIdentity: ScriptedPairOwner().identity, profile: specification.profile)
        await #expect(throws: ClusterPairSlotError.ownerUnavailable) {
            try await loop.publishClusterPairSlot(specification, owner: mismatch)
        }
    }

    @Test func onlyAMemberPublishesAndOnlyItsRegisteredModel() async throws {
        let solo = try await clusterPairMemberLoop(role: .solo)
        let owner = ScriptedPairOwner()
        await #expect(throws: ClusterPairSlotError.notServing("solo provider")) {
            try await solo.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        }
        let member = try await clusterPairMemberLoop()
        let stranger = ScriptedPairOwner(model: "fixture/not-registered")
        await #expect(throws: ClusterPairSlotError.unknownModel) {
            try await member.publishClusterPairSlot(
                clusterPairSpecification(stranger, model: "fixture/not-registered"), owner: stranger)
        }
        #expect(await member.clusterPairSlotSnapshot.slots.isEmpty)
    }

    @Test func losingARankRetiresTheSlotAndShutsTheOwnerDown() async throws {
        let loop = try await clusterPairMemberLoop()
        let owner = ScriptedPairOwner()
        let id = try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        owner.losePeer()
        #expect(await clusterPairWait { await loop.clusterPairSlotSnapshot.id == nil })
        let snapshot = await loop.clusterPairSlotSnapshot
        #expect(snapshot.slots.isEmpty && snapshot.refusing)
        #expect(await loop.state.backendCapacity?.slots.isEmpty == true)
        #expect(await loop.state.warmModels.isEmpty)
        #expect(owner.shutdownCount == 1)
        // A stale retirement for the old slot does nothing; a fresh pair
        // publishes a new slot with a new identity.
        #expect(!(await loop.retireClusterPairSlot(id, reason: "late")))
        let next = ScriptedPairOwner()
        let nextID = try await loop.publishClusterPairSlot(clusterPairSpecification(next), owner: next)
        #expect(nextID != id)
        #expect(!(await loop.retireClusterPairSlot(id, reason: "stale")))
        #expect(await loop.clusterPairSlotSnapshot.id == nextID)
        #expect(await loop.retireClusterPairSlot(nextID, reason: "test"))
        #expect(next.shutdownCount == 1)
    }

    /// Retirement closes admission at once, stops the running request at its
    /// next token the clean way (no native cancel), and shuts the owner down
    /// only after that request retired.
    @Test func retirementStopsTheRequestCleanlyBeforeShuttingTheOwnerDown() async throws {
        let loop = try await clusterPairMemberLoop()
        let owner = ScriptedPairOwner()
        let hold = DispatchSemaphore(value: 0)
        owner.hold = hold
        try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        let bridge = try #require(await loop.modelSlots[clusterPairFixtureModel]?.engineV2)
        let stream = await bridge.submitTokenized(promptTokens: [1, 2, 3],
            request: ChatCompletionRequest(model: clusterPairFixtureModel, messages: [], temperature: 0, max_tokens: 3),
            requestId: "pair-drain", cacheEnabled: false)
        #expect(await clusterPairWait { owner.reserveCount == 1 })
        let retirement = Task { await loop.retireClusterPairSlot(reason: "test") }
        #expect(await clusterPairWait { await loop.state.refusingNewWork })
        #expect(await clusterPairWait { owner.lastLease?.cleanStopCount == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(owner.shutdownCount == 0)
        hold.signal()
        var text = "", reasons: [String] = []
        for await event in stream {
            switch event {
            case .chunk(let chunk): text += chunk
            case .info(_, let completion, _, let reason): reasons.append("\(completion):\(reason)")
            case .error, .terminal: reasons.append("failure")
            }
        }
        #expect(text.isEmpty, "the token that answers a clean stop is never delivered")
        // The host stopped it: one terminal, reported as not completed.
        #expect(reasons.count == 1, "terminals: \(reasons)")
        #expect(await retirement.value)
        #expect(owner.shutdownCount == 1)
        #expect(owner.lastLease?.cancelCount == 0 && owner.lastLease?.releaseCount == 1)
    }
}
