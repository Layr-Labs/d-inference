import Foundation
import Testing
@testable import ProviderCore

// Me first for a pair. While the owner uses the pair through its leader's local
// API, the pair takes no Darkbloom work; once the owner has been idle for
// `[local] me_first_idle_minutes` (two minutes by default), it takes Darkbloom
// work again. The leader decides for the pair: its heartbeat drains, which makes
// the whole pair unroutable, and every other member stays control-only and
// untouched. The pair's owner is scripted (no process, model or GPU), the
// coordinator is `MockCoordinator` on a loopback port or a client that never
// connects, local APIs bind 127.0.0.1 port 0, and the owner's clock is fake.

private let pairKey = "pair-me-first-fixture-key"
/// The owner's default idle time, in the policy's milliseconds.
private let twoMinutesMs: Int64 = 120_000
private let busyKeys = ["busy_reason", "busy_since_ms", "busy_addon"]

/// A member loop before `run()`: the slot's host when `hostsSlot` (the role a
/// rank-0 installation gives), with its local API when `localAPI`, and the
/// given `[local]` section and owner's clock.
private func pairMember(hostsSlot: Bool = true, localAPI: Bool = true, local: LocalSettings? = nil,
                        clock: MeFirstTestClock = MeFirstTestClock(),
                        name: String = "pair-me-first") async throws -> ProviderLoop {
    let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
        memoryGb: 64, memoryAvailableGb: 64, cpuCores: .init(total: 16, performance: 12, efficiency: 4),
        gpuCores: 40, memoryBandwidthGbs: 546)
    let loop = try ProviderLoop(
        config: .init(coordinatorURL: "ws://127.0.0.1:9/ws", hardware: hardware,
            models: [.init(id: clusterPairFixtureModel, modelType: "qwen3_5", sizeBytes: 1, estimatedMemoryGb: 1)],
            config: .init(provider: .init(name: name, autoUpdate: false), backend: .init(),
                coordinator: .init(url: "ws://127.0.0.1:9/ws", heartbeatIntervalSecs: 1), local: local),
            localEndpoint: localAPI ? .init(host: "127.0.0.1", port: 0, authToken: pairKey) : nil,
            executionRole: .clusterMember),
        attestationSigner: ServeLoopTestSigner())
    await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
    await loop.setServeUsesHostServicesForTesting(false)
    await loop.setDaemonStateFileForTesting(FileManager.default.temporaryDirectory
        .appendingPathComponent("pair-me-first-\(UUID().uuidString).json"))
    await loop.setClusterPairWarmupForTesting(timeoutSeconds: nil)
    await loop.useMeFirstClockForTesting(clock)
    if hostsSlot { try await loop.hostClusterPairSlotForTesting() }
    return loop
}

/// The slot's host with its local API, prepared as `run()` prepares it and
/// serving `owner`'s pair. Only the requests a test makes move its capacity.
private func servingLeader(_ owner: ScriptedPairOwner, local: LocalSettings? = nil,
                           clock: MeFirstTestClock) async throws -> ProviderLoop {
    let leader = try await pairMember(local: local, clock: clock)
    try await leader.prepareClusterMemberControlForTesting()
    try await leader.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
    await leader.stopClusterPairCapacityRefreshForTesting()
    return leader
}

/// The leader's `run()` against a `MockCoordinator` (`PairLeaderFixture`),
/// with its local API and no `[local]` section, so me first is on as by
/// default, on the owner's fake `clock`.
private func meFirstLeaderFixture(clock: MeFirstTestClock) async throws -> PairLeaderFixture {
    let fixture = try await PairLeaderFixture.make(localAPI: true, local: nil)
    await fixture.loop.useMeFirstClockForTesting(clock)
    return fixture
}

/// A client on `loop`'s state that never connects: it builds the heartbeat the
/// coordinator would get.
private func heartbeatBuilder(_ loop: ProviderLoop) async -> CoordinatorClient {
    CoordinatorClient(
        config: .init(url: "ws://127.0.0.1:0/ws/provider", hardware: ModelLoadingFixtures.defaultHardware,
                      models: [], backendName: "mlx-swift"),
        stats: AtomicProviderStats(), state: await loop.state, liveAPNsToken: { nil })
}

