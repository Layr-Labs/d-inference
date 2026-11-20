import DarkbloomClusterRemote
import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// The leading Mac's cluster service while the other Mac doesn't answer (asleep, off, or its cable out). Inside the
/// absence grace the leader keeps its part wanted, so the pair re-forms when the other Mac is back; a part that can't form
/// the pair ends, and the service starts it again. A MiMo leader whose follower slept started it every 48 s, each start
/// reading its share of the model again and registering again with the coordinator (2026-11-09). The part here is
/// `/usr/bin/true`, which ends at once; nothing loads a model and no other Mac answers. Also the wait of a part whose
/// share a Mac's load gate refused.
@Suite("Cluster service: a part whose other Mac is away, or whose share was refused for memory", .serialized)
struct ClusterServicePartRestartTests {
    /// The waits between the starts of a part that keeps ending: while the other Mac answers, 6, 12 and 24 s, then 30 s
    /// (3 s after a run of 2 minutes); while it doesn't, 30 s, then twice as long each time up to 10 min, whatever the
    /// run's length.
    @Test func aPartsRestartWaitGrowsTo10MinutesOnlyWhileTheOtherMacIsAway() {
        func waits(away: Bool, ran: Double = 1) -> [Double] {
            var backoff = ClusterControlPartChoice.firstBackoffSeconds
            return (0..<8).map { _ in
                backoff = ClusterControlPartChoice.restartBackoff(after: backoff, ranSeconds: ran, otherMacAway: away)
                return backoff
            }
        }
        #expect(waits(away: false) == [6, 12, 24, 30, 30, 30, 30, 30])
        #expect(waits(away: false, ran: 120) == [3, 3, 3, 3, 3, 3, 3, 3])
        #expect(waits(away: true) == [30, 60, 120, 240, 480, 600, 600, 600])
        #expect(waits(away: true, ran: 120) == [30, 60, 120, 240, 480, 600, 600, 600])
        // A part already backing off when the other Mac goes away doubles from where it was.
        #expect(ClusterControlPartChoice.restartBackoff(after: 24, ranSeconds: 1, otherMacAway: true) == 48)
    }

    /// The leading Mac's part ended because a Mac's load gate refused its share (a DevNet pair, 2026-11-15: the
    /// MacBook's share of Gemma 4 26B refused on 3.09 GiB free, the part started again every 30 s and read the share each
    /// time): it waits twice as long each time, up to 5 min, whatever the run's length. The other Mac away still decides
    /// the wait when both hold.
    @Test func aPartRefusedForMemoryWaitsTwiceAsLongEachTimeUpTo5Minutes() {
        func waits(ran: Double) -> [Double] {
            var backoff = ClusterControlPartChoice.firstBackoffSeconds
            return (0..<9).map { _ in
                backoff = ClusterControlPartChoice.restartBackoff(after: backoff, ranSeconds: ran, otherMacAway: false, memoryRefused: true)
                return backoff
            }
        }
        #expect(waits(ran: 35) == [6, 12, 24, 48, 96, 192, 300, 300, 300])
        #expect(waits(ran: 600) == [6, 12, 24, 48, 96, 192, 300, 300, 300])
        // From the ordinary cap it keeps doubling; the other Mac away goes first.
        #expect(ClusterControlPartChoice.restartBackoff(after: 30, ranSeconds: 35, otherMacAway: false, memoryRefused: true) == 60)
        #expect(ClusterControlPartChoice.restartBackoff(after: 3, ranSeconds: 35, otherMacAway: true, memoryRefused: true) == 30)
    }

