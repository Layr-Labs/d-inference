/// The coordinated update of a `darkbloom cluster` pair (`ClusterPairUpdateCycle`), with real components: each Mac's
/// cycle runs the real updater against its own temporary install root (`UpdateRecoveryFixture`) and a loopback
/// release server (`MockCoordinator`), and each Mac's part is a real member loop on that coordinator, whose pair slot
/// is served by a scripted owner and which answers the drain through its lifecycle mailbox. No binary is replaced
/// outside the temporary roots, no model or GPU runs, and nothing leaves loopback.

import Foundation
import Testing
@testable import ProviderCore

private let pairTiming: ClusterPairUpdateCycle.Timing = {
    var timing = ClusterPairUpdateCycle.Timing()
    timing.partnerStageWait = 30
    timing.drainTimeout = 15
    timing.partnerDrainWait = 30
    timing.poll = 0.05
    timing.partAnswer = 10
    return timing
}()

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ line: String) { lock.withLock { values.append(line) } }
    var all: [String] { lock.withLock { values } }
}

private func poll(seconds: Double, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

private func stagingDirectories(_ fixture: UpdateRecoveryFixture) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: fixture.installRoot.path)) ?? []).filter { $0.hasPrefix(".update-staging-") }
}

/// One Mac of the pair: its install, its loopback coordinator (which also serves the release) and its part.
private struct PairMac {
    let fixture: UpdateRecoveryFixture
    let mock: MockCoordinator
    let baseURL: URL
    let directory: URL
    let loop: ProviderLoop?
    let task: Task<Void, Error>?
    let publicKey: String?

    var progressPath: URL { directory.appendingPathComponent("service-update.json") }
    var mailboxDirectory: URL { directory.appendingPathComponent("lifecycle") }
    var mailbox: LifecycleMailbox { LifecycleMailbox(identity: ProcessIdentity.current()!, directory: mailboxDirectory) }

    /// `part`: run a member loop as this Mac's part (registered with its coordinator, no pair slot yet).
    static func make(release: MockReleaseFixture? = nil, part: Bool = true) async throws -> PairMac {
        let fixture = try UpdateRecoveryFixture()
        let mock = MockCoordinator(release: release ?? fixture.mockReleaseFixture(), releaseArtifact: fixture.artifact)
        let baseURL = try await mock.start()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pair-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard part else {
            return PairMac(fixture: fixture, mock: mock, baseURL: baseURL, directory: directory, loop: nil, task: nil, publicKey: nil)
        }
        let url = baseURL.mockProviderWebSocketURL()
        let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 64, memoryAvailableGb: 64, cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(
            config: .init(coordinatorURL: url, hardware: hardware,
                models: [.init(id: clusterPairFixtureModel, modelType: "qwen3_5", sizeBytes: 1, estimatedMemoryGb: 1)],
                config: .init(provider: .init(name: "cluster-pair-update", autoUpdate: false), backend: .init(),
                    coordinator: .init(url: url, heartbeatIntervalSecs: 1)),
                executionRole: .clusterMember, clusterMemberStopsOnDisconnect: false, clusterMemberAnswersUpdateDrain: true),
            attestationSigner: ServeLoopTestSigner())
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await loop.setServeUsesHostServicesForTesting(false)
        await loop.setDaemonStateFileForTesting(directory.appendingPathComponent("state.json"))
        await loop.setClusterPairWarmupForTesting(timeoutSeconds: nil)
        let task = Task { try await loop.run() }
        let registration = try #require(try await mock.awaitFirstRegister(timeout: .seconds(15)))
        try await mock.pushClusterMemberAcceptance(nonce: try #require(registration.memberRegistrationNonce))
        try await loop.waitForClusterMemberRegistration(until: .now.advanced(by: .seconds(5)))
        return PairMac(fixture: fixture, mock: mock, baseURL: baseURL, directory: directory, loop: loop, task: task,
                       publicKey: registration.publicKey)
    }

    /// Makes this Mac rank 0: its part serves the pair slot; every request waits for `owner.hold` before its first token.
    func servePair() async throws -> ScriptedPairOwner {
        let owner = ScriptedPairOwner()
        owner.hold = DispatchSemaphore(value: 0)
        let loop = try #require(self.loop)
        try await loop.publishClusterPairSlot(clusterPairSpecification(owner), owner: owner)
        #expect(try await mock.waitForSnapshot(timeout: .seconds(10)) { $0.heartbeats.last?.status == .idle } != nil)
        return owner
    }

    func push(_ id: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": clusterPairFixtureModel, "messages": [["role": "user", "content": "pair"]],
            "max_tokens": 3, "stream": true, "temperature": 0, "reasoning_parser": "none"])
        try await mock.pushInferenceRequest(requestId: id, providerPublicKeyBase64: try #require(publicKey),
            chatRequestJSON: body, consumerKeyPair: .generate())
    }

    func cycle(partner: PairMac, updater: SelfUpdater? = nil, log: Lines, timing: ClusterPairUpdateCycle.Timing = pairTiming,
               part published: ClusterPairUpdateCycle.Part? = nil) -> ClusterPairUpdateCycle {
        let partnerPath = partner.progressPath
        let part = published ?? (loop == nil ? .notRunning : .running(ProcessIdentity.current()!))
        var environment = ClusterPairUpdateCycle.Environment(
            updater: updater ?? fixture.updater(baseURL: baseURL), progressPath: progressPath,
            partner: { ClusterPairUpdate.readProgress(from: partnerPath).map { .reported($0) } ?? .unreachable },
            part: { part }, partStarting: { _ in false }, mailboxDirectory: mailboxDirectory,
            // A pair is loaded on both Macs: neither may go on alone.
            pairRunsHere: { true }, log: { log.append($0) })
        environment.timing = timing
        return ClusterPairUpdateCycle(environment: environment)
    }

    func cleanUp() async {
        if let task {
            task.cancel()
            _ = await ServeLoopFixture.finishes(task, within: .seconds(30))
        }
        await mock.shutdown()
        fixture.cleanup()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A rollback on one Mac of the pair, which the other Mac follows (`ClusterPairUpdateCycle.followRollback`).
private enum FollowTestError: Error { case notInstalled }

extension PairMac {
    var store: UpdateRecoveryStore { UpdateRecoveryStore(installRoot: fixture.installRoot, verifyCodeSignatures: false) }

    /// v2 installed by the updater and restarted into, as the pair's cycle leaves it: a pending candidate over v1.
    @discardableResult
    func installCandidate() async throws -> SelfUpdater {
        let updater = fixture.updater(baseURL: baseURL)
        guard case .updated(_, "2.0.0") = await updater.update() else { throw FollowTestError.notInstalled }
        try updater.prepareCandidateLaunch(operation: "cluster-restart", baseline: nil)
        return updater
    }

    /// The candidate passed its stabilization window.
    func promote() throws {
        var state = try store.loadState()
        state.promoteCandidate()
        try store.writeState(state)
    }

    /// This Mac's supervisor rolled v2 back (it failed its start check), restored v1 and quarantined v2, and, started
    /// again from v1, publishes its resting progress with the quarantine.
    func rollBackAfterFailedStartCheck() async throws {
        let updater = try await installCandidate()
        #expect(ClusterCandidateRecovery(updater: updater).recordFailedStartCheck(version: "2.0.0", reason: "`--version` exited 1",
                                                                                  now: 200) == .rolledBack(from: "2.0.0", to: "1.0.0"))
        ClusterPairUpdate.writeProgress(.init(phase: .idle, running: "1.0.0", writtenAt: Date().timeIntervalSince1970,
                                              quarantined: updater.quarantinedVersion()), to: progressPath)
    }
}

