import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@_spi(OwnerService) import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote

// Two processes over the link control channel (loopback), model-free: this
// process is the leader (rank 0 through its own stand-in owner, rank 1 through
// `ClusterLinkWorkerEndpoint`), the follower process serves rank 1 through
// `ClusterLinkWorkerServer`. No SSH anywhere. A loopback pass is not a
// hardware pass.
//
//   link-pair-check FOLLOWER OWNER WORKER

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ClusterOwnerStateError.invalid(message) }
}
func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }; throw ClusterOwnerStateError.invalid("Expected rejection")
}
func directory() throws -> URL {
    let value = URL(fileURLWithPath: "/private/tmp/cluster-link-worker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return value
}
func journalBytes(_ dir: URL) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("native-device.lease").path)[.size]) as? NSNumber)?.uint64Value ?? 0
}
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func wait(seconds: Double, until condition: () -> Bool) -> Bool {
    let end = now() + UInt64(seconds * 1_000_000_000)
    while !condition() && now() < end { Thread.sleep(forTimeInterval: 0.01) }
    return condition()
}

/// One leader listener on loopback and one follower process dialling it.
final class LinkHarness: @unchecked Sendable {
    let router = ClusterLinkWorkerRouter()
    let listener: ClusterLinkControlListener
    let peer: ClusterLinkControlPeer
    let process = Process()
    private let input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var lines: [String] = []
    let followerDirectory: URL
    let reader = DispatchGroup()

    init(follower: URL, owner: URL, worker: String, profile: String, behavior: String) throws {
        var secret = Data(count: 32)
        guard secret.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
            throw ClusterOwnerStateError.invalid("No random secret")
        }
        let linkEpoch = UUID(), edgeID = UUID()
        let key = try ClusterLinkControlKey.qualification(secret: secret, epoch: linkEpoch, edgeID: edgeID)
        let loopback = ClusterLinkIPv4Address("127.0.0.1")!
        let edge = try ClusterLinkControlEdge(edgeID: edgeID, epoch: linkEpoch, key: key, peerAddress: nil)
        let router = self.router
        listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", localAddress: loopback, port: 0,
            policy: .loopbackForTests, edges: [edge])) { event, _ in router.handle(event) }
        let port = try listener.start()
        peer = listener.peer(for: edgeID)!
        followerDirectory = try directory()
        process.executableURL = follower
        process.arguments = [String(port), linkEpoch.uuidString, edgeID.uuidString, owner.path, worker, followerDirectory.path, profile, behavior]
        process.environment = [:]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data((secret.map { String(format: "%02x", $0) }.joined() + "\n").utf8))
        reader.enter()
        let handle = output.fileHandleForReading
        DispatchQueue.global().async {
            defer { self.reader.leave() }
            var buffered = Data()
            while true {
                let bytes = handle.availableData
                if bytes.isEmpty { break }
                buffered.append(bytes)
                while let index = buffered.firstIndex(of: 10) {
                    let line = String(decoding: buffered.prefix(upTo: index), as: UTF8.self)
                    buffered.removeSubrange(...index)
                    self.lock.withLock { self.lines.append(line) }
                }
            }
        }
        guard peer.waitUntilConnected(timeout: .seconds(10)) else { throw ClusterOwnerStateError.invalid("Follower never connected") }
    }

    var reports: [String] { lock.withLock { lines } }
    func sawReport(_ prefix: String, seconds: Double) -> Bool { wait(seconds: seconds) { reports.contains { $0.hasPrefix(prefix) } } }

    func linkEndpoint(relay: (any ClusterOwnerBootstrapExchange)?, lifetimeNanoseconds: UInt64 = 15_000_000_000) throws -> ClusterLinkWorkerEndpoint {
        try ClusterLinkWorkerEndpoint(transport: ClusterLinkPeerWorkerTransport(peer: peer), clusterID: "cpu-test",
            expectedIdentity: fixtureIdentity, profile: fixtureProfile, rank: 1, executionPlanSHA256: fixturePlan,
            lifetimeDeadlineUptimeNanoseconds: now() + lifetimeNanoseconds, bootstrapRelay: relay, router: router)
    }

    /// Closes the follower's standard input and waits for it to end itself.
    func finish(seconds: Double = 45) throws -> Int32 {
        try? input.fileHandleForWriting.close()
        guard wait(seconds: seconds, until: { !process.isRunning }) else {
            process.terminate(); throw ClusterOwnerStateError.invalid("Follower did not end after its input closed: \(reports)")
        }
        process.waitUntilExit(); reader.wait()
        listener.stop()
        let status = process.terminationStatus
        try? FileManager.default.removeItem(at: followerDirectory)
        return status
    }
    func followerJournalBytes() -> UInt64 { journalBytes(followerDirectory) }
}