    /// `DARKBLOOM_CLUSTER_MEMORY_REFUSAL_REPLAN` reaches the cluster service through its login agent (exported before
    /// `darkbloom start` or `darkbloom cluster`), and only an off word turns it off.
    @Test func theMemoryRefusalSwitchReachesTheClusterService() {
        let key = ClusterMemoryRefusalReplan.environmentKey
        #expect(key == "DARKBLOOM_CLUSTER_MEMORY_REFUSAL_REPLAN")
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        for word in ["0", "off", "FALSE", " no ", "disabled", "none"] { #expect(!ClusterMemoryRefusalReplan.isEnabled(word), "\(word)") }
        for word in [nil, "", "1", "on", "true"] { #expect(ClusterMemoryRefusalReplan.isEnabled(word), "\(String(describing: word))") }
    }

    /// The service itself: the leading Mac's part ends at once after each start, and the load gate's refusal of a share
    /// is recorded meanwhile, as the part records it. From a wait of 24 s it waits 48 s, not the 30 s cap of a part
    /// that ends for another reason, and says why.
    @Test func aLeadersPartRefusedForMemoryWaitsLongerThanTheOrdinaryCap() throws {
        try withLeader(otherMacAway: false, soloGrace: 3_600, refusesForMemory: true) { leader in
            // The other Mac confirmed this Mac's claim just now (its time-to-live an hour): the pair runs here.
            leader.service.lock.withLock {
                _ = leader.service.control?.receiveAnswer(from: leader.other.memberID, sent: leader.claim,
                                                          answer: .accepted(leader.other), now: ClusterService.monotonicSeconds())
            }
            guard case .cluster = leader.mode else {
                Issue.record("the leader's pair is not up: \(leader.mode)")
                return
            }
            // The memory re-plan comes due only after two refusals; this one stands in, so nothing is planned. The
            // switch is set on, whatever this test process's environment says.
            leader.service.memoryReplan = .init(reachMembers: { .failure(.init("fixture: not re-planned")) },
                planModels: { .success([]) }, adopt: { _ in .success([]) }, serve: { .success([]) }, restoreStart: {})
            leader.service.memoryRefusalReplan = true
            leader.service.lock.withLock { leader.service.backoff = 24 }
            leader.run()
            let child = try leader.endedPart()
            #expect((40...48).contains(child.restartInSeconds ?? 0),
                    "it waits 48 s, not the 30 s cap: \(String(describing: child.restartInSeconds)) \(leader.lines.values)")
            #expect(child.restartWaitsForOtherMac == nil, "the other Mac answers")
            let saidBy = Date().addingTimeInterval(2)
            func said() -> Bool { leader.lines.values.contains { $0.contains("a Mac's memory refused its share: starting it again in 48 s") } }
            while !said(), Date() < saidBy { usleep(20_000) }
            #expect(said(), "\(leader.lines.values)")
        }
    }

    /// Only the leader's modes with a member of the plan absent count as the other Mac away.
    @Test func theOtherMacIsAwayInTheLeadersModesWithAnAbsentMember() {
        let away: [ClusterControlNode.Mode] = [.waiting(missing: ["b"], soloInSeconds: 60, canServeAlone: false),
                                               .alone(missing: ["b"]), .cannotServe(missing: ["b"], reason: "fixture")]
        let present: [ClusterControlNode.Mode] = [.cluster, .confirming, .idle, .following(leaderID: "a")]
        #expect(away.allSatisfy(\.othersAway) && !present.contains(where: \.othersAway))
    }

    /// `darkbloom cluster status` on the leading Mac, under the line that it waits for the other Mac: when its part starts
    /// again, and that the other Mac's answer starts it at once. Nothing while the wait is the ordinary one.
    @Test func theLeadersStatusSaysWhenItsPartStartsAgain() {
        var child = ClusterServiceStatus.Child(running: false, starts: 3, lastEnd: "exit 1", restartInSeconds: 240,
                                               restartWaitsForOtherMac: true, lastError: nil)
        #expect(OnboardingLive.partWaitLine(child, here: "This Mac", there: "the other Mac")
            == "This Mac's part starts again in 4 min, or as soon as the other Mac answers: while the other Mac is away, each "
            + "start waits twice as long as the last, up to 10 min.")
        child.restartWaitsForOtherMac = nil
        #expect(OnboardingLive.partWaitLine(child, here: "This Mac", there: "the other Mac") == nil)
    }

