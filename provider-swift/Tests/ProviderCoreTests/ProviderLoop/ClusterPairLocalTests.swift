import Foundation
import Testing
import MLXLMCommon
@testable import ProviderCore

// The pair's leader takes the owner's local requests beside Darkbloom. The
// leader member's own local API serves its published pair slot: one bridge and
// one set of lanes for local and Darkbloom requests. The pair's owner is
// scripted (no process, model or GPU), the coordinator is `MockCoordinator` on
// a loopback port and the local API binds port 0: these prove the leader's
// admission, lanes and lifecycle, never a pair.

private let pairLocalToken = "pair-local-fixture-token"

/// The leader's local API in these tests: loopback, port 0, with the key.
private let keyedLocalAPI = LocalInferenceHTTPConfig(host: "127.0.0.1", port: 0, authToken: pairLocalToken)

private let leaderHardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4,
    chipTier: .max, memoryGb: 64, memoryAvailableGb: 64, cpuCores: .init(total: 16, performance: 12, efficiency: 4),
    gpuCores: 40, memoryBandwidthGbs: 546)

/// A member loop that has not run yet, with or without a local API: whether
/// it may keep one is the first thing `run()` decides
/// (`prepareClusterMemberControl`).
private func memberLoop(name: String, localEndpoint: LocalInferenceHTTPConfig?, model: String = clusterPairFixtureModel,
                        hardware: HardwareInfo = leaderHardware,
                        coordinatorURL: String = "ws://127.0.0.1:9/ws", local: LocalSettings? = nil) throws -> ProviderLoop {
    try ProviderLoop(
        config: .init(coordinatorURL: coordinatorURL, hardware: hardware,
            models: [.init(id: model, modelType: "qwen3_5", sizeBytes: 1, estimatedMemoryGb: 1)],
            config: .init(provider: .init(name: name, autoUpdate: false), backend: .init(),
                coordinator: .init(url: coordinatorURL, heartbeatIntervalSecs: 1), local: local),
            localEndpoint: localEndpoint, executionRole: .clusterMember),
        attestationSigner: ServeLoopTestSigner())
}

/// The leader's serving context for `model`. These tests publish their slots
/// themselves, so it never builds an owner.
private func pairServingContext(_ model: String = clusterPairFixtureModel) throws -> ClusterPairServingContext {
    try ClusterPairServingContext(publicModelID: model, modelType: "qwen3_5",
        tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99], profile: distributedTestProfile(),
        makeOwner: { _ in throw ClusterPairSlotError.notServing("these tests publish their own slots") })
}

/// Set when the work it marks has ended; read without waiting.
private final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() { lock.withLock { done = true } }
    var value: Bool { lock.withLock { done } }
}

/// A local acquisition in its own task, so a test can watch it wait.
private struct PendingAcquisition {
    let task: Task<MultiModelBatchSchedulerEngine.AcquiredModel, Error>
    let finished: Finished

    init(_ loop: ProviderLoop, model: String = clusterPairFixtureModel) {
        let finished = Finished()
        self.finished = finished
        task = Task {
            defer { finished.set() }
            return try await loop.acquireModelForLocal(model)
        }
    }
}

extension ProviderLoop {
    /// The serving host role a rank-0 installation gives the leader member
    /// (`installClusterPairServing`), without a two-rank installation: these
    /// tests publish their slots themselves, with any roster.
    func hostClusterPairSlotForTesting(model: String = clusterPairFixtureModel) throws {
        clusterPairServing = try pairServingContext(model)
    }

    var clusterPairLocalWaitingCount: Int { clusterPairLocalLanes.waitingCount }

    /// Local requests waiting for a lane, local requests in use (waiting or
    /// holding a lane: the owner-pause hook) and local reservations.
    var clusterPairLocalCounts: (waiting: Int, inUse: Int, reserved: Int) {
        (clusterPairLocalLanes.waitingCount, clusterPairLocalLanes.inUse, localReservations.totalInFlight)
    }

    func setClusterPairLocalQueueForTesting(maximumWaiting: Int) {
        clusterPairLocalLanes = .init(limits: .init(maximumWaiting: maximumWaiting))
    }