func localEndpoint(_ owner: URL, _ worker: String, _ dir: URL, behavior: String, relay: ClusterOwnerBootstrapRelay?,
                   lifetimeNanoseconds: UInt64 = 15_000_000_000) throws -> ClusterRemoteWorkerEndpoint {
    try .init(transport: .init(executable: owner, arguments: [worker, dir.path, "0", behavior], environment: [:]),
        clusterID: "cpu-test", expectedIdentity: fixtureIdentity, profile: fixtureProfile, rank: 0,
        executionPlanSHA256: fixturePlan, lifetimeDeadlineUptimeNanoseconds: now() + lifetimeNanoseconds, bootstrapRelay: relay)
}

func runRequest(_ pair: ClusterWorkerPair) throws {
    let request = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
        promptTokenIDs: [1, 2], stopTokenIDs: [], outputCount: 2, chunkSize: 1,
        deadlineUptimeNanoseconds: now() + 8_000_000_000, capacityLimitBytes: 1800))
    try request.start { _ in true }
    try require(wait(seconds: 6) { request.isRetired }, "Paired request over the link did not retire")
    request.releaseResources()
}

func shutdown(_ pair: ClusterWorkerPair, seconds: Int = 8, _ context: @autoclosure () -> String = "") throws {
    let done = DispatchSemaphore(value: 0)
    Task.detached { await pair.shutdown(); done.signal() }
    try require(done.wait(timeout: .now() + .seconds(seconds)) == .success, "Pair did not shut down \(context())")
}