private final class Restarts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ mac: String, _ version: String) { lock.withLock { values.append("\(mac):\(version)") } }
    var all: [String] { lock.withLock { values.sorted() } }
}

@Suite("Cluster pair coordinated update", .serialized, .timeLimit(.minutes(3)))
struct ClusterPairUpdateTests {
    /// Rank 0 serves a request that outlives the stage: the pair stages while it serves, stops taking requests only
    /// then, lets the request finish (never cancelled), and only then both Macs install and restart.
    @Test func busyPairStagesThenDrainsWithoutCuttingThenUpdates() async throws {
        let rank0 = try await PairMac.make(), rank1 = try await PairMac.make()
        defer { Task { await rank0.cleanUp(); await rank1.cleanUp() } }
        let owner = try await rank0.servePair()
        try await rank0.push("in-flight")
        #expect(try await rank0.mock.waitForSnapshot(timeout: .seconds(10)) { $0.inferenceAccepted.contains { $0.requestId == "in-flight" } } != nil)

        let log0 = Lines(), log1 = Lines(), restarts = Restarts()
        let cycle0 = rank0.cycle(partner: rank1, log: log0), cycle1 = rank1.cycle(partner: rank0, log: log1)
        async let outcome0 = cycle0.run { restarts.record("rank0", $0) }
        async let outcome1 = cycle1.run { restarts.record("rank1", $0) }

        // Both Macs staged while the pair served; rank 0's part closed admission only after that.
        #expect(await poll(seconds: 30) { rank0.mailbox.readClusterUpdateDrainStatus()?.outcome == .draining })
        #expect(!stagingDirectories(rank0.fixture).isEmpty && !stagingDirectories(rank1.fixture).isEmpty)
        #expect(try rank0.fixture.liveBinaryContents() == "1.0.0-darkbloom" && rank1.fixture.liveBinaryContents() == "1.0.0-darkbloom")
        #expect(await poll(seconds: 10) { rank1.mailbox.readClusterUpdateDrainStatus()?.outcome == .notServing },
                "rank 1's part serves no request of its own")
        // The coordinator is told (heartbeat `draining`) and a request routed anyway is refused, not accepted.
        #expect(try await rank0.mock.waitForSnapshot(timeout: .seconds(10)) { $0.heartbeats.last?.status == .draining } != nil)
        try await rank0.push("after-drain-began")
        let refused = try await rank0.mock.waitForSnapshot(timeout: .seconds(10)) { $0.inferenceErrors.contains { $0.requestId == "after-drain-began" } }
        #expect(refused?.inferenceErrors.first { $0.requestId == "after-drain-began" }?.statusCode == 503)
        #expect(refused?.inferenceAccepted.contains { $0.requestId == "after-drain-began" } == false)
        // Nothing is installed while the accepted request runs.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(try rank0.fixture.liveBinaryContents() == "1.0.0-darkbloom" && restarts.all.isEmpty)

        owner.hold?.signal()
        let finished = try await rank0.mock.waitForSnapshot(timeout: .seconds(10)) { $0.inferenceComplete.contains { $0.requestId == "in-flight" } }
        #expect(finished?.inferenceErrors.contains { $0.requestId == "in-flight" } == false)
        #expect(owner.lastLease?.cancelCount == 0, "the accepted request was never cancelled")

