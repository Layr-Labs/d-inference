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

    func linkEndpoint(relay: (any ClusterOwnerBootstrapExchange)?, lifetimeNanoseconds: UInt64 = 15_000_000_000,
                      retirementAllowanceNanoseconds: UInt64 = ClusterLinkWorkerEndpoint.retirementAllowanceNanoseconds) throws -> ClusterLinkWorkerEndpoint {
        try ClusterLinkWorkerEndpoint(transport: ClusterLinkPeerWorkerTransport(peer: peer), clusterID: "cpu-test",
            expectedIdentity: fixtureIdentity, profile: fixtureProfile, rank: 1, executionPlanSHA256: fixturePlan,
            lifetimeDeadlineUptimeNanoseconds: now() + lifetimeNanoseconds, bootstrapRelay: relay,
            retirementAllowanceNanoseconds: retirementAllowanceNanoseconds, router: router)
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
        try codec(); passed += 1; print("PASS codec: no host uptime crosses, a sampled reservation keeps its sampling, closed fields")
        try served(follower, owner, worker, profile: "prelude"); passed += 1
        try served(follower, owner, worker, profile: "mesh2"); passed += 1
        try served(follower, owner, worker, profile: "none"); passed += 1
        try leaseEnforcedByTheFollower(follower, owner, worker); passed += 1
        try leaseLapsesOverALiveLink(follower, owner, worker); passed += 1
        try followerWorkerLost(follower, owner, worker); passed += 1
        try refusedOpen(follower, owner, worker); passed += 1
        try fenceNamesItsCause(follower, owner, worker); passed += 1
        try proofCeilingEndsTheWait(follower, owner, worker); passed += 1
        try followerOwnerEndNamed(follower, owner, worker); passed += 1
        print("link-worker: \(passed) groups passed (two processes over loopback; not a hardware pass)")
    }

    /// A fence names its cause (S24): the follower's report, and so its
    /// incident, carries the leader's reason; the proofs still come back over
    /// the live link and the leader's waits end with them.
    static func fenceNamesItsCause(_ follower: URL, _ owner: URL, _ worker: String) throws {
        let harness = try LinkHarness(follower: follower, owner: owner, worker: worker, profile: "none", behavior: "normal")
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try localEndpoint(owner, worker, dir, behavior: "normal", relay: nil)
        let second = try harness.linkEndpoint(relay: nil)
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: now() + 10_000_000_000)
        try runRequest(pair)
        let cause = "request 1c3269d9 failed on the pair: Rank 0 reported failure: runtimeError"
        second.requestNativeCleanup(reason: cause)
        try require(harness.sawReport("fenced leader fenced: " + cause, seconds: 10), "The follower was not told why it was fenced: \(harness.reports)")
        let began = now()
        try require(second.waitForOwnerReleased(deadline: now() + 15_000_000_000) && second.nativeCleanupObserved,
            "The follower's proofs did not reach the leader after a fence: \(harness.reports) \(second.diagnosticSummary)")
        let elapsed = Double(now() - began) / 1e9
        first.requestNativeCleanup(reason: cause)
        try require(first.waitForOwnerReleased(deadline: now() + 10_000_000_000), "Leader's local owner release missing")
        try shutdown(pair, seconds: 8)
        let status = try harness.finish()
        try require(status == 0 && harness.reports.contains("released true"), "Follower reports differ: \(harness.reports)")
        print(String(format: "PASS a fence names its cause on the follower; proofs back %.1f s after the fence", elapsed))
    }

    /// After a fence the leader's waits on the follower end by themselves at
    /// the follower's proof ceiling (its last lease plus the retirement
    /// allowance) when no proof can arrive, here with the link down. Nothing
    /// is claimed: cleanup and release stay unobserved and the endpoint says why.
    static func proofCeilingEndsTheWait(_ follower: URL, _ owner: URL, _ worker: String) throws {
        let harness = try LinkHarness(follower: follower, owner: owner, worker: worker, profile: "none", behavior: "normal")
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try localEndpoint(owner, worker, dir, behavior: "normal", relay: nil)
        let second = try harness.linkEndpoint(relay: nil, lifetimeNanoseconds: 3_000_000_000, retirementAllowanceNanoseconds: 1_000_000_000)
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: now() + 6_000_000_000)
        try require(pair.readiness != nil, "Pair not ready")
        harness.listener.stop()
        second.requestNativeCleanup(reason: "check: the leader fences with the link down")
        let began = now()
        let proven = second.waitForOwnerReleased(deadline: now() + 30_000_000_000)
        let elapsed = Double(now() - began) / 1e9
        try require(!proven && !second.nativeCleanupObserved && !second.ownerDeviceLeaseReleasedObserved, "A wait that ended without a proof claimed one")
        try require(elapsed < 10, String(format: "The wait outlived the follower's proof ceiling: %.1f s", elapsed))
        try require(second.diagnosticSummary.contains("proof ceiling passed") && second.diagnosticSummary.contains("check: the leader fences"),
            "The endpoint does not say why: \(second.diagnosticSummary)")
        first.requestNativeCleanup()
        try require(first.waitForOwnerReleased(deadline: now() + 10_000_000_000), "Leader's local owner release missing")
        try shutdown(pair, seconds: 8)
        let status = try harness.finish()
        try require(status == 0, "Follower exit \(status): \(harness.reports)")
        print(String(format: "PASS the proof ceiling ends the leader's wait with the link down: %.1f s (grant 3 s, allowance 1 s)", elapsed))
    }

    /// The follower's owner refuses its launch (its memory gate, say) and
    /// exits with status 1: the follower's report and the leader's endpoint
    /// both name how it ended and the owner's own last line (S24), not only
    /// "follower endpoint closed".
    static func followerOwnerEndNamed(_ follower: URL, _ owner: URL, _ worker: String) throws {
        let harness = try LinkHarness(follower: follower, owner: owner, worker: worker, profile: "none", behavior: "refuse-launch+normal")
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try localEndpoint(owner, worker, dir, behavior: "normal", relay: nil)
        let second = try harness.linkEndpoint(relay: nil)
        var started = true
        do { _ = try ClusterWorkerPair(workers: [first, second], startupDeadline: now() + 6_000_000_000) } catch { started = false }
        try require(!started, "A pair formed with a follower whose owner refused its launch")
        first.requestNativeCleanup()
        let named = "its owner exited with status 1: fixture owner: the memory gate refused this load"
        try require(wait(seconds: 10) { harness.reports.contains { $0.contains("fenced follower endpoint closed: " + named) } },
            "The follower's report does not name its owner's end: \(harness.reports)")
        try require(wait(seconds: 10) { second.followerReport?.contains(named) == true },
            "The leader was not told how the follower's owner ended: \(second.followerReport ?? "nothing") / \(second.diagnosticSummary)")
        try require(second.followerReport?.contains("\u{1b}") == false, "A control character crossed the link")
        try require(second.diagnosticSummary.contains("the follower said: " + named), "The leader's summary omits it: \(second.diagnosticSummary)")
        _ = second.waitForOwnerReleased(deadline: now() + 10_000_000_000)
        let status = try harness.finish()
        try require(status == 0, "Follower exit \(status)")
        print("PASS a follower owner that refuses its launch is named on both Macs: \(named)")
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
        // A sampled reservation reaches the follower's rank with its sampling:
        // both ranks get it (the selecting rank draws with it). Dropped on the
        // link, the follower ran the request greedy and the ranks disagreed at
        // the first token, which ended the pair (RC blocker: any sampled request).
        let sampling = ClusterWorkerSampling(temperature: 0.7, topP: 0.9, topK: 0, minP: 0, repetitionPenalty: 1,
            repetitionContextSize: 0, frequencyPenalty: 0, presencePenalty: 0, seed: 7, stream: 11,
            logitBias: [.init(tokenID: 3, bias: -1)])
        let sampled = ClusterWorkerCommand.reserve(.init(profileID: "cpu", promptTokenIDs: [7, 8, 9], stopTokenIDs: [2], outputCount: 2,
            chunkSize: 1, deadlineUptimeNanoseconds: 9_000, capacityLimitBytes: 100, sampling: sampling))
        let sampledLocal = try ClusterLinkWorkerWire.decode(try ClusterLinkWorkerWire.command(sampled, requestID: request, epoch: epoch,
            session: session, sequence: 4, now: 8_000, deliveryDeadline: 8_200).encoded()).localCommand(now: 50_000)
        guard case .reserve(let s) = sampledLocal.command else { throw ClusterOwnerStateError.invalid("Sampled reserve lost") }
        try require(s.sampling == sampling && s.deadlineUptimeNanoseconds == 51_000,
            "A sampled reservation lost its sampling on the link: \(String(describing: s.sampling))")
        try require(r.sampling == nil, "A greedy reservation gained sampling on the link")
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

    /// The leader goes silent (its listener stops; no fence is sent): the
    /// follower fences its own owner when the lease it was granted runs out,
    /// and still proves cleanup and release on its side. The leader has no
    /// proof while the link is down: rank 1 stays unresolved there.
    static func leaseEnforcedByTheFollower(_ follower: URL, _ owner: URL, _ worker: String) throws {
        let harness = try LinkHarness(follower: follower, owner: owner, worker: worker, profile: "none", behavior: "normal")
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try localEndpoint(owner, worker, dir, behavior: "normal", relay: nil)
        let second = try harness.linkEndpoint(relay: nil, lifetimeNanoseconds: 8_000_000_000)
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: now() + 6_000_000_000)
        try require(pair.readiness != nil, "Pair not ready")
        let silent = now()
        harness.listener.stop()
        try require(harness.sawReport("fenced leader lease expired", seconds: 12), "Follower did not fence at its lease: \(harness.reports)")
        try require(harness.sawReport("released true", seconds: 20), "Follower did not release after its own fence: \(harness.reports)")
        let elapsed = Double(now() - silent) / 1e9
        try require(harness.followerJournalBytes() == 0, "Follower journal left after lease expiry")
        try require(!second.nativeCleanupObserved, "The leader claimed rank 1's cleanup without a link")
        first.requestNativeCleanup()
        try require(first.waitForOwnerReleased(deadline: now() + 10_000_000_000), "Leader's local owner release missing")
        let status = try harness.finish()
        try require(status == 0, "Follower exit \(status): \(harness.reports)")
        withExtendedLifetime(pair) {}
        print(String(format: "PASS lease enforced by a follower whose leader went silent: fenced and released %.1f s after (grant 8 s)", elapsed))
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