    /// Stops the periodic capacity refresh, one of the events that wakes waiters.
    func stopClusterPairCapacityRefreshForTesting() {
        clusterPairCapacityTask?.cancel()
        clusterPairCapacityTask = nil
    }
}

/// A leader member with no coordinator, the way `run()` prepares it, hosting its pair's slot.
private func pairLeaderLoop(warmupTimeoutSeconds: Double? = nil) async throws -> ProviderLoop {
    let loop = try await clusterPairMemberLoop(warmupTimeoutSeconds: warmupTimeoutSeconds)
    try await loop.hostClusterPairSlotForTesting()
    return loop
}

/// One local request on the pair's bridge, as the local API submits it.
private func submitLocal(_ acquired: MultiModelBatchSchedulerEngine.AcquiredModel, id: String,
                         maxTokens: Int = 3) async throws -> AsyncStream<GenerationEvent> {
    let bridge = try #require(acquired.engineV2Bridge)
    return await bridge.submitTokenized(promptTokens: [1, 2, 3],
        request: ChatCompletionRequest(model: clusterPairFixtureModel, messages: [], temperature: 0, max_tokens: maxTokens),
        requestId: id, cacheEnabled: false)
}

/// A stream's delivered text and terminals, read to its end.
private func drain(_ stream: AsyncStream<GenerationEvent>) async -> (text: String, terminals: [String]) {
    var text = "", terminals: [String] = []
    for await event in stream {
        switch event {
        case .logprobs: break
        case .chunk(let chunk): text += chunk
        case .info(_, let completion, _, let reason): terminals.append("\(completion):\(reason ?? "none")")
        case .error(let message): terminals.append("error: \(message)")
        case .terminal: terminals.append("terminal")
        }
    }
    return (text, terminals)
}

/// The HTTP status a local refusal surfaces as.
private func localStatus(_ error: Error) -> UInt16 { ProviderLoop.mapInferenceErrorToStatus(error) }

/// A leader member's `run()` against a `MockCoordinator`, with or without its
/// local API (127.0.0.1, port 0, a key). Its discovery record goes to a
/// directory of its own (`DARKBLOOM_LOCAL_DIR`), restored only once the loop
/// has stopped. `ClusterPairMeFirstTests` runs its leader here too.
struct PairLeaderFixture {
    let mock: MockCoordinator
    let loop: ProviderLoop
    let directory: URL
    let localAPI: Bool
    let previousLocalDirectory: String?

