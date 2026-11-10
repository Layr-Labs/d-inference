import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// The leading Mac's cluster service while the other Mac doesn't answer (asleep, off, or its cable out). Inside the
/// absence grace the leader keeps its part wanted, so the pair re-forms when the other Mac is back; a part that can't form
/// the pair ends, and the service starts it again. A MiMo leader whose follower slept started it every 48 s, each start
/// reading its share of the model again and registering again with the coordinator (2026-11-09). The part here is
/// `/usr/bin/true`, which ends at once; nothing loads a model and no other Mac answers.
@Suite("Cluster service: a part whose other Mac is away", .serialized)
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
            #expect(leader.lines.values.contains { $0.contains("this Mac's solo server ended") }, "\(leader.lines.values)")
            #expect((1...6).contains(child.restartInSeconds ?? 0),
                    "it waits 6 s, not the away wait: \(String(describing: child.restartInSeconds))")
            #expect(child.restartWaitsForOtherMac == nil, "the other Mac's answer is not what it waits for")
            #expect(leader.starts.values.count == 1, "\(leader.lines.values)")
        }
    }

    /// The leading Mac's service, its part `/usr/bin/true`, and no paired Mac on the cable. This Mac leads the plan, and
    /// the other Mac was last heard 10 s ago, past its 1 s time-to-live: within `soloGrace` it waits for the other Mac;
    /// after it, holding the model alone (`holdsModelAlone`), it serves alone. The service stops when `body` returns.
    private func withLeaderWhoseOtherMacIsAway(holdsModelAlone: Bool? = nil, soloGrace: Double,
                                               _ body: (AwayLeader) throws -> Void) throws {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        try withExtendedLifetime(macs) {
            let leader = macs.leader, follower = macs.follower
            // Only this service runs: no paired Mac answers over the cable.
            try FileManager.default.moveItem(at: leader.pairing.directory,
                                             to: leader.home.appendingPathComponent("pairing-elsewhere", isDirectory: true))
            let starts = ClusterApprovalRecorder<Double>()
            let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: leader.provider,
                darkbloomExecutable: URL(fileURLWithPath: "/usr/bin/true"), sessionArguments: [], pair: nil, dryRun: true,
                version: "fixture")
            let service = ClusterService(settings: .init(wizard: wizard, leaderArguments: [], followerArguments: []),
                paths: leader.paths, recoveryGraceSeconds: 0.2, supervisionIntervalSeconds: 0.1,
                beforePartStart: { starts.append(Date().timeIntervalSince1970) },
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
                claim: claim, rankOrder: [leader.memberID, follower.memberID], now: ClusterService.monotonicSeconds() - 10,
                ttl: 1, soloGrace: soloGrace)
            service.lock.withLock { service.control = node }
            let away = AwayLeader(service: service, starts: starts, other: other, claim: claim)
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