@main struct LinkWorkerPairCheck {
    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let follower = URL(fileURLWithPath: CommandLine.arguments[1]), owner = URL(fileURLWithPath: CommandLine.arguments[2])
        let worker = CommandLine.arguments[3]
        var passed = 0
        try codec(); passed += 1; print("PASS codec: no host uptime crosses, closed fields")
        try served(follower, owner, worker, profile: "prelude"); passed += 1
        try served(follower, owner, worker, profile: "mesh2"); passed += 1
        try served(follower, owner, worker, profile: "none"); passed += 1
        try leaseEnforcedByTheFollower(follower, owner, worker); passed += 1
        try leaseLapsesOverALiveLink(follower, owner, worker); passed += 1
        try followerWorkerLost(follower, owner, worker); passed += 1
        try followerProcessKilled(follower, owner, worker); passed += 1
        try refusedOpen(follower, owner, worker); passed += 1
        print("link-worker: \(passed) groups passed (two processes over loopback; not a hardware pass)")
    }

    static func codec() throws {
        let epoch = fixtureIdentity.membershipEpoch, session = UUID(), request = UUID()
        let reserve = ClusterWorkerCommand.reserve(.init(profileID: "cpu", promptTokenIDs: [7, 8, 9], stopTokenIDs: [2], outputCount: 2,
            chunkSize: 1, deadlineUptimeNanoseconds: 9_000, capacityLimitBytes: 100))
        let wire = try ClusterLinkWorkerWire.command(reserve, requestID: request, epoch: epoch, session: session, sequence: 3,
            now: 8_000, deliveryDeadline: 8_200)
        let bytes = try wire.encoded()
        let text = String(decoding: bytes, as: UTF8.self)
        try require(!text.contains("9000") && wire.remainingNanoseconds == 1_000 && wire.deliveryRemainingNanoseconds == 200,
            "A host uptime crossed the link")
        let local = try ClusterLinkWorkerWire.decode(bytes).localCommand(now: 50_000)
        guard case .reserve(let r) = local.command else { throw ClusterOwnerStateError.invalid("Reserve lost") }
        try require(r.deadlineUptimeNanoseconds == 51_000 && local.deliveryDeadline == 50_200 && local.requestID == request
            && r.promptTokenIDs == [7, 8, 9], "Reservation not rebased on the receiver's clock")
        try rejects { _ = try ClusterLinkWorkerWire.command(reserve, requestID: request, epoch: epoch, session: session, sequence: 3,
            now: 9_500, deliveryDeadline: 9_600) }
        // Closed fields per kind.
        var renew = ClusterLinkWorkerWire(kind: .renew, epoch: epoch, session: session, sequence: 1)
        try rejects { _ = try renew.encoded() }
        renew.remainingNanoseconds = ClusterWorkerLease.ttlNanoseconds
        _ = try ClusterLinkWorkerWire.decode(try renew.encoded())
        renew.worker = Data([1]); try rejects { _ = try renew.encoded() }
        var open = ClusterLinkWorkerWire(kind: .open, epoch: epoch, session: session, sequence: 0)
        open.clusterID = "cpu-test"; open.rank = 1; open.planSHA256 = fixturePlan
        open.remainingNanoseconds = ClusterWorkerLease.maximumNanoseconds + 1
        try rejects { _ = try open.encoded() }
        open.remainingNanoseconds = 1_000_000_000; open.bootstrapProfile = "unknown"
        try rejects { _ = try open.encoded() }
        open.bootstrapProfile = ClusterOwnerBootstrapProfile.nativeKeyPreludeMesh2.rawValue
        _ = try open.encoded()
        try rejects { _ = try ClusterLinkWorkerWire.decode(Data("{\"version\":2}".utf8)) }
        var round = ClusterLinkWorkerWire(kind: .bootstrapRound, epoch: epoch, session: session, sequence: 2)
        round.bootstrapSequence = 7; round.bootstrapBytes = Data([0]); round.ownerIncarnation = UUID(); round.ownerLease = UUID()
        try rejects { _ = try round.encoded() }
    }

    /// One session served through the follower process: bootstrap over the
    /// link (when a profile is selected), a request, idle past three lease
    /// renewals, a second request, shutdown, and both proofs.
    static func served(_ follower: URL, _ owner: URL, _ worker: String, profile: String) throws {
        let behavior = profile == "prelude" ? "bootstrap-prelude" : profile == "mesh2" ? "bootstrap-normal" : "normal"
        let harness = try LinkHarness(follower: follower, owner: owner, worker: worker, profile: profile, behavior: behavior)
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let relay: ClusterOwnerBootstrapRelay?
        switch profile {
        case "prelude": relay = try .init(identity: fixtureIdentity, executionPlanSHA256: fixturePlan, profile: .nativeKeyPreludeMesh2,
            deadlineUptimeNanoseconds: now() + 10_000_000_000, nativeStarts: try fixtureNativeStarts())
        case "mesh2": relay = try .init(identity: fixtureIdentity, executionPlanSHA256: fixturePlan, deadlineUptimeNanoseconds: now() + 10_000_000_000)
        default: relay = nil
        }
        let first = try localEndpoint(owner, worker, dir, behavior: behavior, relay: relay)
        let second = try harness.linkEndpoint(relay: relay)
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: now() + 10_000_000_000)
        try runRequest(pair)
        // The first grant is 15 s: without renewals on the link the follower
        // would fence its owner before the second request.
        Thread.sleep(forTimeInterval: 17)
        try require(second.renewals >= 3 && second.readiness != nil, "Lease renewals over the link did not keep the follower (\(second.renewals))")
        try runRequest(pair)
        try shutdown(pair, seconds: 8, "rank0 cleanup \(first.nativeCleanupObserved) rank1 cleanup \(second.nativeCleanupObserved) follower \(harness.reports)")
        try require(first.nativeCleanupObserved && second.nativeCleanupObserved, "Missing cleanup proof (\(profile))")
        try require(second.waitForOwnerReleased(deadline: now() + 10_000_000_000), "Follower's release proof missing (\(profile)): \(harness.reports)")
        try require(first.waitForOwnerReleased(deadline: now() + 10_000_000_000), "Leader's local owner release missing")
        try require(harness.followerJournalBytes() == 0 && journalBytes(dir) == 0, "A device journal was left (\(profile))")
        let status = try harness.finish()
        try require(status == 0 && harness.reports.contains("released true") && !harness.reports.contains(where: { $0.hasPrefix("fenced leader lease") }),
            "Follower reports differ (\(profile)): \(harness.reports)")
        print("PASS served over the link, profile \(profile): 2 requests, \(second.renewals) renewals, cleanup and release proven")
    }

    /// The leader goes away (its listener stops; no fence is sent): the
    /// follower fences its own owner when its link to the leader does not
    /// resume in the edge's own re-dial time (5 s here, before the 8 s grant
    /// it would otherwise fence at), and still proves cleanup and release on
    /// its side. The leader has no proof while the link is down: rank 1 stays
    /// unresolved there. The lease alone is covered by the next group.
    static func leaseEnforcedByTheFollower(_ follower: URL, _ owner: URL, _ worker: String) throws {
        let harness = try LinkHarness(follower: follower, owner: owner, worker: worker, profile: "none", behavior: "normal")
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try localEndpoint(owner, worker, dir, behavior: "normal", relay: nil)
        let second = try harness.linkEndpoint(relay: nil, lifetimeNanoseconds: 8_000_000_000)
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: now() + 6_000_000_000)
        try require(pair.readiness != nil, "Pair not ready")
        let silent = now()
        harness.listener.stop()
        try require(harness.sawReport("fenced leader link lost", seconds: 12), "Follower did not fence when its leader's link was lost: \(harness.reports)")
        try require(harness.sawReport("released true", seconds: 20), "Follower did not release after its own fence: \(harness.reports)")
        let elapsed = Double(now() - silent) / 1e9
        try require(harness.followerJournalBytes() == 0, "Follower journal left after lease expiry")
        try require(!second.nativeCleanupObserved, "The leader claimed rank 1's cleanup without a link")
        first.requestNativeCleanup()
        try require(first.waitForOwnerReleased(deadline: now() + 10_000_000_000), "Leader's local owner release missing")
        let status = try harness.finish()
        try require(status == 0, "Follower exit \(status): \(harness.reports)")
        withExtendedLifetime(pair) {}
        print(String(format: "PASS a follower whose leader went away fenced on the lost link and released %.1f s after (grant 8 s)", elapsed))
    }

    /// The leader stops renewing while the link stays up: the follower fences
    /// at the end of its grant and the leader receives cleanup and release.
    static func leaseLapsesOverALiveLink(_ follower: URL, _ owner: URL, _ worker: String) throws {
        let harness = try LinkHarness(follower: follower, owner: owner, worker: worker, profile: "none", behavior: "normal")
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try localEndpoint(owner, worker, dir, behavior: "normal", relay: nil)
        let second = try harness.linkEndpoint(relay: nil, lifetimeNanoseconds: 8_000_000_000)
        second.suspendRenewalsForTesting()
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: now() + 6_000_000_000)
        try runRequest(pair)
        try require(wait(seconds: 14) { second.nativeCleanupObserved }, "No cleanup after the lease lapsed: \(harness.reports)")
        try require(pair.readiness == nil && harness.reports.contains("fenced leader lease expired"), "Lapse not enforced by the follower: \(harness.reports)")
        try shutdown(pair, seconds: 20, "rank0 \(first.nativeCleanupObserved) follower \(harness.reports)")
        try require(second.waitForOwnerReleased(deadline: now() + 10_000_000_000), "Follower release missing after the lapse")
        try require(harness.followerJournalBytes() == 0, "Follower journal left after the lapse")
        let status = try harness.finish()
        try require(status == 0, "Follower exit \(status)")
        print("PASS lease lapse over a live link: follower fenced at its grant, leader received cleanup and release")
    }

    /// The follower's worker ends mid-request: the leader's request fails, the
    /// pair is invalid, and the follower's cleanup and release still arrive.
    static func followerWorkerLost(_ follower: URL, _ owner: URL, _ worker: String) throws {
        let harness = try LinkHarness(follower: follower, owner: owner, worker: worker, profile: "none", behavior: "exit")
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try localEndpoint(owner, worker, dir, behavior: "normal", relay: nil)
        let second = try harness.linkEndpoint(relay: nil)
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: now() + 10_000_000_000)
        let request = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
            promptTokenIDs: [1, 2], stopTokenIDs: [], outputCount: 2, chunkSize: 1,
            deadlineUptimeNanoseconds: now() + 8_000_000_000, capacityLimitBytes: 1800))
        var failed = false
        do { try request.start { _ in true } } catch { failed = true }
        _ = wait(seconds: 8) { request.isRetired || pair.readiness == nil }
        try require(failed || pair.readiness == nil, "Pair stayed ready after the follower's worker ended")
        try require(wait(seconds: 8) { second.nativeCleanupObserved }, "No cleanup proof from the follower: \(harness.reports)")
        try shutdown(pair, seconds: 20)
        try require(second.waitForOwnerReleased(deadline: now() + 10_000_000_000), "Follower release missing after its worker ended: \(harness.reports)")
        try require(harness.followerJournalBytes() == 0, "Follower journal left after its worker ended")
        let status = try harness.finish()
        try require(status == 0, "Follower exit \(status)")
        print("PASS follower worker lost mid-request: pair invalid, cleanup and release proven over the link")
    }

    /// The follower's PROCESS is SIGKILLed mid-request (hardware finding F3):
    /// nothing can come from it any more, no fence, no cleanup, no release.
    /// Both ranks stall like ranks inside a collective whose peer has gone.
    /// The leader states the loss within the link's own re-dial window (well
    /// inside the rank lease), the request in flight fails at once, the pair
    /// shuts down without waiting for proofs that cannot arrive, rank 1 is
    /// never claimed as cleaned up or released, and the follower Mac's own
    /// owner still ends its rank and clears its journal.
    static func followerProcessKilled(_ follower: URL, _ owner: URL, _ worker: String) throws {
        let harness = try LinkHarness(follower: follower, owner: owner, worker: worker, profile: "none", behavior: "stall")
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try localEndpoint(owner, worker, dir, behavior: "stall", relay: nil, lifetimeNanoseconds: 60_000_000_000)
        let second = try harness.linkEndpoint(relay: nil, lifetimeNanoseconds: 60_000_000_000)
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: now() + 10_000_000_000)
        let request = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
            promptTokenIDs: [1, 2], stopTokenIDs: [], outputCount: 2, chunkSize: 1,
            deadlineUptimeNanoseconds: now() + 50_000_000_000, capacityLimitBytes: 1800))
        try request.start { _ in true }
        Thread.sleep(forTimeInterval: 0.5)
        try require(!request.isRetired && pair.readiness != nil, "The stalled request should still be in flight")
        let killed = now()
        try require(Darwin.kill(harness.process.processIdentifier, SIGKILL) == 0, "SIGKILL to the follower failed")
        // Stated within the lease TTL (30 s); the window is 5 s for a closed link.
        let lost = wait(seconds: 12) { pair.readiness == nil && second.readiness == nil }
        let stated = Double(now() - killed) / 1e9
        try require(lost, "The leader still treats a killed follower as ready \(stated) s later")
        try require(wait(seconds: 10) { request.isRetired }, "The request in flight did not end after the follower was lost")
        let retired = Double(now() - killed) / 1e9
        try shutdown(pair, seconds: 15, "after a killed follower: rank0 \(first.nativeCleanupObserved)")
        let begin = now()
        try require(!second.waitForOwnerReleased(deadline: now() + 60_000_000_000) && now() - begin < 2_000_000_000,
            "The wait for a killed follower's release did not end at once (or claimed it)")
        try require(!second.nativeCleanupObserved, "The leader claimed rank 1's cleanup with no proof")
        try require(first.waitForOwnerReleased(deadline: now() + 10_000_000_000), "Leader's local owner release missing")
        try require(journalBytes(dir) == 0, "Leader journal left")
        // The follower Mac's own owner (orphaned by the kill) ends its rank and clears its journal.
        try require(wait(seconds: 45) { harness.followerJournalBytes() == 0 }, "The follower's owner left its journal after its member was killed")
        _ = try? harness.finish()
        print(String(format: "PASS follower process killed mid-request: loss stated %.1f s after, request ended %.1f s after, pair shut down, rank 1 unproven, follower journal cleared", stated, retired))
    }

    /// A follower whose own selection differs refuses the open; nothing runs.
    static func refusedOpen(_ follower: URL, _ owner: URL, _ worker: String) throws {
        let harness = try LinkHarness(follower: follower, owner: owner, worker: worker, profile: "mesh2", behavior: "bootstrap-normal")
        let relay = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan, profile: .nativeKeyPreludeMesh2,
            deadlineUptimeNanoseconds: now() + 5_000_000_000, nativeStarts: try fixtureNativeStarts())
        let second = try harness.linkEndpoint(relay: relay)
        try require(wait(seconds: 5) { second.refusalReason != nil }, "Open with another profile was not refused")
        try require(second.nativeCleanupObserved && second.waitForOwnerReleased(deadline: now() + 1_000_000_000) && second.readiness == nil,
            "A refused open left something unproven")
        let status = try harness.finish()
        try require(status == 0 && harness.reports.contains(where: { $0.hasPrefix("refused bootstrap profile") }), "Refusal not reported: \(harness.reports)")
        print("PASS open with another bootstrap profile refused by the follower; nothing launched")
    }
}