    /// `local` is the leader's `[local]` section. It defaults to shared
    /// serving (`me_first = false`): these tests are about the lanes, and a
    /// pause would refuse the Darkbloom requests they push.
    /// `ClusterPairMeFirstTests` passes its own.
    static func make(localAPI: Bool, warmupTimeoutSeconds: Double? = nil,
                     local: LocalSettings? = LocalSettings(meFirst: false)) async throws -> PairLeaderFixture {
        let mock = MockCoordinator()
        let url = try await mock.start().mockProviderWebSocketURL()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cluster-pair-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["DARKBLOOM_LOCAL_DIR"]
        if localAPI { try #require(setenv("DARKBLOOM_LOCAL_DIR", directory.path, 1) == 0) }
        let loop = try memberLoop(name: "cluster-pair-local", localEndpoint: localAPI ? keyedLocalAPI : nil,
                                  coordinatorURL: url, local: local)
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await loop.setServeUsesHostServicesForTesting(false)
        await loop.setDaemonStateFileForTesting(directory.appendingPathComponent("state.json"))
        await loop.setClusterPairWarmupForTesting(timeoutSeconds: warmupTimeoutSeconds)
        try await loop.hostClusterPairSlotForTesting()
        return .init(mock: mock, loop: loop, directory: directory, localAPI: localAPI, previousLocalDirectory: previous)
    }

    func start() -> Task<Void, Error> { Task { try await loop.run() } }

    /// Registration and the member acceptance; returns the provider's public key.
    func register() async throws -> String {
        let registration = try #require(try await mock.awaitFirstRegister(timeout: .seconds(15)))
        try await mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
        try await loop.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(5)))
        return try #require(registration.publicKey)
    }

    /// The local API's port, from its discovery record.
    func localPort() async throws -> UInt16 {
        #expect(await clusterPairWait { LocalEndpoint.readInfo() != nil })
        let info = try #require(LocalEndpoint.readInfo())
        #expect(info.port != 0 && info.apiKey == pairLocalToken && info.pid == ProcessInfo.processInfo.processIdentifier)
        return info.port
    }

    func localChat(port: UInt16, stream: Bool = true, maxTokens: Int = 3) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(pairLocalToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": clusterPairFixtureModel, "messages": [["role": "user", "content": "local"]],
            "max_tokens": maxTokens, "stream": stream, "temperature": 0, "reasoning_parser": "none"])
        return request
    }

    func push(_ id: String, publicKey: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": clusterPairFixtureModel, "messages": [["role": "user", "content": "pair"]],
            "max_tokens": 3, "stream": true, "temperature": 0, "reasoning_parser": "none"])
        try await mock.pushInferenceRequest(requestId: id, providerPublicKeyBase64: publicKey,
            chatRequestJSON: body, consumerKeyPair: .generate())
    }

    func completed(_ id: String, timeout: Duration = .seconds(10)) async throws -> Bool {
        try await mock.waitForSnapshot(timeout: timeout) { snapshot in
            snapshot.inferenceComplete.contains { $0.requestId == id } || snapshot.inferenceErrors.contains { $0.requestId == id }
        }.map { $0.inferenceErrors.allSatisfy { $0.requestId != id } } ?? false
    }

    func cleanUp(_ task: Task<Void, Error>) async {
        task.cancel()
        _ = await ServeLoopFixture.finishes(task, within: .seconds(30))
        await mock.shutdown()
        if localAPI {
            if let previousLocalDirectory { setenv("DARKBLOOM_LOCAL_DIR", previousLocalDirectory, 1) }
            else { unsetenv("DARKBLOOM_LOCAL_DIR") }
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("The pair's leader takes local requests beside Darkbloom", .serialized, .timeLimit(.minutes(2)))
struct ClusterPairLocalTests {
    /// The leader's local API serves the pair through the slot's own bridge:
    /// a 503 before the pair serves (never a 500), then the stream, with the
    /// local API's own cache partition and the discovery record of its port.
    @Test func theLeaderServesItsPairOnItsLocalAPI() async throws {
        let fixture = try await PairLeaderFixture.make(localAPI: true, warmupTimeoutSeconds: 30)
        let task = fixture.start()
        do {
            _ = try await fixture.register()
            let port = try await fixture.localPort()
            // No pair yet: refused for now, with a reason, not a 500.
            let (earlyBody, earlyReply) = try await URLSession.shared.data(for: try fixture.localChat(port: port))
            #expect((earlyReply as? HTTPURLResponse)?.statusCode == 503, "\(String(decoding: earlyBody, as: UTF8.self))")
            #expect(String(decoding: earlyBody, as: UTF8.self).contains("\"error\""))

            let owner = ScriptedPairOwner()
            try await fixture.loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
            #expect(await fixture.loop.clusterPairWarmup?.succeeded == true)
            let (data, reply) = try await URLSession.shared.data(for: try fixture.localChat(port: port))
            let body = String(decoding: data, as: UTF8.self)
            #expect((reply as? HTTPURLResponse)?.statusCode == 200, "\(body)")
            #expect(body.contains("t5") && body.contains("t7") && body.hasSuffix("data: [DONE]\n\n"), "\(body)")
            // The warmup canary's reservation, then this request's: the pair's own owner served it.
            #expect(owner.reserveCount == 2)
            // The local API's partition: no tenant salt, never a coordinator scope.
            let local = try #require(owner.reservedRequests.last)
            #expect(local.cacheSalt == nil && local.prefixCacheEnabled)
            #expect(await clusterPairWait { await fixture.loop.clusterPairLocalCounts == (0, 0, 0) })
        } catch { await fixture.cleanUp(task); throw error }
        await fixture.cleanUp(task)
    }

    /// Only the member that hosts the slot runs a local API, and always with a
    /// key: the real rank-0 installation serves; rank 1, a member with no pair
    /// installation and a host without a key refuse it at once.
    @Test func onlyTheSlotsHostRunsALocalAPIAndAlwaysWithAKey() async throws {
        // The contract fixture's installations are for "fixture-model" on an Apple M4.
        let contract = try MemberContractFixture()
        let context = try pairServingContext("fixture-model")
        func member(_ endpoint: LocalInferenceHTTPConfig = keyedLocalAPI) throws -> ProviderLoop {
            try memberLoop(name: "cluster-pair-local-host", localEndpoint: endpoint, model: "fixture-model",
                hardware: HardwareInfo(machineModel: "fixture", chipName: "Apple M4", chipFamily: .m4, chipTier: .pro,
                    memoryGb: 24, memoryAvailableGb: 20, cpuCores: .init(total: 12, performance: 8, efficiency: 4),
                    gpuCores: 16, memoryBandwidthGbs: 200))
        }

        let leader = try member()
        try await leader.installNativePairMember(contract.installations[0])
        try await leader.installClusterPairServing(context)
        try await leader.prepareClusterMemberControlForTesting()
        #expect(await leader.state.refusingNewWork, "the leader stays a control-only member until its slot serves")

        let follower = try member()
        try await follower.installNativePairMember(contract.installations[1])
        await #expect(throws: ClusterMemberControlError.incompatibleConfiguration) {
            try await follower.prepareClusterMemberControlForTesting()
        }
        let uninstalled = try member()
        await #expect(throws: ClusterMemberControlError.incompatibleConfiguration) {
            try await uninstalled.prepareClusterMemberControlForTesting()
        }
        let keyless = try member(.init(host: "127.0.0.1", port: 0, authToken: nil))
        try await keyless.installNativePairMember(contract.installations[0])
        try await keyless.installClusterPairServing(context)
        await #expect(throws: ClusterMemberControlError.incompatibleConfiguration) {
            try await keyless.prepareClusterMemberControlForTesting()
        }
    }

    /// While the pair does not serve (before its slot, after it retired), a
    /// local request is refused for now: 503, never the member guard's
    /// untyped error (a 500). Another model is not this pair's: 404. A refused
    /// request never counts as the owner's use.
    @Test func aLocalRequestWhileThePairIsNotServingIs503() async throws {
        let loop = try await pairLeaderLoop()
        func refusal(_ model: String = clusterPairFixtureModel) async -> Error? {
            do { _ = try await loop.acquireModelForLocal(model); return nil } catch { return error }
        }
        let early = try #require(await refusal())
        #expect(early is MultiModelBatchSchedulerEngineError && localStatus(early) == 503, "\(early)")
        let other = try #require(await refusal("fixture/other"))
        #expect(localStatus(other) == 404, "\(other)")

        let owner = ScriptedPairOwner()
        let id = try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        let served = try await loop.acquireModelForLocal(clusterPairFixtureModel)
        await served.releaseToken.fire()
        #expect(await loop.retireClusterPairSlot(id, reason: "test"))
        let late = try #require(await refusal())
        #expect(late is MultiModelBatchSchedulerEngineError && localStatus(late) == 503, "\(late)")
        #expect(await loop.clusterPairLocalCounts == (0, 0, 0))
    }

    /// One lane: a local request that finds it busy waits, without polling,
    /// and takes it when the request holding it is released; later ones keep
    /// their arrival order. The owner's use counts every waiting or running
    /// local request and returns to zero.
    @Test func aLocalRequestWaitsForALaneAndTakesItWhenItIsReleased() async throws {
        let loop = try await pairLeaderLoop()
        let owner = ScriptedPairOwner()
        let hold = DispatchSemaphore(value: 0)
        owner.hold = hold
        try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        let first = try await loop.acquireModelForLocal(clusterPairFixtureModel)
        #expect(first.queueExitedAt == nil, "a free lane is taken at once, not through the queue")
        let firstStream = try await submitLocal(first, id: "local-first")
        #expect(await clusterPairWait { owner.reserveCount == 1 })

        let second = PendingAcquisition(loop)
        #expect(await clusterPairWait { await loop.clusterPairLocalWaitingCount == 1 })
        let third = PendingAcquisition(loop)
        #expect(await clusterPairWait { await loop.clusterPairLocalWaitingCount == 2 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!second.finished.value && !third.finished.value, "the lane is busy: both wait")
        #expect(await loop.clusterPairLocalCounts == (2, 3, 1))

        hold.signal()
        #expect(await drain(firstStream).text == "t5t6t7")
        await first.releaseToken.fire()
        let secondAcquired = try await second.task.value
        #expect(secondAcquired.queueExitedAt != nil, "its first-token budget starts when the queue lets it go")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!third.finished.value, "the lane is the second's now: the third keeps waiting")
        #expect(await loop.clusterPairLocalCounts == (1, 2, 1))

        await secondAcquired.releaseToken.fire()
        let thirdAcquired = try await third.task.value
        #expect(await loop.clusterPairLocalCounts == (0, 1, 1))
        await thirdAcquired.releaseToken.fire()
        #expect(await loop.clusterPairLocalCounts == (0, 0, 0))
        #expect(await loop.retireClusterPairSlot(reason: "test"))
    }

    /// The queue is bounded as `cluster local`'s is: a request that finds it
    /// full is refused with 429, and one that waited past its ceiling with
    /// 503. A cancelled waiter leaves at once from wherever it waits: the
    /// second here, which nothing else wakes (the capacity refresh wakes only
    /// the first).
    @Test func aFullQueueIs429AWaiterPastItsCeilingIs503AndACancelledWaiterLeaves() async throws {
        let loop = try await pairLeaderLoop()
        await loop.setClusterPairLocalQueueForTesting(maximumWaiting: 2)
        let owner = ScriptedPairOwner()
        // A 500 ms request lifetime: with one lane and two waiting places, a
        // waiter's ceiling is three lifetimes.
        let profile = try DistributedResidentExecutionProfile(id: owner.profileID, vocabularySize: 100,
            maxPromptTokens: 8192, maxOutputTokens: 128, maxContextTokens: 8192 + 128, requestTimeout: .milliseconds(500))
        let specification = ClusterPairSlotSpecification(publicModelID: clusterPairFixtureModel, modelType: "qwen3_5",
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99], expectedIdentity: owner.identity,
            profile: profile, artifactBytes: 1 << 30)
        try await loop.publishClusterPairSlot(specification, owner: owner)
        let holder = try await loop.acquireModelForLocal(clusterPairFixtureModel)

        let first = PendingAcquisition(loop)
        #expect(await clusterPairWait { await loop.clusterPairLocalWaitingCount == 1 })
        let second = PendingAcquisition(loop)
        #expect(await clusterPairWait { await loop.clusterPairLocalWaitingCount == 2 })
        do { _ = try await loop.acquireModelForLocal(clusterPairFixtureModel); Issue.record("a full queue admitted") }
        catch { #expect(localStatus(error) == 429, "\(error)") }

        second.task.cancel()
        // Bounded either way: without its own wake, the second would leave only
        // once the first's ceiling put it in front.
        #expect(await clusterPairWait(.milliseconds(300)) { second.finished.value },
                "a cancelled waiter behind another leaves at once")
        await #expect(throws: CancellationError.self) { _ = try await second.task.value }
        #expect(await loop.clusterPairLocalCounts == (1, 2, 1), "only the first still waits")

        let started = ContinuousClock.now
        do { _ = try await first.task.value; Issue.record("a waiter outlived its ceiling") }
        catch { #expect(localStatus(error) == 503, "\(error)") }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await loop.clusterPairLocalCounts == (0, 1, 1))
        await holder.releaseToken.fire()
        #expect(await loop.clusterPairLocalCounts == (0, 0, 0))
        // The lane is free again: taken at once.
        let next = try await loop.acquireModelForLocal(clusterPairFixtureModel)
        #expect(next.queueExitedAt == nil)
        await next.releaseToken.fire()
    }

    /// Nothing slips in during the warmup canary: a local request made while
    /// it runs waits until admission opens, and a pair that retires during
    /// the canary refuses it with 503. Two lanes: the canary holds one and
    /// leaves the other free, so only the admission gate keeps the request out
    /// (with one lane, the engine's own count would keep it out anyway).
    @Test func aLocalRequestDuringTheWarmupCanaryWaitsForAdmission() async throws {
        let loop = try await pairLeaderLoop(warmupTimeoutSeconds: 30)
        let owner = ScriptedPairOwner()
        owner.lanes = 2
        let hold = DispatchSemaphore(value: 0)
        owner.hold = hold
        let publication = Task { try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner) }
        #expect(await clusterPairWait { await loop.clusterPairSlotSnapshot.id != nil && owner.reserveCount == 1 })
        let early = PendingAcquisition(loop)
        #expect(await clusterPairWait { await loop.clusterPairLocalWaitingCount == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(!early.finished.value, "admission is closed while the canary runs")
        #expect(await loop.clusterPairLocalCounts == (1, 1, 0), "no local request holds the lane the canary left free")
        hold.signal()
        _ = try await publication.value
        #expect(await loop.clusterPairWarmup?.succeeded == true)
        let admitted = try await early.task.value
        #expect(admitted.queueExitedAt != nil && owner.reserveCount == 1)
        await admitted.releaseToken.fire()
        #expect(await loop.retireClusterPairSlot(reason: "test"))

        // A rank lost during the canary retires the slot: the waiter hears 503.
        let lost = ScriptedPairOwner()
        let lostHold = DispatchSemaphore(value: 0)
        lost.hold = lostHold
        let failing = Task { try await loop.publishClusterPairSlot(clusterPairSpecification(lost), owner: lost) }
        #expect(await clusterPairWait { await loop.clusterPairSlotSnapshot.id != nil && lost.reserveCount == 1 })
        let refused = PendingAcquisition(loop)
        #expect(await clusterPairWait { await loop.clusterPairLocalWaitingCount == 1 })
        lost.losePeer()
        lostHold.signal()
        do { _ = try await refused.task.value; Issue.record("admitted into a retired pair") }
        catch { #expect(localStatus(error) == 503, "\(error)") }
        _ = try? await failing.value
        #expect(await clusterPairWait { await loop.clusterPairSlotSnapshot.id == nil })
        #expect(await loop.clusterPairLocalCounts == (0, 0, 0))
    }

    /// A drain (a stop or an update) refuses the waiting local requests at
    /// once, as it refuses new ones: the pair's 503 (`clusterPairNotServing`,
    /// which its API answers typed), while the request holding the lane
    /// finishes. The capacity refresh is off here: the drain alone wakes them.
    @Test func aDrainRefusesWaitingLocalRequestsAtOnce() async throws {
        let loop = try await pairLeaderLoop()
        let owner = ScriptedPairOwner()
        try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        await loop.stopClusterPairCapacityRefreshForTesting()
        let holder = try await loop.acquireModelForLocal(clusterPairFixtureModel)
        let waiter = PendingAcquisition(loop)
        #expect(await clusterPairWait { await loop.clusterPairLocalWaitingCount == 1 })
        let started = ContinuousClock.now
        await loop.beginServingDrain(owner: .lifecycle)
        let refused = await clusterPairWait(.milliseconds(500)) { waiter.finished.value }
        #expect(refused && ContinuousClock.now - started < .seconds(1), "the drain refuses the waiter itself")
        if !refused { waiter.task.cancel() }
        do { _ = try await waiter.task.value; Issue.record("a drain admitted a waiting request") }
        catch { #expect(error as? MultiModelBatchSchedulerEngineError == ProviderLoop.clusterPairNotServing, "\(error)") }
        do { _ = try await loop.acquireModelForLocal(clusterPairFixtureModel); Issue.record("a drain admitted a new request") }
        catch { #expect(error as? MultiModelBatchSchedulerEngineError == ProviderLoop.clusterPairNotServing, "\(error)") }
        #expect(await loop.clusterPairLocalCounts == (0, 1, 1))
        await holder.releaseToken.fire()
        #expect(await loop.clusterPairLocalCounts == (0, 0, 0))
    }

    /// A lost rank retires the slot: a queued local request hears 503 and the
    /// one in flight ends with its terminal, never a hang.
    @Test func retirementWhileQueuedIs503AndTheRequestInFlightEnds() async throws {
        let loop = try await pairLeaderLoop()
        let owner = ScriptedPairOwner()
        let hold = DispatchSemaphore(value: 0)
        owner.hold = hold
        try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        let running = try await loop.acquireModelForLocal(clusterPairFixtureModel)
        let stream = try await submitLocal(running, id: "local-running")
        #expect(await clusterPairWait { owner.reserveCount == 1 })
        let queued = PendingAcquisition(loop)
        #expect(await clusterPairWait { await loop.clusterPairLocalWaitingCount == 1 })

        owner.losePeer()
        do { _ = try await queued.task.value; Issue.record("a queued request outlived its pair") }
        catch { #expect(localStatus(error) == 503, "\(error)") }
        hold.signal()
        let ended = await drain(stream)
        #expect(ended.terminals.count == 1, "one terminal: \(ended.terminals)")
        await running.releaseToken.fire()
        #expect(await clusterPairWait { await loop.clusterPairSlotSnapshot.id == nil })
        #expect(await loop.clusterPairLocalCounts == (0, 0, 0))
        #expect(owner.shutdownCount == 1)
    }

    /// Nothing keys on two Macs: a pair of three ranks with three lanes serves
    /// three local requests at once and queues the fourth; the two members
    /// that do not host the slot refuse a local API. A roster still needs two
    /// distinct ranks or more, and an impostor rank is still refused.
    @Test func nothingKeysOnTwoRanks() async throws {
        let epoch = UUID()
        func identity(_ peers: [String]) -> DistributedResidentIdentity {
            .init(membershipEpoch: epoch, modelID: clusterPairFixtureModel,
                  artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
                  peers: peers.enumerated().map { .init(id: $0.element, buildSHA256: String(repeating: "\($0.offset)", count: 64)) })
        }
        #expect(throws: DistributedEngineError.self) { try identity(["rank-0"]).validate() }
        #expect(throws: DistributedEngineError.self) { try identity(["rank-0", "rank-0"]).validate() }
        #expect(throws: DistributedEngineError.self) { try identity(["rank-0", "rank-1", "rank-0"]).validate() }
        let roster = identity(["rank-0", "rank-1", "rank-2"])
        // The engine serves only an owner whose readiness is the expected
        // roster, peer for peer: one other rank in the third place is refused.
        let impostor = ScriptedPairOwner(identity: identity(["rank-0", "rank-1", "rank-x"]))
        #expect(throws: DistributedEngineError.unavailable) {
            _ = try DistributedEngineFactory.makeBridge(owner: impostor, expectedIdentity: roster,
                profile: try distributedTestProfile(), tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
        }
        let owner = ScriptedPairOwner(identity: roster)
        owner.lanes = 3
        let leader = try await pairLeaderLoop()
        try await leader.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        var running: [MultiModelBatchSchedulerEngine.AcquiredModel] = []
        for _ in 0..<3 { running.append(try await leader.acquireModelForLocal(clusterPairFixtureModel)) }
        #expect(running.allSatisfy { $0.queueExitedAt == nil })
        let fourth = PendingAcquisition(leader)
        #expect(await clusterPairWait { await leader.clusterPairLocalWaitingCount == 1 })
        #expect(await leader.clusterPairLocalCounts == (1, 4, 3))
        await running.removeFirst().releaseToken.fire()
        let admitted = try await fourth.task.value
        #expect(admitted.queueExitedAt != nil)
        for acquired in running + [admitted] { await acquired.releaseToken.fire() }
        #expect(await leader.clusterPairLocalCounts == (0, 0, 0))
        #expect(await leader.retireClusterPairSlot(reason: "test"))

        for rank in 1...2 {
            let member = try memberLoop(name: "cluster-rank-\(rank)", localEndpoint: keyedLocalAPI)
            await #expect(throws: ClusterMemberControlError.incompatibleConfiguration) {
                try await member.prepareClusterMemberControlForTesting()
            }
        }
    }

    /// A local request waits behind a Darkbloom request holding the one lane,
    /// and is woken when that request ends.
    @Test func aLocalRequestWaitsBehindADarkbloomRequestAndRunsWhenItEnds() async throws {
        let fixture = try await PairLeaderFixture.make(localAPI: true)
        let task = fixture.start()
        do {
            let publicKey = try await fixture.register()
            let port = try await fixture.localPort()
            let owner = ScriptedPairOwner()
            let hold = DispatchSemaphore(value: 0)
            owner.hold = hold
            try await fixture.loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
            try await fixture.push("darkbloom-1", publicKey: publicKey)
            #expect(await clusterPairWait { owner.reserveCount == 1 })
            let local = Task { try await URLSession.shared.data(for: try fixture.localChat(port: port)) }
            #expect(await clusterPairWait { await fixture.loop.clusterPairLocalWaitingCount == 1 })
            hold.signal()
            #expect(try await fixture.completed("darkbloom-1"))
            #expect(await clusterPairWait { owner.reserveCount == 2 }, "the local request took the lane it freed")
            hold.signal()
            let (data, reply) = try await local.value
            #expect((reply as? HTTPURLResponse)?.statusCode == 200, "\(String(decoding: data, as: UTF8.self))")
            #expect(await clusterPairWait { await fixture.loop.clusterPairLocalCounts == (0, 0, 0) })
        } catch { await fixture.cleanUp(task); throw error }
        await fixture.cleanUp(task)
    }

    /// The local API adds nothing to a Darkbloom request's path: with no local
    /// request queued, the leader admits Darkbloom requests as fast as a
    /// leader without a local API (the same code path; the bound only catches
    /// an added wait, not scheduling noise), including the moment a local
    /// request has just released the lane.
    @Test func aDarkbloomRequestSeesNoExtraWaitWhenNoLocalRequestIsQueued() async throws {
        var medians: [Bool: Duration] = [:]
        for localAPI in [false, true] {
            let fixture = try await PairLeaderFixture.make(localAPI: localAPI)
            let task = fixture.start()
            do {
                let publicKey = try await fixture.register()
                let owner = ScriptedPairOwner()
                try await fixture.loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
                var samples: [Duration] = []
                for index in 0..<9 {
                    if localAPI, index % 3 == 0 {
                        // A local request has just ended: the lane is free at once.
                        let acquired = try await fixture.loop.acquireModelForLocal(clusterPairFixtureModel)
                        await acquired.releaseToken.fire()
                    }
                    let reserved = owner.reserveCount
                    let started = ContinuousClock.now
                    try await fixture.push("darkbloom-\(index)", publicKey: publicKey)
                    while owner.reserveCount == reserved, ContinuousClock.now - started < .seconds(10) {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    samples.append(ContinuousClock.now - started)
                    #expect(try await fixture.completed("darkbloom-\(index)"))
                }
                medians[localAPI] = samples.sorted()[samples.count / 2]
                if localAPI { #expect(await fixture.loop.clusterPairLocalCounts == (0, 0, 0)) }
            } catch { await fixture.cleanUp(task); throw error }
            await fixture.cleanUp(task)
        }
        let baseline = try #require(medians[false]), withLocalAPI = try #require(medians[true])
        #expect(withLocalAPI <= baseline * 2 + .milliseconds(25),
                "admission with no local request queued: \(withLocalAPI); without a local API: \(baseline)")
    }

    /// Stopping the leader lets a local stream in flight finish, then frees
    /// its port and removes its discovery record.
    @Test func stoppingTheLeaderWithALocalStreamDrainsItAndFreesThePort() async throws {
        let fixture = try await PairLeaderFixture.make(localAPI: true)
        let task = fixture.start()
        do {
            _ = try await fixture.register()
            let port = try await fixture.localPort()
            let owner = ScriptedPairOwner()
            let hold = DispatchSemaphore(value: 0)
            owner.hold = hold
            try await fixture.loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
            let local = Task { try await URLSession.shared.data(for: try fixture.localChat(port: port)) }
            #expect(await clusterPairWait { owner.reserveCount == 1 })
            task.cancel()
            try await Task.sleep(for: .milliseconds(200))
            #expect(owner.shutdownCount == 0, "the stop waits for the local stream")
            hold.signal()
            let (data, reply) = try await local.value
            let body = String(decoding: data, as: UTF8.self)
            #expect((reply as? HTTPURLResponse)?.statusCode == 200 && body.hasSuffix("data: [DONE]\n\n"), "\(body)")
            #expect(await ServeLoopFixture.finishes(task, within: .seconds(30)))
            #expect(owner.shutdownCount == 1)
            #expect(LocalEndpoint.readInfo() == nil, "the discovery record is removed")
            var probe = try fixture.localChat(port: port)
            probe.timeoutInterval = 2
            let closed = await clusterPairWait {
                do { _ = try await URLSession.shared.data(for: probe); return false } catch { return true }
            }
            #expect(closed, "nothing listens on the port")
        } catch { await fixture.cleanUp(task); throw error }
        await fixture.cleanUp(task)
    }
}
