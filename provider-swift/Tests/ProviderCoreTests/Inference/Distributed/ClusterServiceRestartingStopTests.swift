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
            default: steps.planModels = { .success([offered]) }; steps.serve = { .failure(refused) }
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
