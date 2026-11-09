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
    @Test func aLeaderWhoseOtherMacIsAwayWaitsLongerToStartItsPartAgainAndStartsItAtOnceWhenItAnswers() throws {
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
            // This Mac leads the plan. The other Mac was last heard 10 s ago, past its 1 s time-to-live, and this Mac
            // would serve alone (it can't here) only after an hour: it waits for the other Mac, its part wanted.
            let claim = ClusterControlClaim(term: 1, leaderID: leader.memberID, members: [leader.memberID, follower.memberID],
                                            reason: "fixture")
            let other = ClusterControlMember(memberID: follower.memberID, name: "fixture member", memoryBytes: 1, gpuCores: 1)
            let node = ClusterControlNode(localID: leader.memberID,
                members: [.init(memberID: leader.memberID, name: "fixture leader", memoryBytes: 1, gpuCores: 1), other],
                claim: claim, rankOrder: [leader.memberID, follower.memberID], now: ClusterService.monotonicSeconds() - 10,
                ttl: 1, soloGrace: 3_600)
            guard case .waiting = node.mode(now: ClusterService.monotonicSeconds()) else {
                Issue.record("the leader is not waiting for the other Mac: \(node.mode(now: ClusterService.monotonicSeconds()))")
                return
            }
            service.lock.withLock { service.control = node }

            let stop = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let lines = ClusterApprovalRecorder<String>()
            Thread.detachNewThread {
                _ = try? service.run(stop: stop) { lines.append($0) }
                done.signal()
            }
            defer {
                stop.signal()
                _ = done.wait(timeout: .now() + 30)
            }
            // The part starts, ends at once, and waits to start again.
            let deadline = Date().addingTimeInterval(20)
            var waiting: ClusterServiceStatus.Child?
            while waiting == nil, Date() < deadline {
                let child = service.status().child
                if !starts.values.isEmpty, !child.running, child.restartInSeconds != nil { waiting = child } else { usleep(20_000) }
            }
            let child = try #require(waiting, "the part did not start and end: \(lines.values)")
            #expect((child.restartInSeconds ?? 0) >= 29,
                    "it waits 30 s, not the 6 s of a part whose other Mac answers: \(String(describing: child.restartInSeconds))")
            #expect(starts.values.count == 1, "\(lines.values)")

            // The other Mac answers: the part starts again at once.
            let answered = Date().timeIntervalSince1970
            service.lock.withLock {
                _ = service.control?.receiveAnswer(from: follower.memberID, sent: claim, answer: .accepted(other),
                                                   now: ClusterService.monotonicSeconds())
            }
            let until = Date().addingTimeInterval(5)
            while starts.values.count < 2, Date() < until { usleep(20_000) }
            let again = try #require(starts.values.dropFirst().first, "the part did not start again: \(lines.values)")
            #expect(again - answered < 3, "it started \(again - answered) s after the other Mac answered")
        }
    }
}