    @Test func aLeaderWhoseOtherMacIsAwayWaitsLongerToStartItsPartAgainAndStartsItAtOnceWhenItAnswers() throws {
        // This Mac would serve alone (it can't here) only after an hour: it waits for the other Mac, its part wanted.
        try withLeaderWhoseOtherMacIsAway(soloGrace: 3_600) { leader in
            guard case .waiting = leader.mode else {
                Issue.record("the leader is not waiting for the other Mac: \(leader.mode)")
                return
            }
            leader.run()
            // The part starts, ends at once, and waits to start again.
            let child = try leader.endedPart()
            #expect((child.restartInSeconds ?? 0) >= 29,
                    "it waits 30 s, not the 6 s of a part whose other Mac answers: \(String(describing: child.restartInSeconds))")
            #expect(child.restartWaitsForOtherMac == true, "the status says the other Mac's answer ends the wait")
            #expect(leader.starts.values.count == 1, "\(leader.lines.values)")

            // The other Mac answers: the part starts again at once.
            let answered = Date().timeIntervalSince1970
            leader.service.lock.withLock {
                _ = leader.service.control?.receiveAnswer(from: leader.other.memberID, sent: leader.claim,
                                                          answer: .accepted(leader.other), now: ClusterService.monotonicSeconds())
            }
            let until = Date().addingTimeInterval(5)
            while leader.starts.values.count < 2, Date() < until { usleep(20_000) }
            let again = try #require(leader.starts.values.dropFirst().first, "the part did not start again: \(leader.lines.values)")
            #expect(again - answered < 3, "it started \(again - answered) s after the other Mac answered")
        }
    }

    /// Past the grace a leader that holds the model alone serves alone: its solo server is no part of the pair, so when it
    /// ends it starts again after the ordinary 6 s, not the away wait, though the other Mac is still away.
    @Test func aSoloServerThatEndsWaitsTheOrdinaryBackoffWhileTheOtherMacIsAway() throws {
        try withLeaderWhoseOtherMacIsAway(holdsModelAlone: true, soloGrace: 0) { leader in
            guard case .alone = leader.mode else {
                Issue.record("the leader does not serve alone: \(leader.mode)")
                return
            }
            leader.run()
            let child = try leader.endedPart()
            // The service says so just after its status shows the wait.
            let saidBy = Date().addingTimeInterval(2)
            func said() -> Bool { leader.lines.values.contains { $0.contains("this Mac's solo server ended") } }
            while !said(), Date() < saidBy { usleep(20_000) }
            #expect(said(), "\(leader.lines.values)")
            #expect((1...6).contains(child.restartInSeconds ?? 0),
                    "it waits 6 s, not the away wait: \(String(describing: child.restartInSeconds))")
            #expect(child.restartWaitsForOtherMac == nil, "the other Mac's answer is not what it waits for")
            #expect(leader.starts.values.count == 1, "\(leader.lines.values)")
        }
    }

    static let journalRefusal = "Unresolved native ownership journal: an earlier cluster session's owner ended before its "
        + "worker was seen to exit. Run `darkbloom cluster recover` on this Mac; it clears the journal once nothing it names is running."

    /// A part whose start this Mac's device journal refuses (a stop landed seconds after the pair came up, and the
    /// owner ended before publishing its worker's cleanup): every later start ended the same way until someone ran
    /// `darkbloom cluster recover`. The service runs that recovery itself, once per run of refused starts, and starts the
    /// part again at once; the next refusal of the same run is left to the person.
    @Test func aPartRefusedByTheDeviceJournalIsRecoveredOncePerRun() throws {
        try withLeader(otherMacAway: false, soloGrace: 3_600, partError: Self.journalRefusal) { leader in
            leader.service.lock.withLock {
                _ = leader.service.control?.receiveAnswer(from: leader.other.memberID, sent: leader.claim,
                                                          answer: .accepted(leader.other), now: ClusterService.monotonicSeconds())
            }
            let recoveries = ClusterApprovalRecorder<Bool>()
            leader.service.journalAutoRecover = true
            leader.service.deviceJournalRecovery = {
                recoveries.append(true)
                return (ClusterDeviceRecovery.report(.cleared(.init(clusterID: "fixture", peerID: "fixture", rank: 0,
                    membershipEpoch: "fixture", leaseID: "fixture", ownerIncarnation: "fixture", nativeLaunchID: "fixture"))), 1)
            }
            leader.run()
            let until = Date().addingTimeInterval(20)
            while leader.starts.values.count < 3, Date() < until { usleep(50_000) }
            let starts = leader.starts.values
            #expect(starts.count >= 3, "\(leader.lines.values)")
            #expect(recoveries.values.count == 1, "recovered \(recoveries.values.count) times: \(leader.lines.values)")
            #expect(starts.count >= 2 && starts[1] - starts[0] < 2, "it started again at once after the recovery: \(starts)")
            let cleared = leader.lines.values.filter { $0.contains("device journal named an earlier session whose owner is gone: cleared it") }
            #expect(cleared.count == 1 && cleared[0].contains("removed 1 stale bootstrap directory"), "\(leader.lines.values)")
        }
    }

    /// A save of the cluster approval that the stranded journal refused before the part's recovery cleared it (the guided
    /// setup's approval step saves right after its own stop, and the save's own recovery refused then): the next approval
    /// check asks again at once, and the status no longer says to run `cluster recover`.
    @Test func aClearedJournalTriesTheApprovalSaveItRefusedAgain() throws {
        try withLeader(otherMacAway: false, soloGrace: 3_600, partError: Self.journalRefusal) { leader in
            leader.service.lock.withLock {
                _ = leader.service.control?.receiveAnswer(from: leader.other.memberID, sent: leader.claim,
                                                          answer: .accepted(leader.other), now: ClusterService.monotonicSeconds())
            }
            let refused = "Not offered for pairing: this Mac could not save its setup: Unresolved native ownership journal; "
                + "run `darkbloom cluster recover`"
            _ = try leader.service.store.updateRecord { $0.approvalNote = refused }
            let later = Date().addingTimeInterval(3_600)
            leader.service.lock.withLock { leader.service.nextApprovalCheck = later }
            leader.service.journalAutoRecover = true
            leader.service.deviceJournalRecovery = {
                (ClusterDeviceRecovery.report(.cleared(.init(clusterID: "fixture", peerID: "fixture", rank: 0,
                    membershipEpoch: "fixture", leaseID: "fixture", ownerIncarnation: "fixture", nativeLaunchID: "fixture"))), 0)
            }
            leader.run()
            func note() -> String? { (try? leader.service.store.readRecord())?.approvalNote }
            let until = Date().addingTimeInterval(10)
            while note() == refused, Date() < until { usleep(50_000) }
            #expect(note() == ClusterJournalAutoRecover.clearedSaveNote, "\(leader.lines.values)")
            let nextCheck = leader.service.lock.withLock { leader.service.nextApprovalCheck }
            #expect(nextCheck < later, "the approval check was not asked again")
            let reason = ClusterOnboardingReady.notOfferedReason(note())
            #expect(!reason.contains("cluster recover") && reason.contains("the next approval check saves the cluster approval again"),
                    "\(reason)")
        }
    }

    /// The leader's approval check while the coordinator offers the pair's model and the other Mac doesn't answer over the
    /// cable (`withLeader` leaves it nothing to answer with), so the check's save, which stops a serving pair, waits.
    /// `holdLock`: a person's command holds the control command lock during the first check. The first check asks the
    /// coordinator; once it has ended, the next one is brought forward. Returns the coordinator's answers in all.
    private func approvalCheckAsks(holdLock: Bool) async throws -> (first: Int, total: Int, lines: [String]) {
        let mock = MockCoordinator()
        let url = try await mock.start().mockProviderWebSocketURL()
        var counts = (first: 0, total: 0, lines: [String]())
        try withLeader(otherMacAway: false, soloGrace: 3_600, coordinatorURL: url) { leader in
            leader.service.lock.withLock {
                _ = leader.service.control?.receiveAnswer(from: leader.other.memberID, sent: leader.claim,
                                                          answer: .accepted(leader.other), now: ClusterService.monotonicSeconds())
            }
            let macs = try #require(leader.macs)
            let approval = macs.modelApproval()
            mock.setClusterApprovals(body: try ClusterApprovalMacs.body([approval]))
            // The pair isn't offered yet (no approval saved), and the coordinator's answer is one to save.
            let saved = try macs.saved(macs.leader)
            #expect(saved.configuration.nativeMember?.clusterApproval == nil)
            guard case .save = ClusterApprovalSync.decision(saved: saved, fetched: .approvals([approval]), now: Date().timeIntervalSince1970,
                                                            facts: { _ in throw ClusterConfigurationError.invalid("not needed") })
            else { Issue.record("the fixture's approval is not one to save"); return }
            let held = holdLock ? ClusterControlCommandLock.acquire(seconds: 5,
                file: leader.service.store.paths.directory.appendingPathComponent("control.lock")) : nil
            #expect(!holdLock || held != nil)
            func asked() -> Int { mock.snapshot().clusterApprovalQueries.count }
            func due() -> Bool { leader.service.lock.withLock { leader.service.nextApprovalCheck } > Date() }
            leader.run()
            var until = Date().addingTimeInterval(20)
            while !(asked() >= 1 && due()), Date() < until { usleep(50_000) }
            counts.first = asked()
            held?.release()
            leader.service.lock.withLock { leader.service.nextApprovalCheck = .distantPast }
            until = Date().addingTimeInterval(20)
            while asked() < 2, Date() < until { usleep(50_000) }
            counts.total = asked()
            counts.lines = leader.lines.values
        }
        await mock.shutdown()
        return counts
    }

    /// The other Mac doesn't answer, so the check's save waits (it would stop a serving pair for nothing). That check is
    /// not this service run's check yet: the next one asks the coordinator again. Marked done, a pair that wasn't offered
    /// asked nothing more until its service restarted, and stayed on its local API after the other Mac came back (a
    /// DevNet pair, 2026-11-19: a cable unplugged after a failed approval save, about 4 hours not offered).
    @Test func anApprovalCheckThatWaitsForTheOtherMacAsksAgainAtTheNextCheck() async throws {
        let counts = try await approvalCheckAsks(holdLock: false)
        #expect(counts.first == 1, "\(counts.lines)")
        #expect(counts.total >= 2, "the next check did not ask the coordinator again: \(counts.lines)")
    }

    /// A person's command holds the control command lock: the check says it tries again in a minute, and that next check
    /// asks the coordinator again.
    @Test func anApprovalCheckSkippedForABusyCommandLockAsksAgainAtTheNextCheck() async throws {
        let counts = try await approvalCheckAsks(holdLock: true)
        #expect(counts.first == 1, "\(counts.lines)")
        #expect(counts.lines.contains { $0.contains("another cluster command is running") }, "\(counts.lines)")
        #expect(counts.total >= 2, "the next check did not ask the coordinator again: \(counts.lines)")
    }

    /// A recovery that refuses (the journal's owner or worker still runs) changes nothing: it says why and the part keeps
    /// its wait.
    @Test func aRefusedJournalRecoveryKeepsThePartsWait() throws {
        try withLeader(otherMacAway: false, soloGrace: 3_600, partError: Self.journalRefusal) { leader in
            leader.service.lock.withLock {
                _ = leader.service.control?.receiveAnswer(from: leader.other.memberID, sent: leader.claim,
                                                          answer: .accepted(leader.other), now: ClusterService.monotonicSeconds())
            }
            leader.service.journalAutoRecover = true
            leader.service.deviceJournalRecovery = { (ClusterDeviceRecovery.report(.refusedLiveOwner), 0) }
            leader.run()
            let child = try leader.endedPart()
            #expect((5...6).contains(child.restartInSeconds ?? 0), "the ordinary wait: \(String(describing: child.restartInSeconds))")
            let saidBy = Date().addingTimeInterval(2)
            func said() -> Bool { leader.lines.values.contains { $0.contains("device journal refuses the part's start and can't be cleared yet") } }
            while !said(), Date() < saidBy { usleep(20_000) }
            #expect(said(), "\(leader.lines.values)")
        }
    }

    /// With the switch off, nothing is recovered.
    @Test func theJournalRecoveryIsOffWithItsSwitch() throws {
        try withLeader(otherMacAway: false, soloGrace: 3_600, partError: Self.journalRefusal) { leader in
            leader.service.lock.withLock {
                _ = leader.service.control?.receiveAnswer(from: leader.other.memberID, sent: leader.claim,
                                                          answer: .accepted(leader.other), now: ClusterService.monotonicSeconds())
            }
            let recoveries = ClusterApprovalRecorder<Bool>()
            leader.service.journalAutoRecover = false
            leader.service.deviceJournalRecovery = { recoveries.append(true); return (ClusterDeviceRecovery.report(.nothingToRecover), 0) }
            leader.run()
            _ = try leader.endedPart()
            usleep(500_000)
            #expect(recoveries.values.isEmpty, "\(leader.lines.values)")
        }
    }

    /// `DARKBLOOM_CLUSTER_JOURNAL_AUTO_RECOVER` reaches the cluster service through its login agent, only an off word
    /// turns it off, and only the journal's refusal counts.
    @Test func theJournalRecoverySwitchAndItsRefusal() {
        let key = ClusterJournalAutoRecover.environmentKey
        #expect(key == "DARKBLOOM_CLUSTER_JOURNAL_AUTO_RECOVER")
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        for word in ["0", "off", "FALSE", " no ", "disabled", "none"] { #expect(!ClusterJournalAutoRecover.isEnabled(word), "\(word)") }
        for word in [nil, "", "1", "on", "true"] { #expect(ClusterJournalAutoRecover.isEnabled(word), "\(String(describing: word))") }
        #expect(ClusterJournalAutoRecover.refusedByJournal(Self.journalRefusal))
        #expect(ClusterJournalAutoRecover.refusedByJournal("Unresolved native ownership journal; run `darkbloom cluster recover`"))
        #expect(!ClusterJournalAutoRecover.refusedByJournal("closed") && !ClusterJournalAutoRecover.refusedByJournal(nil))
    }

    /// The leading Mac's service, its part `/usr/bin/true`, and no paired Mac on the cable. This Mac leads the plan, and
    /// the other Mac was last heard 10 s ago, past its 1 s time-to-live: within `soloGrace` it waits for the other Mac;
    /// after it, holding the model alone (`holdsModelAlone`), it serves alone. The service stops when `body` returns.
    private func withLeaderWhoseOtherMacIsAway(holdsModelAlone: Bool? = nil, soloGrace: Double,
                                               _ body: (AwayLeader) throws -> Void) throws {
        try withLeader(otherMacAway: true, holdsModelAlone: holdsModelAlone, soloGrace: soloGrace, body)
    }

    /// The same leader, the other Mac away or heard just now (its time-to-live an hour). `refusesForMemory`: before each
    /// start of the part, the load gate's refusal of a share is recorded in this install's incidents, as a part records
    /// a follower's refusal (`memory_gate_refused`). `partError`: each start's part writes this error line to the rank
    /// log, as a part refused at its start does.
    private func withLeader(otherMacAway: Bool, holdsModelAlone: Bool? = nil, soloGrace: Double, refusesForMemory: Bool = false,
                            partError: String? = nil, coordinatorURL: String = "ws://127.0.0.1:9/ws/provider",
                            _ body: (AwayLeader) throws -> Void) throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: coordinatorURL)
        try withExtendedLifetime(macs) {
            let leader = macs.leader, follower = macs.follower
            // Only this service runs: no paired Mac answers over the cable.
            try FileManager.default.moveItem(at: leader.pairing.directory,
                                             to: leader.home.appendingPathComponent("pairing-elsewhere", isDirectory: true))
            let starts = ClusterApprovalRecorder<Double>()
            let incidents = ClusterIncidentLog.forThisInstall(homeDirectory: leader.home)
            let rankLog = ClusterSetupPaths(paths: leader.paths).directory.appendingPathComponent("rank.log")
            let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: leader.provider,
                darkbloomExecutable: URL(fileURLWithPath: "/usr/bin/true"), sessionArguments: [], pair: nil, dryRun: true,
                version: "fixture")
            let service = ClusterService(settings: .init(wizard: wizard, leaderArguments: [], followerArguments: []),
                paths: leader.paths, recoveryGraceSeconds: 0.2, supervisionIntervalSeconds: 0.1,
                beforePartStart: {
                    starts.append(Date().timeIntervalSince1970)
                    if refusesForMemory {
                        try? incidents.record(.init(severity: .error, source: "leader", stateCode: "activation_launch_failed",
                            reasonCode: "memory_gate_refused", guidanceCode: "memory_gate_refused",
                            message: "fixture: Resident load needs 7.38 GiB of admissible memory and has 3.09 GiB"))
                    }
                    if let partError, let handle = try? FileHandle(forWritingTo: rankLog) {
                        handle.seekToEndOfFile(); handle.write(Data("Error: \(partError)\n".utf8)); try? handle.close()
                    }
                },
                // Its power assertions apart from those of the other services this test process runs.
                powerAssertionReason: "Cluster part restart test " + UUID().uuidString)
            var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: leader.pin, peerPin: follower.pin,
                peerName: "fixture member", since: "fixture")
            leadership.serving = true; leadership.modelName = ClusterApprovalMacs.model
            _ = try service.store.updateRecord { $0.leadership = leadership }
            let claim = ClusterControlClaim(term: 1, leaderID: leader.memberID, members: [leader.memberID, follower.memberID],
                                            reason: "fixture")
            let other = ClusterControlMember(memberID: follower.memberID, name: "fixture member", memoryBytes: 1, gpuCores: 1)
            let node = ClusterControlNode(localID: leader.memberID,
                members: [.init(memberID: leader.memberID, name: "fixture leader", memoryBytes: 1, gpuCores: 1,
                                holdsModelAlone: holdsModelAlone), other],
                claim: claim, rankOrder: [leader.memberID, follower.memberID],
                now: ClusterService.monotonicSeconds() - (otherMacAway ? 10 : 0), ttl: otherMacAway ? 1 : 3_600, soloGrace: soloGrace)
            service.lock.withLock { service.control = node }
            let away = AwayLeader(service: service, starts: starts, other: other, claim: claim)
            away.macs = macs
            defer { away.stop() }
            try body(away)
        }
    }

    private final class AwayLeader: @unchecked Sendable {
        let service: ClusterService
        let starts: ClusterApprovalRecorder<Double>
        let lines = ClusterApprovalRecorder<String>()
        let other: ClusterControlMember
        let claim: ClusterControlClaim
        /// Both Macs' homes and saved setups (the follower's answers nothing over the cable).
        var macs: ClusterApprovalMacs?
        private let stopping = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        private var running = false

        init(service: ClusterService, starts: ClusterApprovalRecorder<Double>, other: ClusterControlMember,
             claim: ClusterControlClaim) {
            self.service = service; self.starts = starts; self.other = other; self.claim = claim
        }

        var mode: ClusterControlNode.Mode {
            let now = ClusterService.monotonicSeconds()
            return service.lock.withLock { service.control?.mode(now: now) } ?? .idle
        }

        func run() {
            running = true
            let service = service, lines = lines, stopping = stopping, done = done
            Thread.detachNewThread {
                _ = try? service.run(stop: stopping) { lines.append($0) }
                done.signal()
            }
        }

        /// The status once the part has started, ended at once, and waits to start again.
        func endedPart() throws -> ClusterServiceStatus.Child {
            let deadline = Date().addingTimeInterval(20)
            var waiting: ClusterServiceStatus.Child?
            while waiting == nil, Date() < deadline {
                let child = service.status().child
                if !starts.values.isEmpty, !child.running, child.restartInSeconds != nil { waiting = child } else { usleep(20_000) }
            }
            return try #require(waiting, "the part did not start and end: \(lines.values)")
        }

        func stop() {
            guard running else { return }
            stopping.signal()
            _ = done.wait(timeout: .now() + 30)
        }
    }
}
