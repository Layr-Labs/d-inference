import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// What the other Mac answered the stop right after both Macs restarted into an update: no answer within the command's
/// 30 s, or a refusal because control moved to it while this Mac was down (`ClusterService`'s `stop` command).
private let otherMacFailures = [
    "the other Mac did not answer within 30 s",
    "the Mac that asked no longer leads: term 2 superseded its term 1",
    "this Mac does not follow the Mac that asked",
]

/// The control leader's automatic steps that stop the pair only to start it again: the re-plan after a Darkbloom update
/// and a change of the pair's cluster approval. DevNet pair-2, 2026-11-07 (`0.10.10-dev.branch.135` → `.137`): after the
/// coordinated update the pair stayed "Stopped" on both Macs, and only `darkbloom cluster` served it again. The stop
/// (`OnboardingLive.localStop`) clears the pair's saved start before it stops anything; when it then failed, nothing put
/// the start back, and both steps act only while the start is saved, so nothing tried again. Each Mac here has its own
/// home (`ClusterApprovalMacs`); the stop is the real one, with the other Mac's answer given.
@Suite("Cluster service: a stop only to start the pair again", .serialized)
struct ClusterServiceRestartingStopTests {
    /// The leading Mac of a pair the fixture saved, its pair started as it is when an update or an approval change stops
    /// it. Its cluster service runs no loop: only the steps under test act on its record.
    private func leader() throws -> (ClusterApprovalMacs, ClusterService) {
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider")
        return (macs, try Self.service(macs))
    }