        let (result0, result1) = await (outcome0, outcome1)
        #expect(result0 == .restarted(from: "1.0.0", to: "2.0.0", drained: true), "\(log0.all)")
        #expect(result1 == .restarted(from: "1.0.0", to: "2.0.0", drained: true), "\(log1.all)")
        #expect(restarts.all == ["rank0:2.0.0", "rank1:2.0.0"])
        #expect(try rank0.fixture.liveBinaryContents() == "2.0.0-darkbloom" && rank1.fixture.liveBinaryContents() == "2.0.0-darkbloom")
        for mac in [rank0, rank1] {
            let state = try UpdateRecoveryStore(installRoot: mac.fixture.installRoot, verifyCodeSignatures: false).loadState()
            #expect(state.candidate?.release.version == "2.0.0" && state.candidate?.launchIntent != nil, "the restart is a tracked candidate")
            #expect(ClusterPairUpdate.readProgress(from: mac.progressPath)?.phase == .restarting)
        }
        #expect(log0.all.contains { $0.contains("staged") } && log0.all.contains { $0.contains("installed v2.0.0") })
    }

    /// A request that outlives the drain bound: rank 0 takes requests again (nothing cancelled), both Macs keep their
    /// release, and the next slot updates the pair once the request is done.
    @Test func pairBusyPastTheDrainBoundDefersThenUpdatesAtTheNextSlot() async throws {
        let rank0 = try await PairMac.make(), rank1 = try await PairMac.make()
        defer { Task { await rank0.cleanUp(); await rank1.cleanUp() } }
        let owner = try await rank0.servePair()
        try await rank0.push("long")
        #expect(try await rank0.mock.waitForSnapshot(timeout: .seconds(10)) { $0.inferenceAccepted.contains { $0.requestId == "long" } } != nil)

        var short = pairTiming
        short.drainTimeout = 1
        let log0 = Lines(), log1 = Lines(), restarts = Restarts()
        async let first0 = rank0.cycle(partner: rank1, log: log0, timing: short).run { restarts.record("rank0", $0) }
        async let first1 = rank1.cycle(partner: rank0, log: log1, timing: short).run { restarts.record("rank1", $0) }
        let (deferred0, deferred1) = await (first0, first1)
        #expect(deferred0 == .drainTimedOut && deferred1 == .drainTimedOut, "\(log0.all) \(log1.all)")
        #expect(rank0.mailbox.readClusterUpdateDrainStatus()?.outcome == .timedOut)
        #expect(restarts.all.isEmpty)
        #expect(try rank0.fixture.liveBinaryContents() == "1.0.0-darkbloom" && rank1.fixture.liveBinaryContents() == "1.0.0-darkbloom")
        #expect(stagingDirectories(rank0.fixture).isEmpty && stagingDirectories(rank1.fixture).isEmpty, "nothing staged is kept")
        #expect(ClusterPairUpdate.readProgress(from: rank0.progressPath)?.phase == .deferred)
        #expect(ClusterPairUpdate.readProgress(from: rank1.progressPath)?.phase == .deferred)
        // Rank 0 takes requests again on the same connection; the long request was never cancelled.
        #expect(try await rank0.mock.waitForSnapshot(timeout: .seconds(10)) { $0.heartbeats.last?.status != .draining } != nil)
        #expect(owner.lastLease?.cancelCount == 0)
        owner.hold?.signal()
        #expect(try await rank0.mock.waitForSnapshot(timeout: .seconds(10)) { $0.inferenceComplete.contains { $0.requestId == "long" } } != nil)

        // The next slot: the same pair, idle now, updates.
        async let next0 = rank0.cycle(partner: rank1, log: log0).run { restarts.record("rank0", $0) }
        async let next1 = rank1.cycle(partner: rank0, log: log1).run { restarts.record("rank1", $0) }
        let (updated0, updated1) = await (next0, next1)
        #expect(updated0 == .restarted(from: "1.0.0", to: "2.0.0", drained: true), "\(log0.all)")
        #expect(updated1 == .restarted(from: "1.0.0", to: "2.0.0", drained: true), "\(log1.all)")
        #expect(try rank0.fixture.liveBinaryContents() == "2.0.0-darkbloom" && rank1.fixture.liveBinaryContents() == "2.0.0-darkbloom")
    }

    /// One Mac cannot verify the release: neither Mac stops taking requests or installs, and both retry at the next slot.
    @Test func oneMacFailingKeepsBothOnTheirReleaseAndTheNextSlotRetries() async throws {
        let healthy = try await PairMac.make(part: false)
        var broken = MockReleaseFixture()
        let failing = try await PairMac.make(part: false)
        broken = failing.fixture.mockReleaseFixture()
        broken.bundleHash = String(repeating: "0", count: 64)
        let badMock = MockCoordinator(release: broken, releaseArtifact: failing.fixture.artifact)
        let badURL = try await badMock.start()
        defer { Task { await healthy.cleanUp(); await failing.cleanUp(); await badMock.shutdown() } }

        let logA = Lines(), logB = Lines(), restarts = Restarts()
        async let a = healthy.cycle(partner: failing, log: logA).run { restarts.record("healthy", $0) }
        async let b = failing.cycle(partner: healthy, updater: failing.fixture.updater(baseURL: badURL), log: logB)
            .run { restarts.record("failing", $0) }
        let (outcomeA, outcomeB) = await (a, b)
        guard case .stageFailed(let reason) = outcomeB else { Issue.record("expected stageFailed, got \(outcomeB)"); return }
        #expect(reason.contains("hashMismatch"))
        #expect(outcomeA == .drainTimedOut, "the healthy Mac gives the release up too: \(logA.all)")
        #expect(logA.all.contains { $0.contains("the other Mac:") && $0.contains("failed") }, "\(logA.all)")
        #expect(restarts.all.isEmpty)
        #expect(try healthy.fixture.liveBinaryContents() == "1.0.0-darkbloom" && failing.fixture.liveBinaryContents() == "1.0.0-darkbloom")
        #expect(stagingDirectories(healthy.fixture).isEmpty && stagingDirectories(failing.fixture).isEmpty)
        #expect(ClusterPairUpdate.readProgress(from: failing.progressPath)?.phase == .failed)

        // The next slot, with the release verifiable again on both Macs.
        async let retryA = healthy.cycle(partner: failing, log: logA).run { restarts.record("healthy", $0) }
        async let retryB = failing.cycle(partner: healthy, log: logB).run { restarts.record("failing", $0) }
        let (doneA, doneB) = await (retryA, retryB)
        #expect(doneA == .restarted(from: "1.0.0", to: "2.0.0", drained: true), "\(logA.all)")
        #expect(doneB == .restarted(from: "1.0.0", to: "2.0.0", drained: true), "\(logB.all)")
        #expect(restarts.all == ["failing:2.0.0", "healthy:2.0.0"])
        #expect(try healthy.fixture.liveBinaryContents() == "2.0.0-darkbloom" && failing.fixture.liveBinaryContents() == "2.0.0-darkbloom")
    }

    /// The other Mac has automatic updates off: the slot downloads nothing. `darkbloom update` run on both Macs updates
    /// the pair: the Mac asked first waits, while serving, for the other Mac's.
    @Test func partnerWithAutomaticUpdatesOffUpdatesWhenAskedOnBothMacs() async throws {
        let first = try await PairMac.make(part: false), second = try await PairMac.make(part: false)
        defer { Task { await first.cleanUp(); await second.cleanUp() } }
        ClusterPairUpdate.writeProgress(.init(phase: .disabled, running: "1.0.0", writtenAt: Date().timeIntervalSince1970),
                                        to: second.progressPath)
        let log1 = Lines(), log2 = Lines(), restarts = Restarts()
        let slot = await first.cycle(partner: second, log: log1).run { restarts.record("first", $0) }
        #expect(slot == .stageFailed("automatic updates are off on the other Mac"), "given up before the download: \(log1.all)")
        #expect(stagingDirectories(first.fixture).isEmpty && restarts.all.isEmpty)

        async let asked1 = first.cycle(partner: second, log: log1).run(request: "update-1") { restarts.record("first", $0) }
        #expect(await poll(seconds: 10) { ClusterPairUpdate.readProgress(from: first.progressPath)?.phase == .staged })
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(ClusterPairUpdate.readProgress(from: first.progressPath)?.phase == .staged, "still waiting for the other Mac")
        async let asked2 = second.cycle(partner: first, log: log2).run(request: "update-2") { restarts.record("second", $0) }
        let (done1, done2) = await (asked1, asked2)
        #expect(done1 == .restarted(from: "1.0.0", to: "2.0.0", drained: true), "\(log1.all)")
        #expect(done2 == .restarted(from: "1.0.0", to: "2.0.0", drained: true), "\(log2.all)")
        #expect(restarts.all == ["first:2.0.0", "second:2.0.0"])
        #expect(try first.fixture.liveBinaryContents() == "2.0.0-darkbloom" && second.fixture.liveBinaryContents() == "2.0.0-darkbloom")
    }

    /// A part that serves without answering the drain (the leader's local API, a solo server): the slot downloads
    /// nothing and the part keeps serving; the next slot tries again.
    @Test func partThatCannotDrainDownloadsNothing() async throws {
        let mac = try await PairMac.make(part: false), other = try await PairMac.make(part: false)
        defer { Task { await mac.cleanUp(); await other.cleanUp() } }
        let log = Lines(), restarts = Restarts()
        let outcome = await mac.cycle(partner: other, log: log, part: .undrainable).run { restarts.record("mac", $0) }
        #expect(outcome == .stageFailed(ClusterPairUpdateCycle.undrainable), "given up before the download: \(log.all)")
        #expect(stagingDirectories(mac.fixture).isEmpty && restarts.all.isEmpty)
        #expect(try mac.fixture.liveBinaryContents() == "1.0.0-darkbloom")
        #expect(ClusterPairUpdate.readProgress(from: mac.progressPath)?.phase == .failed, "the other Mac gives the release up too")
    }

    /// The other Mac cannot be asked: this Mac goes on alone only while no pair runs on it, and it asks again before it
    /// installs, so a pair that formed on it meanwhile keeps it waiting and the cycle defers.
    @Test func macWhosePartnerCannotBeAskedGoesOnAloneOnlyWithoutAPair() async throws {
        let mac = try await PairMac.make(part: false)
        defer { Task { await mac.cleanUp() } }
        var timing = pairTiming
        timing.partnerDrainWait = 2
        func cycle(pairRunsHere: @escaping @Sendable () -> Bool, log: Lines) -> ClusterPairUpdateCycle {
            var environment = ClusterPairUpdateCycle.Environment(updater: mac.fixture.updater(baseURL: mac.baseURL),
                progressPath: mac.progressPath, partner: { .unreachable }, part: { .notRunning }, partStarting: { _ in false },
                mailboxDirectory: mac.mailboxDirectory, pairRunsHere: pairRunsHere, log: { log.append($0) })
            environment.timing = timing
            return ClusterPairUpdateCycle(environment: environment)
        }
        let asked = Lines(), log = Lines(), restarts = Restarts()
        let formed = await cycle(pairRunsHere: { asked.append("asked"); return asked.all.count > 1 }, log: log)
            .run { restarts.record("mac", $0) }
        #expect(formed == .drainTimedOut, "a pair formed after the stage wait: \(log.all)")
        #expect(restarts.all.isEmpty)
        #expect(try mac.fixture.liveBinaryContents() == "1.0.0-darkbloom")

        let alone = await cycle(pairRunsHere: { false }, log: log).run { restarts.record("mac", $0) }
        #expect(alone == .restarted(from: "1.0.0", to: "2.0.0", drained: true), "no pair here: \(log.all)")
        #expect(restarts.all == ["mac:2.0.0"])
    }

    /// The part's side of the drain: release after a drain reopens admission on the same connection, and only the
    /// coordinator-paired part answers at all.
    @Test func drainedPartTakesRequestsAgainWhenReleased() async throws {
        let rank0 = try await PairMac.make()
        defer { Task { await rank0.cleanUp() } }
        _ = try await rank0.servePair()
        let identity = try #require(ProcessIdentity.current())
        let drain = ClusterUpdateDrainRequest(action: .drain, target: identity, timeoutSeconds: 10)
        try rank0.mailbox.writeClusterUpdateDrainRequest(drain)
        #expect(await poll(seconds: 10) { rank0.mailbox.readClusterUpdateDrainStatus() == .init(requestID: drain.id, outcome: .drained, remaining: 0) })
        #expect(try await rank0.mock.waitForSnapshot(timeout: .seconds(10)) { $0.heartbeats.last?.status == .draining } != nil)
        #expect(await rank0.loop?.state.refusingNewWork == true)
        let release = ClusterUpdateDrainRequest(action: .release, target: identity, timeoutSeconds: 0)
        try rank0.mailbox.writeClusterUpdateDrainRequest(release)
        #expect(await poll(seconds: 10) { rank0.mailbox.readClusterUpdateDrainStatus()?.outcome == .released })
        #expect(try await rank0.mock.waitForSnapshot(timeout: .seconds(10)) { $0.heartbeats.last?.status == .idle } != nil)
        #expect(await rank0.loop?.state.refusingNewWork == false)
        #expect(await rank0.loop?.updatePhase == .idle)
        #expect(rank0.mock.snapshot().drainBarriers.isEmpty, "an undone drain never fences the connection")
    }

    /// A release the pair installed is a candidate: promoted once its service stays healthy, rolled back to the
    /// verified predecessor (and quarantined) after three failed starts, as the watchdog does for a single Mac.
    @Test func candidateIsPromotedOrRolledBackLikeTheWatchdogs() async throws {
        let mac = try await PairMac.make(part: false)
        defer { Task { await mac.cleanUp() } }
        let updater = mac.fixture.updater(baseURL: mac.baseURL)
        guard case .updated(_, let installed) = await updater.update() else { Issue.record("install failed"); return }
        #expect(installed == "2.0.0")
        let recovery = ClusterCandidateRecovery(updater: updater, stabilizationSeconds: 10)
        #expect(recovery.noteLaunch(now: 1_000) == .candidate(version: "2.0.0", failedStarts: 0))
        #expect(recovery.observe(healthy: true, processStartedAt: 999, now: 1_001) == .stabilizing)
        let held = try updater.beginUpdateSession(operation: "pair-cycle")
        #expect(recovery.observe(healthy: true, processStartedAt: 999, now: 1_002) == .stabilizing, "another update's lease keeps the candidate")
        held.release()
        #expect(recovery.observe(healthy: false, processStartedAt: 999, now: 1_005) == .stabilizing, "a missed heartbeat restarts the window")
        #expect(recovery.observe(healthy: true, processStartedAt: 999, now: 1_006) == .stabilizing)
        #expect(recovery.observe(healthy: true, processStartedAt: 999, now: 1_016) == .promoted(version: "2.0.0"))
        #expect(recovery.noteLaunch(now: 1_020) == .notCandidate, "a promoted release is no candidate")
        #expect(try UpdateRecoveryStore(installRoot: mac.fixture.installRoot, verifyCodeSignatures: false).loadState().current?.version == "2.0.0")

        let other = try await PairMac.make(part: false)
        defer { Task { await other.cleanUp() } }
        let otherUpdater = other.fixture.updater(baseURL: other.baseURL)
        guard case .updated = await otherUpdater.update() else { Issue.record("install failed"); return }
        let failing = ClusterCandidateRecovery(updater: otherUpdater)
        for start in 1...2 {
            #expect(failing.noteLaunch(now: Double(start * 100)) == .candidate(version: "2.0.0", failedStarts: start - 1))
            #expect(failing.recordFailedStart(now: Double(start * 100 + 5)) == .counted(version: "2.0.0", failures: start))
        }
        #expect(failing.noteLaunch(now: 300) == .candidate(version: "2.0.0", failedStarts: 2))
        #expect(failing.recordFailedStart(now: 305) == .rolledBack(from: "2.0.0", to: "1.0.0"))
        #expect(try other.fixture.liveBinaryContents() == "1.0.0-darkbloom")
        let state = try UpdateRecoveryStore(installRoot: other.fixture.installRoot, verifyCodeSignatures: false).loadState()
        #expect(state.quarantine?.version == "2.0.0" && state.candidate == nil)
        guard case .quarantined(let version, _) = await otherUpdater.checkForUpdate() else { Issue.record("not quarantined"); return }
        #expect(version == "2.0.0", "the next slot does not install the failed release again")
        #expect(failing.recordFailedStart(now: 400) == .notCandidate, "an ordinary end after the rollback counts nothing")
    }

    /// Before the supervisor restarts into an installed binary, it runs it once with `--version`: the check passes only
    /// on exit 0 within the bound with exactly the expected version, and repeats nothing but a version from its output.
    @Test func startCheckPassesOnlyABinaryThatReportsItsVersionInTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("start-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func check(_ body: String) throws -> String? {
            let binary = directory.appendingPathComponent(UUID().uuidString)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            return ClusterCandidateRecovery.startCheckFailure(executable: binary.path, version: "2.0.0", timeout: 1)
        }
        #expect(try check(#"[ "$1" = --version ] && echo 2.0.0"#) == nil)
        #expect(try check("exit 1") == "`--version` exited 1")
        #expect(try check("kill -KILL $$") == "`--version` ended on signal 9")
        #expect(try check("exec sleep 30") == "`--version` did not finish within 1 s")
        #expect(try check("echo 1.9.9") == "it reports v1.9.9")
        #expect(try check("echo 'token=not-a-version'") == "it printed no version", "nothing else the binary prints is repeated")
        let missing = directory.appendingPathComponent("missing").path
        #expect(ClusterCandidateRecovery.startCheckFailure(executable: missing, version: "2.0.0", timeout: 1)?
            .hasPrefix("it could not be run") == true)
    }

    /// A candidate whose binary failed its start check before the restart: after that restart no supervisor would count
    /// its failed starts, so the predecessor is restored and the release quarantined at once. Only the pending release
    /// is, and only under the update lease.
    @Test func candidateThatFailsItsStartCheckIsRolledBackAtOnce() async throws {
        let mac = try await PairMac.make(part: false)
        defer { Task { await mac.cleanUp() } }
        let updater = mac.fixture.updater(baseURL: mac.baseURL)
        guard case .updated = await updater.update() else { Issue.record("install failed"); return }
        try updater.prepareCandidateLaunch(operation: "cluster-restart", baseline: nil)
        let recovery = ClusterCandidateRecovery(updater: updater)
        #expect(recovery.recordFailedStartCheck(version: "1.9.9", reason: "it reports v1.9.9", now: 200) == .notCandidate,
                "not the pending release")
        let held = try updater.beginUpdateSession(operation: "pair-cycle")
        #expect(recovery.recordFailedStartCheck(version: "2.0.0", reason: "`--version` exited 1", now: 201) == .notCandidate,
                "another update holds the lease")
        held.release()
        #expect(try mac.fixture.liveBinaryContents() == "2.0.0-darkbloom")
        #expect(recovery.recordFailedStartCheck(version: "2.0.0", reason: "`--version` exited 1", now: 202)
                == .rolledBack(from: "2.0.0", to: "1.0.0"))
        #expect(try mac.fixture.liveBinaryContents() == "1.0.0-darkbloom")
        let state = try UpdateRecoveryStore(installRoot: mac.fixture.installRoot, verifyCodeSignatures: false).loadState()
        #expect(state.candidate == nil && state.current?.version == "1.0.0")
        #expect(state.quarantine?.version == "2.0.0" && state.quarantine?.failureCount == 1, "one failed start")
        #expect(state.quarantine?.reason.contains("failed its start check before the restart (`--version` exited 1)") == true)
        guard case .quarantined(let version, _) = await updater.checkForUpdate() else { Issue.record("not quarantined"); return }
        #expect(version == "2.0.0", "the next slot does not install it again")
    }

    // MARK: - The peer follows a rollback (owner ruling 2026-11-03)

    /// The other Mac promoted v2 before this one rolled it back: it drains its part, restores v1 under the update lease,
    /// quarantines v2 and restarts into v1, so the pair serves v1 together.
    @Test func peerThatPromotedTheReleaseFollowsTheRollback() async throws {
        let rolledBack = try await PairMac.make(part: false), peer = try await PairMac.make()
        defer { Task { await rolledBack.cleanUp(); await peer.cleanUp() } }
        try await peer.installCandidate()
        try peer.promote()
        try await rolledBack.rollBackAfterFailedStartCheck()

        let log = Lines(), restarts = Restarts()
        let outcome = await peer.cycle(partner: rolledBack, log: log).followRollback { restarts.record("peer", $0) }

        #expect(outcome == .followed(.restarted(from: "2.0.0", to: "1.0.0", drained: true)), "\(log.all)")
        #expect(restarts.all == ["peer:1.0.0"])
        #expect(peer.mailbox.readClusterUpdateDrainStatus()?.outcome == .notServing, "its part was asked to drain first")
        #expect(try peer.fixture.liveBinaryContents() == "1.0.0-darkbloom")
        let state = try peer.store.loadState()
        #expect(state.current?.version == "1.0.0" && state.candidate == nil)
        #expect(state.quarantine?.version == "2.0.0")
        #expect(state.quarantine?.reason.contains("the other Mac of the pair rolled v2.0.0 back to v1.0.0") == true)
        let progress = ClusterPairUpdate.readProgress(from: peer.progressPath)
        #expect(progress?.phase == .restarting && progress?.target == "1.0.0" && progress?.quarantined == "2.0.0")
        #expect(log.all.contains { $0.contains("this Mac follows to v1.0.0") })
        try peer.fixture.updater(baseURL: peer.baseURL).beginUpdateSession(operation: "lease-check").release()
    }

    /// The other Mac is still mid-update: its cycle holds the update lease, so the follow waits for the next check and
    /// changes nothing; then its unpromoted candidate is rolled back the same way.
    @Test func peerStillMidUpdateFollowsOnceItsCycleLetsTheLeaseGo() async throws {
        let rolledBack = try await PairMac.make(part: false), peer = try await PairMac.make(part: false)
        defer { Task { await rolledBack.cleanUp(); await peer.cleanUp() } }
        let updater = try await peer.installCandidate()
        try await rolledBack.rollBackAfterFailedStartCheck()

        let log = Lines(), restarts = Restarts()
        let cycle = try updater.beginUpdateSession(operation: "cluster-auto-update")
        let refused = await peer.cycle(partner: rolledBack, log: log).followRollback { restarts.record("peer", $0) }
        #expect(refused == .busy)
        #expect(try peer.fixture.liveBinaryContents() == "2.0.0-darkbloom")
        #expect(try peer.store.loadState().candidate?.release.version == "2.0.0")
        #expect(ClusterPairUpdate.readProgress(from: peer.progressPath) == nil, "nothing was published")
        cycle.release()

        let outcome = await peer.cycle(partner: rolledBack, log: log).followRollback { restarts.record("peer", $0) }
        #expect(outcome == .followed(.restarted(from: "2.0.0", to: "1.0.0", drained: true)), "\(log.all)")
        #expect(restarts.all == ["peer:1.0.0"])
        #expect(try peer.fixture.liveBinaryContents() == "1.0.0-darkbloom")
        let state = try peer.store.loadState()
        #expect(state.candidate == nil && state.current?.version == "1.0.0" && state.quarantine?.version == "2.0.0")
    }

    /// The other Mac stops answering once the follow began: it waits at most the bound, then defers with a clear reason,
    /// changes nothing and frees the lease. One that cannot be asked at all is not followed.
    @Test func unreachablePeerIsWaitedForThenTheFollowDefers() async throws {
        let rolledBack = try await PairMac.make(part: false), peer = try await PairMac.make(part: false)
        defer { Task { await rolledBack.cleanUp(); await peer.cleanUp() } }
        try await peer.installCandidate()
        try peer.promote()
        try await rolledBack.rollBackAfterFailedStartCheck()
        var timing = pairTiming
        timing.partnerStageWait = 1
        func cycle(partner: @escaping @Sendable () -> ClusterPairUpdate.Partner, log: Lines) -> ClusterPairUpdateCycle {
            var environment = ClusterPairUpdateCycle.Environment(updater: peer.fixture.updater(baseURL: peer.baseURL),
                progressPath: peer.progressPath, partner: partner, part: { .notRunning }, partStarting: { _ in false },
                mailboxDirectory: peer.mailboxDirectory, pairRunsHere: { true }, log: { log.append($0) })
            environment.timing = timing
            return ClusterPairUpdateCycle(environment: environment)
        }
        let log = Lines(), restarts = Restarts()
        let unasked = await cycle(partner: { .unreachable }, log: log).followRollback { restarts.record("peer", $0) }
        #expect(unasked == .nothingToFollow)
        #expect(ClusterPairUpdate.readProgress(from: peer.progressPath) == nil)

        let asked = Lines()
        let reported = try #require(ClusterPairUpdate.readProgress(from: rolledBack.progressPath))
        let started = Date()
        let outcome = await cycle(partner: {
            asked.append("asked")
            return asked.all.count == 1 ? .reported(reported) : .unreachable
        }, log: log).followRollback { restarts.record("peer", $0) }

        #expect(outcome == .followed(.drainTimedOut), "\(log.all)")
        #expect(Date().timeIntervalSince(started) < 15, "the wait is bounded")
        #expect(restarts.all.isEmpty)
        #expect(try peer.fixture.liveBinaryContents() == "2.0.0-darkbloom")
        #expect(try peer.store.loadState().quarantine == nil)
        let progress = ClusterPairUpdate.readProgress(from: peer.progressPath)
        #expect(progress?.phase == .deferred)
        #expect(progress?.detail == "the other Mac did not confirm it runs v1.0.0 within 1 s")
        try peer.fixture.updater(baseURL: peer.baseURL).beginUpdateSession(operation: "lease-check").release()
    }

    /// The other Mac already runs a newer release (it updated alone: its single-Mac updater, `darkbloom update` there,
    /// or this Mac was asleep at the slot). The follow check says so, and the cycle the supervisor then runs at once
    /// finds the other Mac ready and updates this Mac. The same or an older release on the other Mac is nothing to follow.
    @Test func partnerOnANewerReleaseIsFollowedForwardAtOnce() async throws {
        let behind = try await PairMac.make(part: false), ahead = try await PairMac.make(part: false)
        defer { Task { await behind.cleanUp(); await ahead.cleanUp() } }
        try await ahead.installCandidate()
        try ahead.promote()
        func publish(_ running: String) {
            ClusterPairUpdate.writeProgress(.init(phase: .idle, running: running, writtenAt: Date().timeIntervalSince1970),
                                            to: ahead.progressPath)
        }
        let log = Lines(), restarts = Restarts()
        for running in ["1.0.0", "0.9.0"] {
            publish(running)
            let outcome = await behind.cycle(partner: ahead, log: log).followRollback { restarts.record("behind", $0) }
            #expect(outcome == .nothingToFollow, "the other Mac on v\(running)")
        }
        // The other Mac is updating to a newer release (a single-Mac updater there asked its pair to follow): followed
        // while its progress is fresh, not once it went stale.
        let now = Date().timeIntervalSince1970
        ClusterPairUpdate.writeProgress(.init(phase: .staged, target: "2.0.0", running: "1.0.0", writtenAt: now), to: ahead.progressPath)
        #expect(await behind.cycle(partner: ahead, log: log).followRollback { restarts.record("behind", $0) } == .otherMacNewer("2.0.0"))
        ClusterPairUpdate.writeProgress(.init(phase: .staged, target: "2.0.0", running: "1.0.0",
                                              writtenAt: now - ClusterPairUpdate.progressStaleSeconds - 5), to: ahead.progressPath)
        #expect(await behind.cycle(partner: ahead, log: log).followRollback { restarts.record("behind", $0) } == .nothingToFollow)
        publish("2.0.0")
        let outcome = await behind.cycle(partner: ahead, log: log).followRollback { restarts.record("behind", $0) }
        #expect(outcome == .otherMacNewer("2.0.0"))
        #expect(restarts.all.isEmpty, "the follow check itself installs nothing")

        let cycle = await behind.cycle(partner: ahead, log: log).run { restarts.record("behind", $0) }
        #expect(cycle == .restarted(from: "1.0.0", to: "2.0.0", drained: true), "\(log.all)")
        #expect(restarts.all == ["behind:2.0.0"])
    }

    /// Both Macs keep v2 quarantined: neither's next check installs it again, each one's progress says so, and the Mac
    /// that rolled back first finds nothing to follow in its peer's rollback (no loop). A peer that keeps another
    /// release for rollback cannot follow and changes nothing.
    @Test func quarantineAppliesOnBothMacs() async throws {
        let rolledBack = try await PairMac.make(part: false), peer = try await PairMac.make(part: false)
        defer { Task { await rolledBack.cleanUp(); await peer.cleanUp() } }
        try await peer.installCandidate()
        try peer.promote()
        try await rolledBack.rollBackAfterFailedStartCheck()
        let log = Lines(), restarts = Restarts()
        let followed = await peer.cycle(partner: rolledBack, log: log).followRollback { restarts.record("peer", $0) }
        #expect(followed == .followed(.restarted(from: "2.0.0", to: "1.0.0", drained: true)), "\(log.all)")

        for mac in [rolledBack, peer] {
            let updater = mac.fixture.updater(baseURL: mac.baseURL)
            #expect(updater.quarantinedVersion() == "2.0.0")
            guard case .quarantined(let version, _) = await updater.checkForUpdate() else {
                Issue.record("v2.0.0 is not quarantined on \(mac.directory.lastPathComponent)"); continue
            }
            #expect(version == "2.0.0")
        }
        let first = await rolledBack.cycle(partner: peer, log: log).followRollback { restarts.record("rolledBack", $0) }
        #expect(first == .nothingToFollow, "the Mac that rolled back first does not follow its peer back")
        #expect(restarts.all == ["peer:1.0.0"])

        // A Mac that installed the quarantined release again (`--override-quarantine`) rolled nothing back.
        ClusterPairUpdate.writeProgress(.init(phase: .idle, running: "2.0.0", writtenAt: Date().timeIntervalSince1970,
                                              quarantined: "2.0.0"), to: rolledBack.progressPath)
        let reinstalled = try await PairMac.make(part: false)
        defer { Task { await reinstalled.cleanUp() } }
        try await reinstalled.installCandidate()
        try reinstalled.promote()
        let overridden = await reinstalled.cycle(partner: rolledBack, log: log).followRollback { restarts.record("reinstalled", $0) }
        #expect(overridden == .nothingToFollow)
        #expect(try reinstalled.fixture.liveBinaryContents() == "2.0.0-darkbloom")

        // A rollback to a release this Mac does not keep is not followed.
        let other = try await PairMac.make(part: false)
        defer { Task { await other.cleanUp() } }
        try await other.installCandidate()
        try other.promote()
        ClusterPairUpdate.writeProgress(.init(phase: .idle, running: "0.9.0", writtenAt: Date().timeIntervalSince1970,
                                              quarantined: "2.0.0"), to: rolledBack.progressPath)
        guard case .cannotFollow(let reason) = await other.cycle(partner: rolledBack, log: log).followRollback(restart: { _ in }) else {
            Issue.record("followed a rollback to a release it does not keep"); return
        }
        #expect(reason.contains("keeps v1.0.0 for rollback"))
        #expect(try other.fixture.liveBinaryContents() == "2.0.0-darkbloom")
        #expect(try other.store.loadState().quarantine == nil)
    }

    /// What decides the follow before the lease: the Mac that rolled back says the other Mac still runs the release; a
    /// Mac whose part cannot drain does not follow yet; a Mac on another release finds nothing to follow without the
    /// lease, even while another update holds it.
    @Test func followIsDecidedBeforeTheLease() async throws {
        let rolledBack = try await PairMac.make(part: false), peer = try await PairMac.make(part: false)
        defer { Task { await rolledBack.cleanUp(); await peer.cleanUp() } }
        try await peer.installCandidate()
        try peer.promote()
        try await rolledBack.rollBackAfterFailedStartCheck()
        let log = Lines(), now = Date().timeIntervalSince1970

        ClusterPairUpdate.writeProgress(.init(phase: .idle, running: "2.0.0", writtenAt: now), to: peer.progressPath)
        guard case .otherMacStillRuns(let line) = await rolledBack.cycle(partner: peer, log: log).followRollback(restart: { _ in }) else {
            Issue.record("the Mac that rolled back did not say the other Mac still runs v2.0.0"); return
        }
        #expect(line.contains("the other Mac still runs v2.0.0"))

        guard case .cannotFollow(let reason) = await peer.cycle(partner: rolledBack, log: log, part: .undrainable)
            .followRollback(restart: { _ in }) else { Issue.record("a part that cannot drain followed"); return }
        #expect(reason.contains("it follows once its part can drain"))
        #expect(try peer.fixture.liveBinaryContents() == "2.0.0-darkbloom" && peer.store.loadState().quarantine == nil)
        #expect(ClusterPairUpdate.readProgress(from: peer.progressPath)?.phase == .idle, "nothing was published")

        let held = try rolledBack.fixture.updater(baseURL: rolledBack.baseURL).beginUpdateSession(operation: "cluster-auto-update")
        defer { held.release() }
        ClusterPairUpdate.writeProgress(.init(phase: .idle, running: "1.0.0", writtenAt: now, quarantined: "2.0.0"),
                                        to: peer.progressPath)
        let other = await rolledBack.cycle(partner: peer, log: log).followRollback { _ in }
        #expect(other == .nothingToFollow, "not .busy: the lease is not asked for")

        // A Mac that runs the quarantined release but keeps another one cannot follow, decided without the lease.
        let peerLease = try peer.fixture.updater(baseURL: peer.baseURL).beginUpdateSession(operation: "cluster-auto-update")
        defer { peerLease.release() }
        ClusterPairUpdate.writeProgress(.init(phase: .idle, running: "0.9.0", writtenAt: now, quarantined: "2.0.0"),
                                        to: rolledBack.progressPath)
        guard case .cannotFollow(let keeps) = await peer.cycle(partner: rolledBack, log: log).followRollback(restart: { _ in }) else {
            Issue.record("a Mac keeping another release asked for the lease"); return
        }
        #expect(keeps.contains("keeps v1.0.0 for rollback"))
    }
}