private func heartbeatFields(_ builder: CoordinatorClient) async throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(await builder.buildHeartbeatJSON().utf8)) as? [String: Any])
}

/// A heartbeat's JSON with sorted keys, without what every build samples
/// afresh: the system metrics and the capacity sequence.
private func stableHeartbeat(_ builder: CoordinatorClient) async throws -> String {
    var fields = try await heartbeatFields(builder)
    fields.removeValue(forKey: "system_metrics")
    if var capacity = fields["backend_capacity"] as? [String: Any] {
        capacity.removeValue(forKey: "capacity_seq")
        fields["backend_capacity"] = capacity
    }
    return String(decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
}

/// A member that does not host the slot, prepared as `run()` prepares it and
/// with the same (absent) `[local]` as the leader, and the heartbeat it gave
/// before anything happened.
private struct ControlOnlyMember {
    let loop: ProviderLoop
    let builder: CoordinatorClient
    let before: String

    init(rank: Int, clock: MeFirstTestClock) async throws {
        loop = try await pairMember(hostsSlot: false, localAPI: false, clock: clock, name: "pair-me-first-rank-\(rank)")
        try await loop.prepareClusterMemberControlForTesting()
        builder = await heartbeatBuilder(loop)
        before = try await stableHeartbeat(builder)
    }

    /// One member beat, then the heartbeat the coordinator would get.
    func beat() async throws -> String {
        _ = await loop.clusterMemberHeartbeat()
        return try await stableHeartbeat(builder)
    }
}

/// A local request in its own task, so a test can watch it wait for a lane.
private func pendingAcquisition(_ loop: ProviderLoop) -> Task<MultiModelBatchSchedulerEngine.AcquiredModel, Error> {
    Task { try await loop.acquireModelForLocal(clusterPairFixtureModel) }
}

extension ProviderLoop {
    /// Moves on each time the owner pause's resume timer is armed or cancelled.
    var meFirstTimerGenerationForTesting: UInt64 { meFirstTimerGeneration }

    /// Moves the owner's fake clock on and takes one member beat, in one actor
    /// turn: the owner pause's own timer can't end the pause in between, so a
    /// pause that ends here was ended by the beat.
    func clusterMemberHeartbeatForTesting(advancing clock: MeFirstTestClock, by milliseconds: Int64)
        -> ClusterMemberHeartbeatSample {
        clock.advance(ms: milliseconds)
        return clusterMemberHeartbeat()
    }

    /// The owner-use hook, began then ended, `pairs` times on the actor while
    /// `held` more of the owner's requests are in flight: the median time per
    /// pair over `rounds`. Leaves the counts as it found them.
    func clusterPairOwnerUseCostForTesting(held: Int, pairs: Int = 20_000, rounds: Int = 5) -> Duration {
        for _ in 0..<held { noteClusterPairLocalUse(.began) }
        defer { for _ in 0..<held { noteClusterPairLocalUse(.ended) } }
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<rounds {
            let start = clock.now
            for _ in 0..<pairs {
                noteClusterPairLocalUse(.began)
                noteClusterPairLocalUse(.ended)
            }
            samples.append((clock.now - start) / pairs)
        }
        return samples.sorted()[rounds / 2]
    }
}

@Suite("Me first for a pair: the leader's local use pauses the pair", .serialized, .timeLimit(.minutes(2)))
struct ClusterPairMeFirstTests {
    /// The owner's request through the leader's local API pauses the pair: the
    /// leader's heartbeat says `draining` for the owner at once, its slot stays
    /// published and loaded, and a member that does not host the slot keeps
    /// its heartbeat byte for byte. Two minutes after the owner's last request
    /// the member beat ends the pause, and Darkbloom requests are served again.
    @Test func theLeadersLocalUseDrainsItsHeartbeatForTheOwnerAndMembersAreUntouched() async throws {
        let clock = MeFirstTestClock()
        let fixture = try await meFirstLeaderFixture(clock: clock)
        let member = try await ControlOnlyMember(rank: 1, clock: clock)
        let task = fixture.start()
        do {
            let publicKey = try await fixture.register()
            let port = try await fixture.localPort()
            let state = await fixture.loop.state
            let owner = ScriptedPairOwner()
            try await fixture.loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
            #expect(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { snapshot in
                snapshot.heartbeats.contains { $0.status == .idle && $0.backendCapacity?.slots.count == 1 } } != nil,
                "open: the pair is routable")
            #expect(fixture.mock.snapshot().heartbeats.allSatisfy { $0.busy == nil })

            let since = clock.now
            let (data, reply) = try await URLSession.shared.data(for: try fixture.localChat(port: port))
            let body = String(decoding: data, as: UTF8.self)
            #expect((reply as? HTTPURLResponse)?.statusCode == 200 && body.contains("t5"), "\(body)")
            let paused = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { snapshot in
                snapshot.heartbeats.contains { $0.busy?.reason == .owner } }, "the leader announces the pause")
            let beat = try #require(paused.heartbeats.first { $0.busy?.reason == .owner })
            #expect(beat.status == .draining && beat.busy == ProviderBusy(reason: .owner, sinceMs: since))
            #expect(beat.backendCapacity?.slots.map(\.model) == [clusterPairFixtureModel], "the slot stays published")
            #expect(beat.warmModels == [clusterPairFixtureModel], "and loaded")
            #expect(state.ownerPausesPublic && !state.refusingNewWork, "only Darkbloom work pauses: local admission stays open")
            #expect(try await member.beat() == member.before, "the member's heartbeat is unchanged")

            // The member beat ends the pause two minutes after the owner's last request, not a millisecond sooner.
            #expect(await clusterPairWait { await fixture.loop.clusterPairLocalCounts == (0, 0, 0) })
            _ = await fixture.loop.clusterMemberHeartbeatForTesting(advancing: clock, by: twoMinutesMs - 1)
            #expect(state.ownerPausesPublic)
            let seen = fixture.mock.snapshot().heartbeats.count
            _ = await fixture.loop.clusterMemberHeartbeatForTesting(advancing: clock, by: 1)
            #expect(!state.ownerPausesPublic && state.busy == nil)
            let resumed = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { snapshot in
                snapshot.heartbeats.dropFirst(seen).contains { $0.status != .draining } }, "the leader announces the end")
            let open = try #require(resumed.heartbeats.dropFirst(seen).first { $0.status != .draining })
            #expect(open.busy == nil)
            try await fixture.push("after-the-pause", publicKey: publicKey)
            #expect(try await fixture.completed("after-the-pause"), "Darkbloom requests are served again")

            #expect(try await member.beat() == member.before)
            #expect(await member.loop.meFirstSnapshot == nil)
            let memberFields = try await heartbeatFields(member.builder)
            #expect(memberFields["status"] as? String == "draining", "the member stays control-only")
            for key in busyKeys { #expect(memberFields[key] == nil) }
        } catch { await fixture.cleanUp(task); throw error }
        await fixture.cleanUp(task)
    }

    /// The owner's idle time is counted on the member beat, on a fake clock: no
    /// time counts while a request of the owner's runs, a request during the
    /// countdown starts it again, and the pause outlasts the last request by
    /// two minutes to the millisecond. (Each step moves the clock and takes
    /// the beat in one actor turn, so the pause's own timer can't end it first.)
    @Test func theMemberBeatEndsThePauseTwoMinutesAfterTheOwnersLastRequest() async throws {
        let clock = MeFirstTestClock()
        let leader = try await servingLeader(ScriptedPairOwner(), clock: clock)
        let state = await leader.state
        #expect(await leader.meFirstSnapshot == MeFirstSnapshot(idleMs: twoMinutesMs, paused: false))

        let first = try await leader.acquireModelForLocal(clusterPairFixtureModel)
        let since = clock.now
        #expect(state.ownerPausesPublic && state.busy == ProviderBusy(reason: .owner, sinceMs: since))
        #expect(await leader.clusterMemberHeartbeatForTesting(advancing: clock, by: 10 * twoMinutesMs).phase == .serving)
        #expect(state.ownerPausesPublic, "no time is idle time while the owner's request runs")
        #expect(await !leader.meFirstResumeTimerArmedForTesting)

        await first.releaseToken.fire()
        _ = await leader.clusterMemberHeartbeatForTesting(advancing: clock, by: twoMinutesMs / 2)
        let second = try await leader.acquireModelForLocal(clusterPairFixtureModel)
        clock.advance(ms: 1_000)
        await second.releaseToken.fire()
        let last = clock.now
        _ = await leader.clusterMemberHeartbeatForTesting(advancing: clock, by: twoMinutesMs - 1)
        #expect(state.ownerPausesPublic, "the countdown starts again at the end of the owner's last request")
        #expect(await leader.meFirstSnapshot?.resumesAtMs == last + twoMinutesMs)

        #expect(await leader.clusterMemberHeartbeatForTesting(advancing: clock, by: 1).phase == .serving)
        #expect(!state.ownerPausesPublic && state.busy == nil)
        #expect(await leader.meFirstSnapshot == MeFirstSnapshot(idleMs: twoMinutesMs, paused: false, lastUseMs: last))
        #expect(await leader.currentDaemonState().meFirst?.paused == false)
        #expect(await !leader.meFirstResumeTimerArmedForTesting, "the resume ends the timer with it")
        #expect(await leader.retireClusterPairSlot(reason: "test"))
    }

    /// Darkbloom work accepted before the pause finishes and is never
    /// cancelled, and a dispatch that races the pause gets the typed
    /// `capacity / 503 / draining` refusal once, without reaching the pair. The
    /// owner's request waits for the lane the Darkbloom request holds, and the
    /// pause begins as it starts waiting. A leader stopped while the owner's
    /// idle time counts leaves no resume timer behind.
    @Test func darkbloomRequestsInFlightFinishAndARacingDispatchIsRefusedOnce() async throws {
        let clock = MeFirstTestClock()
        let fixture = try await meFirstLeaderFixture(clock: clock)
        let task = fixture.start()
        do {
            let publicKey = try await fixture.register()
            let owner = ScriptedPairOwner()
            let hold = DispatchSemaphore(value: 0)
            owner.hold = hold
            try await fixture.loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
            try await fixture.push("in-flight", publicKey: publicKey)
            #expect(await clusterPairWait { owner.reserveCount == 1 })
            let inFlight = try #require(owner.lastLease)

            let local = pendingAcquisition(fixture.loop)
            #expect(await clusterPairWait { await fixture.loop.clusterPairLocalWaitingCount == 1 })
            #expect(await fixture.loop.ownerPausesPublic, "the pause begins as the owner's request starts waiting")
            #expect(await fixture.loop.meFirstSnapshot?.darkbloomRequestsFinishing == 1)
            #expect(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { snapshot in
                snapshot.heartbeats.contains { $0.status == .draining && $0.busy?.reason == .owner } } != nil)

            try await fixture.push("raced", publicKey: publicKey)
            let refused = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) { snapshot in
                snapshot.inferenceErrors.contains { $0.requestId == "raced" } })
            let refusals = refused.inferenceErrors.filter { $0.requestId == "raced" }
            #expect(refusals.count == 1)
            #expect(refusals.first?.failureCode == .capacity && refusals.first?.statusCode == 503
                    && refusals.first?.errorReason == .draining, "\(refusals)")
            #expect(!refused.inferenceAccepted.contains { $0.requestId == "raced" })
            #expect(owner.reserveCount == 1, "the raced request never reached the pair")

            hold.signal()
            #expect(try await fixture.completed("in-flight"), "accepted before the pause, it finishes")
            #expect(inFlight.cancelCount == 0)
            #expect(await fixture.loop.stats.cancellationsReceived == 0)
            let acquired = try await local.value
            #expect(acquired.queueExitedAt != nil, "the owner's request took the lane the Darkbloom request freed")
            #expect(await clusterPairWait { await fixture.loop.meFirstSnapshot?.darkbloomRequestsFinishing == 0 })
            await acquired.releaseToken.fire()
            #expect(await fixture.loop.ownerPausesPublic, "the pause outlasts the owner's last request")
            #expect(await fixture.loop.meFirstResumeTimerArmedForTesting)

            task.cancel()
            #expect(await ServeLoopFixture.finishes(task, within: .seconds(30)))
            #expect(await !fixture.loop.meFirstResumeTimerArmedForTesting, "the stopped leader leaves no resume timer")
        } catch { await fixture.cleanUp(task); throw error }
        await fixture.cleanUp(task)
    }

    /// Nothing keys on two Macs: on a pair of three ranks with three lanes,
    /// three local requests on the leader and a fourth waiting one make one
    /// pause, which the member beat ends two minutes after the last of them.
    /// The two members that do not host the slot keep their heartbeats byte
    /// for byte, beat after beat.
    @Test func nothingKeysOnTwoRanks() async throws {
        let identity = DistributedResidentIdentity(membershipEpoch: UUID(), modelID: clusterPairFixtureModel,
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
            peers: (0..<3).map { .init(id: "rank-\($0)", buildSHA256: String(repeating: "\($0)", count: 64)) })
        let owner = ScriptedPairOwner(identity: identity)
        owner.lanes = 3
        let clock = MeFirstTestClock()
        let leader = try await servingLeader(owner, clock: clock)
        let leaderBuilder = await heartbeatBuilder(leader)
        var members: [ControlOnlyMember] = []
        for rank in 1...2 { members.append(try await ControlOnlyMember(rank: rank, clock: clock)) }

        var running: [MultiModelBatchSchedulerEngine.AcquiredModel] = []
        for _ in 0..<3 { running.append(try await leader.acquireModelForLocal(clusterPairFixtureModel)) }
        let fourth = pendingAcquisition(leader)
        #expect(await clusterPairWait { await leader.clusterPairLocalWaitingCount == 1 })
        #expect(await leader.meFirstSnapshot?.localRequestsInFlight == 4, "waiting or running, each is the owner's use")
        let paused = try await heartbeatFields(leaderBuilder)
        #expect(paused["status"] as? String == "draining" && paused["busy_reason"] as? String == "owner")
        for member in members { #expect(try await member.beat() == member.before) }

        await running.removeFirst().releaseToken.fire()
        running.append(try await fourth.value)
        for acquired in running { await acquired.releaseToken.fire() }
        #expect(await leader.meFirstSnapshot?.localRequestsInFlight == 0)
        _ = await leader.clusterMemberHeartbeatForTesting(advancing: clock, by: twoMinutesMs)
        let open = try await heartbeatFields(leaderBuilder)
        #expect(open["status"] as? String == "idle")
        for key in busyKeys { #expect(open[key] == nil) }
        for member in members {
            #expect(try await member.beat() == member.before)
            #expect(await member.loop.meFirstSnapshot == nil)
        }
        #expect(await leader.retireClusterPairSlot(reason: "test"))
    }

    /// With me first off (`[local] me_first = false`) the owner's use changes
    /// nothing a coordinator sees: the leader's heartbeat is byte for byte the
    /// same before, during and after a local request, and no pause, busy
    /// field, timer or status entry appears. With it on, the same steps move
    /// the status and the busy fields, and nothing else.
    @Test func withMeFirstOffTheLeaderIsByteForByteToday() async throws {
        for meFirst in [false, true] {
            let clock = MeFirstTestClock()
            let leader = try await servingLeader(ScriptedPairOwner(), local: meFirst ? nil : LocalSettings(meFirst: false),
                                                 clock: clock)
            let state = await leader.state
            let builder = await heartbeatBuilder(leader)
            let before = try await stableHeartbeat(builder)
            let acquired = try await leader.acquireModelForLocal(clusterPairFixtureModel)
            let during = try await stableHeartbeat(builder)
            await acquired.releaseToken.fire()
            _ = await leader.clusterMemberHeartbeatForTesting(advancing: clock, by: 10 * twoMinutesMs)
            let after = try await stableHeartbeat(builder)
            if meFirst {
                #expect(during != before)
                let moved = ["status"] + busyKeys
                #expect(during.droppingFields(moved) == before.droppingFields(moved), "during: \(during)")
                #expect(after == before, "the member beat ended the pause")
            } else {
                #expect(during == before && after == before, "before: \(before)\nduring: \(during)\nafter: \(after)")
                #expect(!state.ownerPausesPublic && state.busy == nil)
                #expect(await leader.meFirstSnapshot == nil)
                #expect(await leader.currentDaemonState().meFirst == nil)
                #expect(await !leader.meFirstResumeTimerArmedForTesting)
            }
            #expect(await leader.clusterPairLocalCounts == (0, 0, 0))
            #expect(await leader.retireClusterPairSlot(reason: "test"))
        }
    }

    /// The pause costs O(1) per request and nothing polls. On the wire, fifty
    /// local requests send one heartbeat when the pause begins and none of
    /// their own; a hundred member beats send nothing; the resume sends one.
    /// The only task is the owner pause's one timer: none while the first
    /// request runs, at most one arming per request's end, and one left once
    /// the idle time counts. With me first off, nothing is sent or started.
    /// The hook takes as long with ten thousand of the owner's requests in
    /// flight as with one, and a whole local acquire and release costs about
    /// the same with me first on as off (both printed).
    @Test func thePauseCostsO1PerRequestAndNothingPolls() async throws {
        for meFirst in [true, false] {
            let mock = MockCoordinator()
            let url = try await mock.start().mockProviderWebSocketURL()
            let clock = MeFirstTestClock()
            let leader = try await servingLeader(ScriptedPairOwner(), local: meFirst ? nil : LocalSettings(meFirst: false),
                                                 clock: clock)
            // The baseline heartbeat is an hour away: every heartbeat the mock sees is an event heartbeat.
            let client = CoordinatorClient(
                config: .init(url: url, hardware: ModelLoadingFixtures.defaultHardware, models: [],
                              backendName: "mlx-swift", heartbeatInterval: 3_600),
                stats: AtomicProviderStats(), state: await leader.state, liveAPNsToken: { nil })
            _ = await client.start()
            defer {
                Task {
                    await client.shutdown()
                    await mock.shutdown()
                }
            }
            _ = try #require(try await mock.awaitFirstRegister(timeout: .seconds(10)))
            await leader.setCoordinatorClientForTesting(client)
            try await Task.sleep(for: .milliseconds(200))
            let base = mock.snapshot().heartbeats.count

            let generation = await leader.meFirstTimerGenerationForTesting
            for index in 0..<50 {
                let acquired = try await leader.acquireModelForLocal(clusterPairFixtureModel)
                if index == 0 {
                    #expect(await !leader.meFirstResumeTimerArmedForTesting, "no timer while the first request runs")
                }
                await acquired.releaseToken.fire()
            }
            // The timer stands down when it finds a request running, and the next end arms it again.
            let armed = await leader.meFirstTimerGenerationForTesting - generation
            #expect(meFirst ? (1...50).contains(armed) : armed == 0, "timer armings for fifty requests: \(armed)")
            try await Task.sleep(for: .milliseconds(300))
            #expect(mock.snapshot().heartbeats.count == base + (meFirst ? 1 : 0))
            #expect(await leader.meFirstResumeTimerArmedForTesting == meFirst, "one timer, while the idle time counts")
            for _ in 0..<100 { _ = await leader.clusterMemberHeartbeat() }
            try await Task.sleep(for: .milliseconds(300))
            #expect(mock.snapshot().heartbeats.count == base + (meFirst ? 1 : 0), "the member beat sends nothing")

            if meFirst {
                let paused = try #require(mock.snapshot().heartbeats.last)
                #expect(paused.status == .draining && paused.busy?.reason == .owner)
                _ = await leader.clusterMemberHeartbeatForTesting(advancing: clock, by: twoMinutesMs)
                let resumed = try #require(try await mock.waitForSnapshot { $0.heartbeats.count == base + 2 })
                #expect(resumed.heartbeats.last?.status == .idle && resumed.heartbeats.last?.busy == nil)
                for _ in 0..<100 { _ = await leader.clusterMemberHeartbeat() }
                try await Task.sleep(for: .milliseconds(300))
                #expect(mock.snapshot().heartbeats.count == base + 2, "nothing after the resume")
            }
            #expect(await !leader.meFirstResumeTimerArmedForTesting)
            #expect(await leader.retireClusterPairSlot(reason: "test"))
        }

        // The hook's cost, measured on the actor, does not grow with the owner's requests in flight.
        let benchClock = MeFirstTestClock()
        let bench = try await servingLeader(ScriptedPairOwner(), clock: benchClock)
        let one = await bench.clusterPairOwnerUseCostForTesting(held: 1)
        let many = await bench.clusterPairOwnerUseCostForTesting(held: 10_000)
        let off = try await servingLeader(ScriptedPairOwner(), local: LocalSettings(meFirst: false), clock: MeFirstTestClock())
        let without = await off.clusterPairOwnerUseCostForTesting(held: 1)
        print("Pair me first, the owner-use hook per local request (began + ended): \(one) with 1 in flight, \(many) with 10,000; \(without) with me first off")
        #expect(many <= one * 3 + .microseconds(1), "with 10,000 in flight: \(many); with 1: \(one)")
        #expect(await bench.meFirstSnapshot?.localRequestsInFlight == 0)

        // A whole local acquire and release on the pair's lanes, as the local API makes them, with me first on and off.
        var cycles: [Bool: [Duration]] = [:]
        for (meFirst, leader) in [(true, bench), (false, off)] {
            var samples: [Duration] = []
            for _ in 0..<2_000 {
                let started = ContinuousClock.now
                let acquired = try await leader.acquireModelForLocal(clusterPairFixtureModel)
                await acquired.releaseToken.fire()
                samples.append(ContinuousClock.now - started)
            }
            cycles[meFirst] = samples.sorted()
        }
        let on = try #require(cycles[true]), shared = try #require(cycles[false])
        print("Pair me first, a local acquire and release (2,000 runs): p50 \(on[1_000]), p99 \(on[1_980]) with me first on; p50 \(shared[1_000]), p99 \(shared[1_980]) off")
        #expect(on[1_000] <= shared[1_000] * 3 + .microseconds(100), "p50 with me first on: \(on[1_000]); off: \(shared[1_000])")

        _ = await bench.clusterMemberHeartbeatForTesting(advancing: benchClock, by: twoMinutesMs)
        #expect(await !bench.ownerPausesPublic)
        #expect(await !bench.meFirstResumeTimerArmedForTesting)
        #expect(await bench.retireClusterPairSlot(reason: "test"))
        #expect(await off.retireClusterPairSlot(reason: "test"))
    }

    /// Me first is on only where the owner's requests meet the pair: the
    /// slot's host running its local API beside Darkbloom. There it is on
    /// unless `[local]` says `me_first = false`, with `[local]`'s idle time
    /// (two minutes by default); the leader's API beside Darkbloom is "both",
    /// whatever single-Mac mode `[local]` saved. A leader without a local API
    /// and every other member never pause.
    @Test func meFirstIsOnOnlyForTheSlotsHostWithItsLocalAPIUnlessLocalTurnsItOff() async throws {
        func idleMs(hostsSlot: Bool = true, localAPI: Bool = true, _ local: LocalSettings?) async throws -> Int64? {
            let loop = try await pairMember(hostsSlot: hostsSlot, localAPI: localAPI, local: local)
            try await loop.prepareClusterMemberControlForTesting()
            return await loop.meFirstSnapshot?.idleMs
        }
        #expect(try await idleMs(nil) == twoMinutesMs)
        #expect(try await idleMs(LocalSettings()) == twoMinutesMs)
        #expect(try await idleMs(LocalSettings(meFirst: true, meFirstIdleMinutes: 5)) == 300_000)
        #expect(try await idleMs(LocalSettings(mode: .network)) == twoMinutesMs)
        #expect(try await idleMs(LocalSettings(mode: .local, meFirstIdleMinutes: 1)) == 60_000)
        #expect(try await idleMs(LocalSettings(meFirst: false)) == nil)
        #expect(try await idleMs(localAPI: false, nil) == nil)
        #expect(try await idleMs(hostsSlot: false, localAPI: false, LocalSettings(meFirst: true)) == nil)
    }
}

private extension String {
    /// This heartbeat JSON (sorted keys) without `keys`.
    func droppingFields(_ keys: [String]) -> String {
        guard var fields = (try? JSONSerialization.jsonObject(with: Data(utf8))) as? [String: Any] else { return self }
        for key in keys { fields.removeValue(forKey: key) }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return self }
        return String(decoding: data, as: UTF8.self)
    }
}