    private static func service(_ macs: ClusterApprovalMacs) throws -> ClusterService {
        let leader = macs.leader
        let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: leader.provider,
            darkbloomExecutable: URL(fileURLWithPath: "/usr/bin/true"), sessionArguments: [], pair: nil, dryRun: true,
            version: "fixture")
        let service = ClusterService(settings: .init(wizard: wizard, leaderArguments: [], followerArguments: []),
            paths: leader.paths, recoveryGraceSeconds: 0.2, supervisionIntervalSeconds: 0.1,
            // Its power assertions apart from those of the other services this test process runs.
            powerAssertionReason: "Cluster restarting stop test " + UUID().uuidString)
        var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: leader.pin, peerPin: macs.follower.pin,
            peerName: "fixture peer", since: "fixture")
        leadership.serving = true; leadership.modelName = ClusterApprovalMacs.model
        _ = try service.store.updateRecord { $0.leadership = leadership }
        return service
    }

    /// The stop both steps make (`OnboardingLive.localStop`): this Mac's saved start cleared, its part retired, then the
    /// other Mac asked, here with `otherMac`.
    private static func stop(_ service: ClusterService, otherMac: @escaping () throws -> Void)
        -> () -> Result<[String], ClusterOnboardingFailure> {
        { service.controlLive.localStop(seconds: 1, stopPeer: otherMac) }
    }

    /// Steps after the stop that must not run once it failed.
    private static func notAfterAFailedStop(_ steps: inout ClusterService.UpdateReplan) {
        steps.awaitReleased = { Issue.record("waited for the parts' memory after a failed stop") }
        steps.planModels = { Issue.record("planned after a failed stop"); return .success([]) }
        steps.adopt = { _ in Issue.record("adopted a setup after a failed stop"); return .success([]) }
        steps.serve = { Issue.record("served after a failed stop"); return .success([]) }
    }

    private static func steps(_ service: ClusterService, stop: @escaping () -> Result<[String], ClusterOnboardingFailure>)
        -> ClusterService.UpdateReplan {
        .init(reachMembers: { .success([]) }, stop: stop, awaitReleased: {}, planModels: { .success([]) },
              adopt: { _ in .success([]) }, serve: { .success([]) }, restoreStart: { service.restoreStart() })
    }

    /// The control command lock the steps and the memory re-plan take: beside the service's own files.
    private static func commandLock(_ service: ClusterService) -> URL {
        service.store.paths.directory.appendingPathComponent("control.lock")
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            usleep(20_000)
        }
        return true
    }

    /// The service's loop on a thread of its own, its lines kept; `stop` ends it and returns them.
    private static func run(_ service: ClusterService) -> (lines: ClusterApprovalRecorder<String>, stop: () -> [String]) {
        let stop = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let lines = ClusterApprovalRecorder<String>()
        Thread.detachNewThread {
            _ = try? service.run(stop: stop) { lines.append($0) }
            done.signal()
        }
        return (lines, {
            stop.signal()
            #expect(done.wait(timeout: .now() + 30) == .success, "the service did not stop")
            return lines.values
        })
    }

    /// The control node of the leader's service: `leader` leads in `term` (this Mac or the other).
    private static func node(_ macs: ClusterApprovalMacs, leader: String, term: UInt64) -> ClusterControlNode {
        let local = macs.leader.memberID, peer = macs.follower.memberID
        return ClusterControlNode(localID: local,
            members: [.init(memberID: local, name: "fixture", memoryBytes: 1, gpuCores: 1),
                      .init(memberID: peer, name: "fixture peer", memoryBytes: 1, gpuCores: 1)],
            claim: .init(term: term, leaderID: leader, members: [local, peer], reason: "fixture"), rankOrder: nil,
            now: ClusterService.monotonicSeconds(), ttl: 3_600)
    }

    /// The leader's service as its loop runs it after an update: no paired Mac answers its listeners, and the other Mac
    /// confirmed this Mac's claim. Without a plan order its mode is idle: nothing of the model starts here.
    private static func confirmedLeader(_ service: ClusterService, _ macs: ClusterApprovalMacs) throws {
        try FileManager.default.moveItem(at: macs.leader.pairing.directory,
                                         to: macs.leader.home.appendingPathComponent("pairing-elsewhere", isDirectory: true))
        var node = Self.node(macs, leader: macs.leader.memberID, term: 1)
        let peer = macs.follower.memberID, claim = node.claim
        _ = node.receiveAnswer(from: peer, sent: claim,
            answer: .accepted(.init(memberID: peer, name: "fixture peer", memoryBytes: 1, gpuCores: 1)), now: ClusterService.monotonicSeconds())
        try #require(node.leadershipConfirmed(now: ClusterService.monotonicSeconds()))
        service.lock.withLock { service.control = node }
    }

    /// Both Macs answer with one new build: the saved setups pin the worker before the update (`ClusterApprovalMacs`'s).
    private static func oneNewBuild(_ macs: ClusterApprovalMacs) -> [String: String?] {
        let new: String? = ClusterApprovalMacs.hash("9")
        return [macs.leader.memberID: new, macs.follower.memberID: new]
    }

    /// The leading Mac of an offered pair as its service loop runs it, its other Mac silent past the lease (time-to-live
    /// 1 s): its setup carries a current cluster approval that its coordinator (answering 404) no longer lists, so the
    /// approval check changes the pair to serve locally (`ClusterApprovalCheck.Step.serveLocally(_, .withdrawn)`), which
    /// stops a serving pair first. Its part is the CPU-only service-part fixture, which ends at once when asked to stop.
    private static func approvalLeader(_ macs: ClusterApprovalMacs, serving: Bool) throws -> (ClusterService, URL) {
        let leader = macs.leader, saved = try macs.saved(leader), facts = try macs.facts()
        let current = try ClusterApprovalAttachment.attachment(for: macs.approval(), saved: saved, paths: leader.paths,
            pairingStore: leader.pairing, edge: nil, now: Date().timeIntervalSince1970, chipClass: ClusterApprovalMacs.chip,
            facts: { _ in facts })
        let attachment = ClusterNativeMemberAttachment(ownerSHA256: current.ownerSHA256, metallibPath: current.metallibPath,
            resourceLibraryPath: current.resourceLibraryPath, clusterApproval: macs.approval(endsIn: 14 * 86_400),
            roster: try #require(current.roster), memberPins: try #require(current.memberPins), edges: nil)
        try ClusterApprovalAttachment.save(attachment, saved: saved, paths: leader.paths, providerConfiguration: leader.provider,
                                           scratch: leader.scratch)
        try FileManager.default.moveItem(at: leader.pairing.directory,
                                         to: leader.home.appendingPathComponent("pairing-elsewhere", isDirectory: true))
        let helper = leader.home.appendingPathComponent("service-part-fixture")
        try NativePairMemberFixture.helper().write(to: helper, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let parts = leader.home.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for role in ["leader", "member"] { try Data().write(to: parts.appendingPathComponent("release-" + role)) }
        let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: leader.provider, darkbloomExecutable: helper,
            sessionArguments: [], pair: nil, dryRun: true, version: "fixture")
        let service = ClusterService(settings: .init(wizard: wizard,
            leaderArguments: ["--service-part-fixture", parts.path, "leader"], followerArguments: [],
            soloArguments: ["--service-part-fixture", parts.path, "replacement"],
            memberArguments: ["--service-part-fixture", parts.path, "member"]), paths: leader.paths, recoveryGraceSeconds: 0.2,
            powerAssertionReason: "Cluster restarting stop test " + UUID().uuidString)
        var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: leader.pin, peerPin: macs.follower.pin,
            peerName: "fixture peer", since: "fixture")
        leadership.serving = serving; leadership.modelName = ClusterApprovalMacs.model
        _ = try service.store.updateRecord { $0.leadership = leadership }
        // Inside the other Mac's absence grace: this Mac runs its part of the cluster.
        let local = leader.memberID, peer = macs.follower.memberID
        let node = ClusterControlNode(localID: local,
            members: [.init(memberID: local, name: "fixture", memoryBytes: 1, gpuCores: 1, holdsModelAlone: false)],
            claim: .init(term: 1, leaderID: local, members: [local, peer], reason: "fixture"),
            rankOrder: [local, peer], now: ClusterService.monotonicSeconds(), ttl: 1, soloGrace: 3_600)
        service.lock.withLock { service.control = node }
        return (service, parts)
    }

    /// How many parts of `role` the fixture recorded with `suffix`: `.ready` started, `.term` asked to stop.
    private static func count(_ parts: URL, _ role: String, _ suffix: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: parts.path)) ?? []).filter { $0.hasPrefix(role + "-") && $0.hasSuffix(suffix) }.count
    }

    @Test(arguments: otherMacFailures)
    func anUpdateReplanWhoseStopTheOtherMacDidNotTakeLeavesThePairStarted(_ answer: String) throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            var steps = Self.steps(service, stop: Self.stop(service) { throw ClusterSetupFailure(answer) })
            Self.notAfterAFailedStop(&steps)
            let outcome = ClusterService.replanAfterUpdate(model: ClusterApprovalMacs.model, steps)
            guard case .failure(let failure) = outcome else { Issue.record("the re-plan went on: \(outcome)"); return }
            #expect(failure.lines.joined().contains(answer), "\(failure.lines)")
            let record = try service.store.readRecord()
            #expect(record.leadership?.serving == true, "the failed stop left the pair stopped (\(answer))")
            #expect(record.stopDrain == nil)
        }
    }

    /// This Mac's own part did not release in time (`ClusterService.stopLocalPart`): the stop keeps its request, so a
    /// person's `darkbloom cluster stop` can finish it. A re-plan's stop puts the start back and drops that request, or
    /// the request alone would keep the pair from serving (`OnboardingLive.localServe`) and from syncing the other Mac.
    @Test func anUpdateReplanWhosePartDidNotReleaseLeavesThePairStarted() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            // A status that cannot be read: the stop cannot tell that this Mac's part released.
            try Data("not a status".utf8).write(to: service.store.paths.directory.appendingPathComponent(ClusterServiceStatus.fileName))
            let asked = ClusterApprovalRecorder<Bool>()
            var steps = Self.steps(service, stop: Self.stop(service) { asked.append(true) })
            Self.notAfterAFailedStop(&steps)
            let outcome = ClusterService.replanAfterUpdate(model: ClusterApprovalMacs.model, steps)
            guard case .failure(let failure) = outcome else { Issue.record("the re-plan went on: \(outcome)"); return }
            #expect(failure.lines.joined().contains("has not finished releasing its memory"), "\(failure.lines)")
            #expect(asked.values.isEmpty, "the other Mac was asked to stop before this Mac's part released")
            let record = try service.store.readRecord()
            #expect(record.leadership?.serving == true, "the failed stop left the pair stopped")
            #expect(record.stopDrain == nil, "the failed stop's request stayed: \(String(describing: record.stopDrain))")
        }
    }

    /// Unchanged: a re-plan that stopped both Macs and then failed puts the start back (the next check tries again).
    @Test(arguments: ["plan", "offer", "adopt", "serve"])
    func anUpdateReplanThatFailsAfterItsStopLeavesThePairStarted(_ failing: String) throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            var steps = Self.steps(service, stop: Self.stop(service) {})
            let refused = ClusterOnboardingFailure("fixture refusal")
            let offered = ClusterOnboardingModelChoice(title: ClusterApprovalMacs.model, lines: ["fixture plan"], blocker: nil,
                                                       modelID: ClusterApprovalMacs.model)
            switch failing {
            case "plan": steps.planModels = { .failure(refused) }
            case "offer": steps.planModels = { .success([ClusterOnboardingModelChoice(title: "another/model", lines: [], blocker: nil)]) }
            case "adopt": steps.planModels = { .success([offered]) }; steps.adopt = { _ in .failure(refused) }
            case "serve": steps.planModels = { .success([offered]) }; steps.serve = { .failure(refused) }
            default: Issue.record("no step \(failing)"); return
            }
            guard case .failure = ClusterService.replanAfterUpdate(model: ClusterApprovalMacs.model, steps) else {
                Issue.record("the re-plan did not fail at \(failing)"); return
            }
            let serving = try service.store.readRecord().leadership?.serving
            #expect(serving == true, "a failed \(failing) left the pair stopped")
        }
    }

    @Test func anUpdateReplanThatReachesNoOtherMacStopsNothing() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            let before = try service.store.readRecord()
            var steps = Self.steps(service, stop: { Issue.record("stopped without the other Mac"); return .success([]) })
            steps.reachMembers = { .failure(ClusterOnboardingFailure("the other Mac did not answer over the cable within 2 minutes")) }
            steps.restoreStart = { Issue.record("put a start back that nothing cleared") }
            guard case .failure = ClusterService.replanAfterUpdate(model: ClusterApprovalMacs.model, steps) else {
                Issue.record("the re-plan went on without the other Mac"); return
            }
            #expect(try service.store.readRecord() == before)
        }
    }

    @Test(arguments: otherMacFailures)
    func anApprovalChangeWhoseStopTheOtherMacDidNotTakeLeavesThePairStarted(_ answer: String) throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            let line = ClusterService.stopForApprovalChange(serving: true, stop: Self.stop(service) { throw ClusterSetupFailure(answer) },
                drained: { Issue.record("waited for a drain after a failed stop"); return true },
                restoreStart: { service.restoreStart() })
            #expect(line?.hasPrefix("could not stop the parts to change the cluster approval: ") == true, "\(line ?? "nil")")
            #expect(line?.contains(answer) == true, "\(line ?? "nil")")
            let record = try service.store.readRecord()
            #expect(record.leadership?.serving == true, "the failed stop left the pair stopped (\(answer))")
            #expect(record.stopDrain == nil)
        }
    }

    @Test func anApprovalChangeOfAPairThatDoesNotServeStopsNothing() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            let before = try service.store.readRecord()
            let line = ClusterService.stopForApprovalChange(serving: false,
                stop: { Issue.record("stopped a pair that does not serve"); return .success([]) },
                drained: { Issue.record("waited for a drain"); return true },
                restoreStart: { Issue.record("started a pair that does not serve") })
            #expect(line == nil)
            #expect(try service.store.readRecord() == before)
        }
    }

    /// The stop went through, but a part did not end within the 5 minutes the change waits for.
    @Test func anApprovalChangeWhosePartsDidNotStopLeavesThePairStarted() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            let line = ClusterService.stopForApprovalChange(serving: true, stop: Self.stop(service) {}, drained: { false },
                                                            restoreStart: { service.restoreStart() })
            #expect(line == "a part did not stop within 5 minutes: the cluster approval stays as it is")
            let record = try service.store.readRecord()
            #expect(record.leadership?.serving == true, "the parts that did not stop left the pair stopped")
            #expect(record.stopDrain == nil)
        }
    }

    /// Once both Macs changed their setups, the parts start again (`OnboardingLive.localServe`). When that fails before
    /// the start is saved (here: a stop request left over), the start is put back, so the service starts the parts.
    @Test func anApprovalChangeWhoseRestartFailsLeavesThePairStarted() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            _ = try service.store.updateRecord { $0.leadership?.serving = false; $0.stopDrain = .init(id: UUID(), keepPeerRunning: true) }
            let line = ClusterService.restartAfterApprovalChange(serving: true, serve: { service.controlLive.localServe() },
                                                                 restoreStart: { service.restoreStart() })
            #expect(line?.hasPrefix("could not start the parts again after the cluster approval changed: ") == true, "\(line ?? "nil")")
            let record = try service.store.readRecord()
            #expect(record.leadership?.serving == true, "the failed restart left the pair stopped")
            #expect(record.stopDrain == nil)
            // A pair that did not serve before the change is not started.
            #expect(ClusterService.restartAfterApprovalChange(serving: false,
                serve: { Issue.record("started a pair that did not serve"); return .success([]) },
                restoreStart: { Issue.record("put a start back that nothing cleared") }) == nil)
        }
    }

    /// A stop of the owner's that clears the start without the command lock (`ClusterService.releaseForSingleMac`:
    /// `darkbloom stop` while the pair doesn't run here and the other Mac doesn't answer, `darkbloom start --solo`) lands
    /// while a step's own stop waits for the other Mac, which never answers. The step then puts its start back: the
    /// owner's stop must hold all the same.
    @Test(arguments: ["re-plan", "approval change"])
    func anOwnersStopWithoutTheCommandLockDuringAStepsFailingStopHolds(_ step: String) throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            // The step holds the command lock, as `checkForUpdate` and `checkApproval` do around it.
            let held = try #require(ClusterControlCommandLock.acquire(seconds: 0, file: Self.commandLock(service)))
            let paths = macs.leader.paths, owner = DispatchSemaphore(value: 0)
            let released = ClusterApprovalRecorder<ClusterService.SingleMacRelease>()
            Thread.detachNewThread {
                guard owner.wait(timeout: .now() + 30) == .success else { return }
                released.append(ClusterService.releaseForSingleMac(seconds: 1, paths: paths))
            }
            let stop = Self.stop(service) {
                // This Mac's part released and its start is cleared; the other Mac is asked. Meanwhile the owner stops.
                owner.signal()
                _ = Self.waitUntil(seconds: 1) { !released.values.isEmpty }
                throw ClusterSetupFailure("the other Mac did not answer within 30 s")
            }
            if step == "re-plan" {
                var steps = Self.steps(service, stop: stop)
                Self.notAfterAFailedStop(&steps)
                _ = ClusterService.replanAfterUpdate(model: ClusterApprovalMacs.model, steps)
            } else {
                _ = ClusterService.stopForApprovalChange(serving: true, stop: stop, drained: { true },
                                                         restoreStart: { service.restoreStart() })
            }
            held.release()
            #expect(Self.waitUntil(seconds: 10) { !released.values.isEmpty }, "the owner's stop did not finish")
            #expect(released.values == [.released])
            let serving = try service.store.readRecord().leadership?.serving
            #expect(serving == false, "the \(step) put back a start the owner cleared")
        }
    }

    /// That stop waits for a cluster command holding the command lock (up to 10 minutes). It says so at once, before the
    /// wait, so `darkbloom stop` can tell the person, and a command still running at the end is told apart from a part
    /// that didn't stop: it read and wrote nothing.
    @Test func aStopForSingleMacServingSaysWhenItWaitsForARunningCommand() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            let paths = macs.leader.paths, said = ClusterApprovalRecorder<Date>()
            let held = try #require(ClusterControlCommandLock.acquire(seconds: 0, file: Self.commandLock(service)))
            let began = Date()
            let busy = ClusterService.releaseForSingleMac(seconds: 1, paths: paths, commandSeconds: 1) { said.append(Date()) }
            held.release()
            #expect(said.values.map { $0.timeIntervalSince(began) < 0.5 } == [true], "the wait was not said once, before it")
            #expect(busy == .commandStillRunning)
            #expect(try service.store.readRecord().leadership?.serving == true, "a stop that never held the lock cleared the start")
            // Nothing runs: nothing to say.
            let free = ClusterService.releaseForSingleMac(seconds: 1, paths: paths, commandSeconds: 1) { said.append(Date()) }
            #expect(free == .released)
            #expect(said.values.count == 1)
            #expect(try service.store.readRecord().leadership?.serving == false)
        }
    }

    /// Both Macs restart into an update seconds apart. While one is down, the other may take control (its lease ran out
    /// after 30 s), so a restarted leader's saved claim may be superseded, and the other Mac then refuses its stop. Such a
    /// claim is confirmed or dropped at its first lease: until the other Mac confirmed it, the leader neither sets the
    /// cluster up again for the update nor asks the coordinator about its approval (both stop the pair), as a person's
    /// command waits too (`OnboardingLive.awaitConfirmedLeadership`). The actual service loop; no paired Mac answers.
    @Test func aRestartedLeaderActsOnTheUpdateOnlyOnceTheOtherMacConfirmedItsClaim() throws {
        let coordinator = try CountingCoordinator()
        defer { coordinator.close() }
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:\(coordinator.port)/ws/provider")
        try withExtendedLifetime(macs) {
            let leader = macs.leader, follower = macs.follower
            // The saved setup pins the worker of the build before the update, not the one installed now.
            try #require(try Self.sha256(leader.worker) != macs.saved(leader).capability.runtimeBinarySHA256)
            try FileManager.default.moveItem(at: leader.pairing.directory,
                                             to: leader.home.appendingPathComponent("pairing-elsewhere", isDirectory: true))
            let service = try Self.service(macs)
            // The claim this Mac saved before its restart: it leads, and the other Mac has not confirmed it yet. Without a
            // plan order its mode is idle: nothing of the model starts here, so only the leader's own checks act.
            let claim = ClusterControlClaim(term: 1, leaderID: leader.memberID, members: [leader.memberID, follower.memberID],
                                            reason: "fixture")
            let node = ClusterControlNode(localID: leader.memberID,
                members: [.init(memberID: leader.memberID, name: "fixture", memoryBytes: 1, gpuCores: 1),
                          .init(memberID: follower.memberID, name: "fixture peer", memoryBytes: 1, gpuCores: 1)],
                claim: claim, rankOrder: nil, now: ClusterService.monotonicSeconds(), ttl: 3_600)
            try #require(node.leads && !node.leadershipConfirmed(now: ClusterService.monotonicSeconds()))
            service.lock.withLock { service.control = node }

            let stop = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let lines = ClusterApprovalRecorder<String>()
            Thread.detachNewThread {
                _ = try? service.run(stop: stop) { lines.append($0) }
                done.signal()
            }
            let wait = ClusterOnboardingUpdate.leaderWaitLine(macs: "this Mac", model: ClusterApprovalMacs.model,
                                                              thisVersion: ProviderCore.version, otherVersion: nil)
            // Twenty supervision ticks with the claim unconfirmed.
            usleep(2_000_000)
            let unconfirmed = (lines: lines.values, asked: coordinator.requests.count)
            // The other Mac accepted this Mac's lease: the claim is confirmed.
            service.lock.withLock {
                _ = service.control?.receiveAnswer(from: follower.memberID, sent: claim,
                    answer: .accepted(.init(memberID: follower.memberID, name: "fixture peer", memoryBytes: 1, gpuCores: 1)),
                    now: ClusterService.monotonicSeconds())
            }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !lines.values.contains(wait) || coordinator.requests.isEmpty { usleep(20_000) }
            stop.signal()
            #expect(done.wait(timeout: .now() + 30) == .success, "the service did not stop")
            #expect(!unconfirmed.lines.contains(wait), "an unconfirmed leader acted on the update: \(unconfirmed.lines)")
            #expect(unconfirmed.asked == 0, "an unconfirmed leader asked the coordinator for its approvals")
            #expect(lines.values.filter { $0 == wait }.count == 1, "the confirmed leader did not act on the update once: \(lines.values)")
            #expect(coordinator.requests.allSatisfy { $0.hasPrefix("GET /v1/cluster/approvals") } && !coordinator.requests.isEmpty,
                    "the confirmed leader did not ask for its approvals: \(coordinator.requests)")
        }
    }

    /// The re-plan compares the builds before it takes the command lock, so a person's stop, or a hand-over, can finish
    /// while it waits for the lock. Once it holds the lock it acts only on a start still saved and a claim still
    /// confirmed: its stop would put the start back when it failed (or `localServe` save it), starting the pair the owner
    /// stopped. The actual service loop.
    @Test(arguments: ["the owner stopped the pair", "control moved to the other Mac"])
    func anUpdateReplanThatWaitedForTheCommandLockDoesNothingAfterAStopOrAHandOver(_ meanwhile: String) throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            // A person's command holds the command lock while the re-plan compares the builds.
            let held = try #require(ClusterControlCommandLock.acquire(seconds: 0, file: Self.commandLock(service)))
            let compared = DispatchSemaphore(value: 0), replanned = ClusterApprovalRecorder<Bool>()
            var steps = Self.steps(service, stop: Self.stop(service) { throw ClusterSetupFailure("the other Mac did not answer within 30 s") })
            steps.reachMembers = { replanned.append(true); return .success([]) }
            service.updateReplan = (running: { compared.signal(); return Self.oneNewBuild(macs) }, steps: steps)
            try Self.confirmedLeader(service, macs)
            let loop = Self.run(service)
            let began = compared.wait(timeout: .now() + 20) == .success
            if meanwhile == "the owner stopped the pair" {
                _ = try service.store.updateRecord { $0.leadership?.serving = false }
            } else {
                service.lock.withLock { service.control = Self.node(macs, leader: macs.follower.memberID, term: 2) }
            }
            held.release()
            usleep(2_000_000)
            let lines = loop.stop()
            #expect(began, "the re-plan never compared the builds: \(lines)")
            #expect(replanned.values.isEmpty, "the re-plan went on after \(meanwhile)")
            #expect(!lines.contains { $0.hasPrefix("Darkbloom changed on both Macs: setting the cluster up again") }, "\(lines)")
            let serving = try service.store.readRecord().leadership?.serving
            #expect(serving == (meanwhile != "the owner stopped the pair"), "\(meanwhile): the start is \(String(describing: serving))")
        }
    }

    /// The memory re-plan (`noteMemoryRefusal`: this Mac's part refused at load twice) comes due when a part ends, so
    /// also right after the owner stops the pair with `darkbloom stop`, and it waits for the command lock that stop
    /// holds. Once it holds the lock it acts only on a start still saved and a claim still confirmed: its `localServe`
    /// would save the start again, starting the pair the owner stopped.
    @Test(arguments: ["the owner stopped the pair", "control moved to the other Mac"])
    func aMemoryReplanRightAfterAStopOrAHandOverDoesNothing(_ meanwhile: String) throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            try Self.confirmedLeader(service, macs)
            let replanned = ClusterApprovalRecorder<Bool>(), lines = ClusterApprovalRecorder<String>()
            let offered = ClusterOnboardingModelChoice(title: ClusterApprovalMacs.model, lines: ["fixture plan"], blocker: nil,
                                                       modelID: ClusterApprovalMacs.model)
            // `serve` stands in for `OnboardingLive.localServe`'s first write.
            service.memoryReplan = .init(reachMembers: { replanned.append(true); return .success([]) },
                planModels: { .success([offered]) }, adopt: { _ in .success([]) },
                serve: { _ = try? service.store.updateRecord { $0.leadership?.serving = true }; return .success([]) })
            // The owner's command holds the command lock as the re-plan comes due.
            let held = try #require(ClusterControlCommandLock.acquire(seconds: 0, file: Self.commandLock(service)))
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                service.replanForMemory(model: ClusterApprovalMacs.model) { lines.append($0) }
                done.signal()
            }
            if meanwhile == "the owner stopped the pair" {
                guard case .success = Self.stop(service, otherMac: {})() else { Issue.record("the owner's stop failed"); return }
            } else {
                service.lock.withLock { service.control = Self.node(macs, leader: macs.follower.memberID, term: 2) }
            }
            held.release()
            #expect(done.wait(timeout: .now() + 20) == .success, "the re-plan did not end")
            #expect(replanned.values.isEmpty, "the memory re-plan went on after \(meanwhile): \(lines.values)")
            let serving = try service.store.readRecord().leadership?.serving
            #expect(serving == (meanwhile != "the owner stopped the pair"), "\(meanwhile): the start is \(String(describing: serving))")
        }
    }

    /// The re-plan after an update in the actual service loop, its stop failing at the other Mac (B6): the pair stays
    /// started, and the re-plan is tried again 10 minutes later (`ClusterOnboardingUpdate.retryAfterFailureSeconds`), not
    /// at every tick. The test moves the next check instead of waiting for it.
    @Test func anUpdateReplanWhoseStopFailsInTheServiceLoopIsTriedAgainTenMinutesLater() throws {
        let (macs, service) = try leader()
        try withExtendedLifetime(macs) {
            let replans = ClusterApprovalRecorder<Bool>()
            var steps = Self.steps(service, stop: Self.stop(service) { throw ClusterSetupFailure("the other Mac did not answer within 30 s") })
            Self.notAfterAFailedStop(&steps)
            steps.reachMembers = { replans.append(true); return .success([]) }
            service.updateReplan = (running: { Self.oneNewBuild(macs) }, steps: steps)
            try Self.confirmedLeader(service, macs)
            let loop = Self.run(service)
            let failed = "could not set the cluster up again after the update: "
            let said = Self.waitUntil(seconds: 20) { loop.lines.values.contains { $0.hasPrefix(failed) } }
            // A tick is 0.1 s: a re-plan tried again at the next tick would run many times in these 2 s.
            usleep(2_000_000)
            let tries = replans.values.count
            let due = service.lock.withLock { service.nextUpdateCheck }.timeIntervalSinceNow
            let record = try service.store.readRecord()
            service.lock.withLock { service.nextUpdateCheck = .distantPast }
            let again = Self.waitUntil(seconds: 10) { replans.values.count >= 2 }
            let lines = loop.stop()
            #expect(said, "the re-plan did not fail as its stop did: \(lines)")
            #expect(tries == 1, "the re-plan ran \(tries) times within 2 s of its failure")
            #expect(due > ClusterOnboardingUpdate.retryAfterFailureSeconds - 10, "the next re-plan is due in \(due) s")
            #expect(record.leadership?.serving == true, "the failed stop left the pair stopped")
            #expect(record.stopDrain == nil)
            #expect(again, "the re-plan was not tried again at its next check")
        }
    }

    /// While the other Mac doesn't answer, every change of the cluster approval fails at it (each one sends to it), so
    /// none that stops a serving pair is begun: the leader would otherwise stop its own part at every check, a minute
    /// apart, and start it again. It still asks the coordinator at every check. The actual service loop; the test moves
    /// the next check instead of waiting a minute for it.
    @Test func anApprovalChangeIsNotBegunOnAServingPairWhileTheOtherMacDoesNotAnswer() throws {
        let coordinator = try CountingCoordinator()
        defer { coordinator.close() }
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:\(coordinator.port)/ws/provider")
        try withExtendedLifetime(macs) {
            let (service, parts) = try Self.approvalLeader(macs, serving: true)
            let loop = Self.run(service)
            let asked = Self.waitUntil(seconds: 20) { !coordinator.requests.isEmpty }
            let askedAt = Date()
            let ready = Self.waitUntil(seconds: 20) { Self.count(parts, "member", ".ready") > 0 }
            // A change begun would stop this Mac's part within a second or two: it ends at once when asked.
            usleep(4_000_000)
            let first = coordinator.requests.count
            let due = service.lock.withLock { service.nextApprovalCheck }.timeIntervalSince(askedAt)
            service.lock.withLock { service.nextApprovalCheck = .distantPast }
            let again = Self.waitUntil(seconds: 10) { coordinator.requests.count >= 2 }
            usleep(3_000_000)
            let record = try service.store.readRecord()
            // Read before the service stops: it stops its part then.
            let stopped = Self.count(parts, "member", ".term")
            let lines = loop.stop()
            #expect(asked && ready, "the coordinator was not asked, or the leader's part did not start: \(lines)")
            #expect(first == 1, "the coordinator was asked \(first) times within the first check's minute")
            #expect(due > ClusterOnboardingUpdate.checkEverySeconds - 10, "the next approval check is due \(due) s after the first")
            #expect(again, "the coordinator was not asked again at the next check")
            #expect(!lines.contains { $0.hasPrefix("could not stop the parts to change the cluster approval") }, "\(lines)")
            #expect(stopped == 0, "this Mac's part was stopped for an approval change")
            #expect(record.leadership?.serving == true)
        }
    }

    /// The approval check asks the coordinator before it takes the command lock, so a hand-over can finish while it waits
    /// for the lock. Once it holds the lock it changes nothing unless this Mac still leads on a confirmed claim. The pair
    /// here does not serve, so a change would go ahead with nothing to stop. The actual service loop.
    @Test func anApprovalChangeWhoseClaimMovedWhileItWaitedForTheCommandLockChangesNothing() throws {
        let coordinator = try CountingCoordinator()
        defer { coordinator.close() }
        let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:\(coordinator.port)/ws/provider")
        try withExtendedLifetime(macs) {
            let (service, _) = try Self.approvalLeader(macs, serving: false)
            // A person's command holds the command lock while the check asks the coordinator.
            let held = try #require(ClusterControlCommandLock.acquire(seconds: 0, file: Self.commandLock(service)))
            let loop = Self.run(service)
            let asked = Self.waitUntil(seconds: 20) { !coordinator.requests.isEmpty }
            service.lock.withLock { service.control = Self.node(macs, leader: macs.follower.memberID, term: 2) }
            held.release()
            usleep(2_000_000)
            let lines = loop.stop()
            #expect(asked, "the coordinator was not asked: \(lines)")
            #expect(!lines.contains { $0.hasPrefix("The pair stays registered for now") }, "a check whose claim moved changed the approval: \(lines)")
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A coordinator without pair approvals on this Mac's loopback: every request is answered 404 and its request line kept.
private final class CountingCoordinator: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let seen = ClusterApprovalRecorder<String>()
    private let done = DispatchSemaphore(value: 0)
    var requests: [String] { seen.values }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClusterConfigurationError.invalid("no socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { Darwin.close(fd); throw ClusterConfigurationError.invalid("no listener") }
        var assigned = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: assigned.sin_port)
        let (seen, done) = (self.seen, self.done)
        Thread.detachNewThread {
            defer { done.signal() }
            while true {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                var head = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while head.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let count = Darwin.read(connection, &buffer, buffer.count)
                    guard count > 0 else { break }
                    head.append(contentsOf: buffer.prefix(count))
                }
                seen.append(String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? "")
                let answer = Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                _ = answer.withUnsafeBytes { Darwin.write(connection, $0.baseAddress, $0.count) }
                Darwin.close(connection)
            }
        }
    }

    func close() {
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        _ = done.wait(timeout: .now() + 10)
    }
}
