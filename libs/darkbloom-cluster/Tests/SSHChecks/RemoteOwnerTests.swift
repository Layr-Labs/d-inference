import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@_spi(OwnerService) import DarkbloomClusterProcess
@_spi(OwnerService) @testable import DarkbloomClusterRemote

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ClusterOwnerStateError.invalid(message) }
}
func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }; throw ClusterOwnerStateError.invalid("Expected rejection")
}
func directory() throws -> URL {
    let value = URL(fileURLWithPath: "/private/tmp/cluster-remote-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return value
}
@main struct RemoteOwnerTests {
    static func main() throws {
        let owner = URL(fileURLWithPath: CommandLine.arguments[1]), worker = CommandLine.arguments[2]
        try codec()
        try lease()
        try ssh()
        try normal(owner, worker)
        try ownerExitIsObservedInEverySession(owner, worker)
        try failure(owner, worker)
        try ownerDeathEndsTheWaits(owner, worker)
        try transportLoss(owner, worker)
        try ownerEOF(owner, worker)
        try admissionExpiry(owner, worker)
        try blockedCallback(owner, worker)
        try bootstrap(owner, worker)
        try invalidBootstrap(owner, worker)
        try bootstrapContracts()
        try combinedBootstrap(owner, worker)
        try combinedBootstrapContracts()
        try cancelledInflightRound(owner, worker)
        try journalFollowsTheLaunch(owner, worker)
        try ownerKeepsItsCeilingAfterAReaderError(owner, worker)
        try lifetimeExpiryStillReleases(owner, worker)
        try ownerCeilingFollowsTheOwnersClock(owner, worker)
        try recovery(worker)
        print("remote-owner: 22 CPU groups passed")
    }
    static func codec() throws {
        let epoch = UUID(), lease = UUID(), inc = UUID(), request = UUID()
        let original = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 2, requestID: request,
            command: .reserve(.init(profileID: "cpu", promptTokenIDs: [1, 2], stopTokenIDs: [], outputCount: 2,
                chunkSize: 1, deadlineUptimeNanoseconds: 9_000, capacityLimitBytes: 100, sampling: nil)))
        let wire = try OwnerWire.command(original, lease: lease, incarnation: inc, sequence: 3, now: 8_000, deliveryDeadline: 8_200)
        let data = try wire.encoded(commandStream: true)
        try require(!String(decoding: data, as: UTF8.self).contains("deadlineUptimeNanoseconds"), "Foreign uptime leaked")
        let decoded = try OwnerWire.decode(data, commandStream: true)
        try require(decoded.deliveryRemaining == 200, "Admission duration lost")
        let local = try decoded.localCommand(now: 300, lifetimeDeadline: 1_100)
        // The leader's remaining duration is translated, not capped by the
        // owner's lease, which the leader renews while the request runs.
        if case .reserve(let r) = local.command { try require(r.deadlineUptimeNanoseconds == 1_300, "Remote translation failed") }
        else { throw OwnerWire.invalid("Expected reserve") }
        try rejects { _ = try OwnerWire.decode(Data("{\"version\":1,\"version\":1}\n".utf8), commandStream: true) }
        try rejects { _ = try OwnerWire.decode(data.dropLast(), commandStream: true) }
        try rejects { _ = try OwnerWire.decode(data, commandStream: false) }
        try rejects { _ = try OwnerWire.command(original, lease: lease, incarnation: inc, sequence: 3, now: 9_000, deliveryDeadline: 9_200) }
        let malformed = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"sequence\":3", with: "\"sequence\":true").utf8)
        try rejects { _ = try OwnerWire.decode(malformed, commandStream: true) }
    }
    static func lease() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let binding = try ClusterOwnerBinding(clusterID: "cpu-test", ownerIncarnation: UUID(), leaseID: UUID(),
            identity: fixtureIdentity, profile: fixtureProfile, rank: 0, executionPlanSHA256: fixturePlan)
        do {
            let lease = try ClusterDeviceLease(directoryURL: dir)
            try rejects { _ = try ClusterDeviceLease(directoryURL: dir) }
            try lease.record(binding: binding, launchID: UUID())
        }
        try rejects { _ = try ClusterDeviceLease(directoryURL: dir) }
        // Test-owned unresolved artifact; production never does this recovery.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("native-device.lease"))
        do { let lease = try ClusterDeviceLease(directoryURL: dir); try lease.record(binding: binding, launchID: UUID()); try lease.resolve() }
        _ = try ClusterDeviceLease(directoryURL: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("native-device.lease"))
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("native-device.lease").path, withDestinationPath: "/dev/null")
        try rejects { _ = try ClusterDeviceLease(directoryURL: dir) }
    }
    static func ssh() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let known = dir.appendingPathComponent("known_hosts"), key = dir.appendingPathComponent("id_ed25519")
        try Data("public-fixture".utf8).write(to: known); try Data("invented-key-fixture".utf8).write(to: key)
        let config = try ClusterSSHConfiguration(host: "peer.local", user: "gaj", port: 22,
            knownHostsFile: known, identityFile: key, installedDarkbloom: "/usr/local/bin/darkbloom")
        let launch = try config.launch()
        try require(launch.executable.path == "/usr/bin/ssh" && launch.arguments.contains("StrictHostKeyChecking=yes")
            && launch.arguments.last == "exec /usr/local/bin/darkbloom cluster worker-owner --stdio", "SSH launch widened")
        // One identity by path, no agent, no prompt. The keychain may supply
        // that identity's passphrase and nothing else.
        for option in ["IdentitiesOnly=yes", "IdentityAgent=none", "BatchMode=yes", "UseKeychain=yes", "GlobalKnownHostsFile=/dev/null"] {
            try require(launch.arguments.contains(option), "SSH identity policy lost \(option)")
        }
        try require(Array(launch.arguments.prefix(2)) == ["-F", "/dev/null"] && launch.environment["SSH_AUTH_SOCK"] == nil, "SSH launch reads user configuration or an agent")
        // The operator's own agent serves the configured identity only when allowed, and only from a socket this user owns.
        let socketPath = dir.appendingPathComponent("agent.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in socketPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) } }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        defer { close(listener); unlink(socketPath) }
        func agent(_ environment: [String: String]) throws -> [String] {
            try ClusterSSHConfiguration(host: "peer.local", user: "gaj", port: 22, knownHostsFile: known, identityFile: key,
                installedDarkbloom: "/usr/local/bin/darkbloom", environment: environment).launch().arguments
        }
        try require(bound == 0, "the fixture agent socket was not bound at \(socketPath)")
        do {
            try require(try agent(["SSH_AUTH_SOCK": socketPath]).contains("IdentityAgent=none"), "an agent was used without the operator's switch")
            let allowed = try agent(["SSH_AUTH_SOCK": socketPath, "DARKBLOOM_CLUSTER_SSH_AGENT": "1"])
            try require(allowed.contains("IdentityAgent=\(socketPath)") && allowed.contains("IdentitiesOnly=yes") && allowed.contains("ForwardAgent=no"),
                "the allowed agent widened what is offered")
            try require(try agent(["SSH_AUTH_SOCK": known.path, "DARKBLOOM_CLUSTER_SSH_AGENT": "1"]).contains("IdentityAgent=none"), "a regular file was taken as an agent")
            try require(try agent(["SSH_AUTH_SOCK": "relative.sock", "DARKBLOOM_CLUSTER_SSH_AGENT": "1"]).contains("IdentityAgent=none"), "a relative socket was taken")
        }
        try rejects { _ = try ClusterSSHConfiguration(host: "peer;touch-bad", user: "gaj", port: 22,
            knownHostsFile: known, identityFile: key, installedDarkbloom: "/bin/sh -c") }
    }
    static func endpoint(_ owner: URL, _ worker: String, _ dir: URL, behavior: String, rank: Int = 0, bootstrapRelay: ClusterOwnerBootstrapRelay? = nil,
                         lifetimeNanoseconds: UInt64 = 15_000_000_000,
                         ownerAllowanceNanoseconds: UInt64 = ClusterRemoteWorkerEndpoint.standardOwnerRetirementAllowanceNanoseconds) throws -> ClusterRemoteWorkerEndpoint {
        try .init(transport: .init(executable: owner, arguments: [worker, dir.path, String(rank), behavior], environment: [:]),
            clusterID: "cpu-test", expectedIdentity: fixtureIdentity, profile: fixtureProfile, rank: rank,
            executionPlanSHA256: fixturePlan, lifetimeDeadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + lifetimeNanoseconds,
            bootstrapRelay: bootstrapRelay, ownerRetirementAllowanceNanoseconds: ownerAllowanceNanoseconds)
    }
    static func journalBytes(_ dir: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("native-device.lease").path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }
    static func awaitOwnerExit(_ e: ClusterRemoteWorkerEndpoint, seconds: UInt64) -> ClusterWorkerProcessTermination? {
        let end = DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000
        while e.ownerTermination == nil && DispatchTime.now().uptimeNanoseconds < end { Thread.sleep(forTimeInterval: 0.01) }
        return e.ownerTermination
    }

    /// The journal names a launch immediately before that launch can exist and
    /// is cleared when no child was created. Previously it was written before
    /// the hello and the factory, and each of these three left it behind.
    static func journalFollowsTheLaunch(_ owner: URL, _ worker: String) throws {
        for behavior in ["factory-throws+normal", "launch-fails+normal"] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let e = try endpoint(owner, worker, dir, behavior: behavior)
            try rejects { _ = try e.receiveWorkerEvent(until: DispatchTime.now().uptimeNanoseconds + 3_000_000_000) }
            try require(awaitOwnerExit(e, seconds: 5) != nil, "Owner did not end after a failed launch (\(behavior))")
            try require(e.readiness == nil, "Failed launch became ready")
            try require(journalBytes(dir) == 0, "A launch that created no child left a journal (\(behavior))")
            _ = try ClusterDeviceLease(directoryURL: dir)
        }
        // The leader stops listening before the hello can be delivered.
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = owner; process.arguments = [worker, dir.path, "0", "normal"]; process.environment = [:]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close(); try output.fileHandleForReading.close()
        let pipe = try ClusterOwnerPipe(input: STDIN_FILENO, output: input.fileHandleForWriting.fileDescriptor, readingCommands: false)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        try pipe.write(OwnerWire(kind: "open", epoch: fixtureIdentity.membershipEpoch, lease: UUID(), incarnation: nil,
            sequence: 0, clusterID: "cpu-test", remaining: 6_000_000_000).encoded(commandStream: true), until: deadline)
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); throw OwnerWire.invalid("Owner stalled at a hello nobody reads") }
        process.waitUntilExit(); pipe.closeOutput(); try? input.fileHandleForWriting.close()
        try require(journalBytes(dir) == 0, "A hello that was never delivered left a journal")
        _ = try ClusterDeviceLease(directoryURL: dir)
    }

    /// A reader error must not end a local owner that is still waiting for its
    /// child. The endpoint closes its command stream; the owner fences the
    /// child, waits out the three seconds the stand-in needs, clears its own
    /// journal and exits by itself. Previously the endpoint sent SIGTERM to the
    /// owner at once, orphaning the child and stranding the journal.
    static func ownerKeepsItsCeilingAfterAReaderError(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let begin = DispatchTime.now().uptimeNanoseconds
        let e = try endpoint(owner, worker, dir, behavior: "garbage+slow-exit")
        _ = try event(e)
        try rejects { _ = try e.receiveWorkerEvent(until: DispatchTime.now().uptimeNanoseconds + 2_000_000_000) }
        let ended = awaitOwnerExit(e, seconds: 10)
        try require(ended != nil, "Owner did not end by itself after its connection failed")
        try require(ended != .signalled(SIGTERM) && ended != .signalled(SIGKILL), "The endpoint signalled an owner that still supervised a child: \(String(describing: ended))")
        try require(DispatchTime.now().uptimeNanoseconds - begin >= 2_500_000_000, "Owner ended before its child's own three seconds")
        try require(!e.nativeCleanupObserved && !e.ownerDeviceLeaseReleasedObserved, "A failed connection fabricated cleanup proof")
        try require(journalBytes(dir) == 0, "Owner that observed its child's exit left a journal")
        _ = try ClusterDeviceLease(directoryURL: dir)
    }

    /// A child that ignores its stream lives to its lifetime and is ended after
    /// it. The owner keeps reading and writing past the lifetime, so the
    /// terminal, the release and the cleared journal all still arrive.
    /// Previously the owner stopped at its deadline and stranded the journal.
    static func lifetimeExpiryStillReleases(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let begin = DispatchTime.now().uptimeNanoseconds
        let e = try endpoint(owner, worker, dir, behavior: "quick+deaf-term", lifetimeNanoseconds: 1_500_000_000, ownerAllowanceNanoseconds: 8_000_000_000)
        _ = try event(e)
        try require(e.waitForNativeCleanup(until: begin + 8_000_000_000), "Native terminal after the lifetime was not received")
        try require(DispatchTime.now().uptimeNanoseconds - begin >= 1_700_000_000, "Child was ended before its lifetime plus margin")
        try require(e.waitForOwnerReleased(deadline: begin + 10_000_000_000), "Release handshake after the lifetime was lost")
        try require(e.ownerTermination == .exited(0) && journalBytes(dir) == 0, "Lifetime expiry left an owner error or a journal")
    }

    /// An owner starts its lifetime when it reads the open, after its own
    /// preparation, so it retires its child later than the leader's clock
    /// alone suggests. The endpoint must not give up on, or signal, an owner
    /// that is still inside its own ceiling: here the owner prepares for 1.5 s,
    /// its child ignores its stream and is ended after the owner's lifetime,
    /// and the terminal, the release and the cleared journal all still arrive.
    /// Measured from the leader's lifetime alone the endpoint stopped listening
    /// at 2.2 s and signalled the owner, with its child still running.
    static func ownerCeilingFollowsTheOwnersClock(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let begin = DispatchTime.now().uptimeNanoseconds
        let e = try endpoint(owner, worker, dir, behavior: "late-open+quick+deaf-term", lifetimeNanoseconds: 1_000_000_000, ownerAllowanceNanoseconds: 1_200_000_000)
        let leaderCeiling = e.localLifetimeDeadlineUptimeNanoseconds + 1_200_000_000
        try require(e.ownerRetirementDeadlineUptimeNanoseconds == leaderCeiling, "Before a hello the ceiling is the leader's lifetime plus the allowance")
        try require(e.waitForNativeCleanup(until: begin + 8_000_000_000), "The endpoint gave up on an owner that was inside its own ceiling")
        // The owner slept 1.5 s before it read the open; its hello cannot have arrived sooner.
        try require(e.ownerRetirementDeadlineUptimeNanoseconds >= leaderCeiling + 1_400_000_000, "The ceiling did not move with the owner's later start")
        try require(e.waitForOwnerReleased(deadline: begin + 10_000_000_000), "Release was lost for an owner that started late")
        try require(e.ownerTermination == .exited(0) && journalBytes(dir) == 0, "A late-starting owner was signalled or left a journal: \(String(describing: e.ownerTermination))")
    }

    /// Explicit recovery of a journal whose owner is gone.
    static func recovery(_ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try require(try ClusterDeviceLeaseRecovery.recover(directoryURL: dir.appendingPathComponent("absent")) == .nothingToRecover, "Absent directory needs no recovery")
        let binding = try ClusterOwnerBinding(clusterID: "cpu-test", ownerIncarnation: UUID(), leaseID: UUID(),
            identity: fixtureIdentity, profile: fixtureProfile, rank: 1, executionPlanSHA256: fixturePlan)
        let epoch = fixtureIdentity.membershipEpoch.uuidString.lowercased()
        func strand() throws { let lease = try ClusterDeviceLease(directoryURL: dir); try lease.record(binding: binding, launchID: UUID()) }
        do { _ = try ClusterDeviceLease(directoryURL: dir) }
        try require(try ClusterDeviceLeaseRecovery.recover(directoryURL: dir) == .nothingToRecover, "Empty journal needs no recovery")

        // A live owner holds the device scope: recovery leaves its journal alone.
        do {
            let lease = try ClusterDeviceLease(directoryURL: dir); try lease.record(binding: binding, launchID: UUID())
            try require(try ClusterDeviceLeaseRecovery.recover(directoryURL: dir) == .refusedLiveOwner, "Recovery ignored a live owner")
            try require(journalBytes(dir) > 0, "Recovery cleared a live owner's journal")
            try lease.resolve()
        }

        // A stranded journal whose worker still runs, by its recorded epoch.
        try strand()
        try rejects { _ = try ClusterDeviceLease(directoryURL: dir) }
        let pretend = try ClusterDeviceLeaseRecovery.recover(directoryURL: dir, runningProcesses: {
            [.init(processIdentifier: 4242, arguments: ["/opt/other", "--membership-epoch", UUID().uuidString.lowercased()]),
             .init(processIdentifier: 4243, arguments: ["/opt/worker", "--membership-epoch", epoch])]
        })
        guard case .refusedLiveWorker(let found, let named) = pretend, found == 4243, named.membershipEpoch == epoch,
              named.rank == 1, named.clusterID == "cpu-test" else { throw OwnerWire.invalid("Recovery missed a process carrying the recorded epoch") }
        try require(journalBytes(dir) > 0, "Refused recovery changed the journal")
        // The same refusal against the real process table: an actual child whose
        // command line carries the epoch, as a native worker's does.
        let alive = Process()
        alive.executableURL = URL(fileURLWithPath: worker)
        alive.arguments = ["0", "never-ready", "--membership-epoch", epoch, "a", "b", "c", "d"]
        alive.standardInput = FileHandle.nullDevice; alive.standardOutput = FileHandle.nullDevice; alive.standardError = FileHandle.nullDevice
        try alive.run()
        defer { if alive.isRunning { alive.terminate(); alive.waitUntilExit() } }
        Thread.sleep(forTimeInterval: 0.2)
        guard case .refusedLiveWorker(let actual, _) = try ClusterDeviceLeaseRecovery.recover(directoryURL: dir),
              actual == alive.processIdentifier else { throw OwnerWire.invalid("Recovery did not find the running process that carries the epoch") }
        try require(journalBytes(dir) > 0, "Refused recovery changed the journal")
        alive.terminate(); alive.waitUntilExit()

        // Nothing the journal names is running: it is cleared and the device is usable.
        guard case .cleared(let record) = try ClusterDeviceLeaseRecovery.recover(directoryURL: dir), record.membershipEpoch == epoch else {
            throw OwnerWire.invalid("Recovery refused a journal that names nothing running")
        }
        try require(journalBytes(dir) == 0, "Recovery reported a clear it did not perform")
        _ = try ClusterDeviceLease(directoryURL: dir)
        try require(try ClusterDeviceLeaseRecovery.recover(directoryURL: dir) == .nothingToRecover, "Recovery is not idempotent")

        // Bytes this build did not write prove nothing and are left alone.
        do { let gate = try ClusterDeviceExclusion(directoryURL: dir); try gate.recordNativeOwnership(Data("not a lease record\n".utf8)) }
        try require(try ClusterDeviceLeaseRecovery.recover(directoryURL: dir, runningProcesses: { [] }) == .refusedUnreadable, "Recovery cleared an unreadable journal")
        try require(journalBytes(dir) > 0, "Refused recovery changed the journal")
    }
    static func event(_ endpoint: ClusterRemoteWorkerEndpoint) throws -> ClusterWorkerEventFrame {
        try endpoint.receiveWorkerEvent(until: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
    }
    static func normal(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = try endpoint(owner, worker, dir, behavior: "normal")
        _ = try event(e)
        let id = UUID(), deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
        try e.sendWorkerCommand(.reserve(.init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2], stopTokenIDs: [],
            outputCount: 2, chunkSize: 1, deadlineUptimeNanoseconds: deadline, capacityLimitBytes: 1024, sampling: nil)), requestID: id, deadline: deadline)
        if case .admitted = try event(e).event {} else { throw OwnerWire.invalid("Expected admission") }
        try e.sendWorkerCommand(.start, requestID: id, deadline: deadline)
        for i in 0..<2 {
            if case .committedToken(let ordinal, _, _, _) = try event(e).event { try require(ordinal == i, "Token ordinal differs") }
            else { throw OwnerWire.invalid("Expected token") }
            try e.sendWorkerCommand(.tokenDecision(ordinal: i, decision: .proceed), requestID: id, deadline: deadline)
        }
        if case .finished(.length) = try event(e).event {} else { throw OwnerWire.invalid("Expected length") }
        if case .retired(.clean) = try event(e).event {} else { throw OwnerWire.invalid("Expected clean retirement") }
        try require(!e.nativeCleanupObserved, "Request retirement fabricated native exit")
        try e.sendWorkerCommand(.shutdown, requestID: nil, deadline: deadline)
        _ = try event(e)
        let until = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        while !e.nativeCleanupObserved && DispatchTime.now().uptimeNanoseconds < until { Thread.sleep(forTimeInterval: 0.01) }
        try require(e.nativeCleanupObserved, "Actual native terminal missing")
        // Wait for owner release ACK before checking the durable journal.
        var size: UInt64 = 1
        while size != 0 && DispatchTime.now().uptimeNanoseconds < until {
            size = (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("native-device.lease").path)[.size] as! NSNumber).uint64Value
            Thread.sleep(forTimeInterval: 0.01)
        }
        try require(size == 0, "Owner journal not released")
    }
    /// Once the owner has released its lease and exited, the endpoint must
    /// report that exit, in every session. It used to take the exit from
    /// `Process.waitUntilExit()` on its reader's dispatch thread. For an owner
    /// that was itself started from a dispatch thread, as every product
    /// caller starts it, that call returned about 70 ms late and in a share of
    /// sessions slept for seconds or for ever: no exit proof, so a session
    /// that had been cleaned up completely was reported as not released.
    /// Started from the main thread the fault does not show at all, and the
    /// share is small, so one session proves nothing; this many do.
    static func ownerExitIsObservedInEverySession(_ owner: URL, _ worker: String) throws {
        let sessions = 300
        for session in 1...sessions {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let e = try endpointStartedOnADispatchThread(owner, worker, dir, behavior: "normal")
            _ = try event(e)
            try e.sendWorkerCommand(.shutdown, requestID: nil, deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
            let observed = e.waitForOwnerReleased(deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
            try require(observed && e.ownerTermination == .exited(0),
                "Session \(session) of \(sessions): owner exit not observed within 5 s (native cleanup \(e.nativeCleanupObserved), lease released \(e.ownerDeviceLeaseReleasedObserved), owner termination \(String(describing: e.ownerTermination)))")
            try require(journalBytes(dir) == 0, "Session \(session): released owner left a journal")
        }
    }
    final class StartedEndpoint: @unchecked Sendable { var result: Result<ClusterRemoteWorkerEndpoint, any Error>? }
    static func endpointStartedOnADispatchThread(_ owner: URL, _ worker: String, _ dir: URL, behavior: String) throws -> ClusterRemoteWorkerEndpoint {
        let started = StartedEndpoint(), done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "remote-owner-check.start").async {
            started.result = Result { try endpoint(owner, worker, dir, behavior: behavior) }
            done.signal()
        }
        done.wait()
        return try started.result!.get()
    }
    static func failure(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = try endpoint(owner, worker, dir, behavior: "hang")
        _ = try event(e)
        e.requestNativeCleanup()
        let until = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !e.nativeCleanupObserved && DispatchTime.now().uptimeNanoseconds < until { Thread.sleep(forTimeInterval: 0.01) }
        try require(e.nativeCleanupObserved, "Cancellation watchdog failed to obtain actual native terminal")
        try require(e.readiness == nil, "Failed owner became ready")
    }
    /// An owner killed by a signal while a request runs can never publish its
    /// worker's cleanup. The leader's waits on it end at once, claiming nothing: no
    /// cleanup is observed, ownership stays unresolved, the signal is named.
    static func ownerDeathEndsTheWaits(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = try endpoint(owner, worker, dir, behavior: "normal")
        _ = try event(e)
        let id = UUID(), deadline = DispatchTime.now().uptimeNanoseconds + 8_000_000_000
        try e.sendWorkerCommand(.reserve(.init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2], stopTokenIDs: [],
            outputCount: 2, chunkSize: 1, deadlineUptimeNanoseconds: deadline, capacityLimitBytes: 1024, sampling: nil)), requestID: id, deadline: deadline)
        if case .admitted = try event(e).event {} else { throw OwnerWire.invalid("Expected admission") }
        try e.sendWorkerCommand(.start, requestID: id, deadline: deadline)
        if case .committedToken = try event(e).event {} else { throw OwnerWire.invalid("Expected the first token") }
        guard let pid = e.ownerProcessIdentifier else { throw OwnerWire.invalid("Owner process not running") }
        let ended = DispatchSemaphore(value: 0)
        Thread { e.waitForNativeCleanup(); ended.signal() }.start()
        // SIGKILL (a fixture owner; no model): SIGUSR1, the qualifier's F3
        // trigger, is now the owner's force-cancel hook (orphan eradication),
        // which fences the worker and proves its cleanup instead of dying.
        try require(Darwin.kill(pid, SIGKILL) == 0, "Could not signal the owner")
        let began = DispatchTime.now().uptimeNanoseconds
        try require(ended.wait(timeout: .now() + 10) == .success, "The cleanup wait outlived the owner's death (10 s)")
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        try require(!e.nativeCleanupObserved && !e.ownerDeviceLeaseReleasedObserved, "A dead owner's cleanup was claimed")
        try require(e.ownerTermination == .signalled(SIGKILL), "Owner termination differs: \(String(describing: e.ownerTermination))")
        try require(e.unresolvedReason?.contains("terminated by signal \(SIGKILL)") == true, "The cause is not named: \(e.unresolvedReason ?? "none")")
        try require(!e.waitForOwnerReleased(deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000), "A dead owner's release was claimed")
        try require(e.readiness == nil, "A dead owner stayed ready")
        print(String(format: "PASS an owner killed by a signal mid-request ends the leader's waits in %.2f s, claiming nothing", elapsed))
    }
    static func transportLoss(_ owner: URL, _ worker: String) throws {
        for behavior in ["transport-exit", "wrong-terminal"] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let e = try endpoint(owner, worker, dir, behavior: behavior)
            try rejects { _ = try e.receiveWorkerEvent(until: DispatchTime.now().uptimeNanoseconds + 1_000_000_000) }
            Thread.sleep(forTimeInterval: 0.1)
            try require(!e.nativeCleanupObserved && e.readiness == nil, "Transport or wrong-incarnation exit fabricated native cleanup")
        }
    }
    static func ownerEOF(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let process = Process(), input = Pipe(), output = Pipe(), err = Pipe()
        // The stand-in needs three seconds to end itself once its stream closes.
        process.executableURL = owner; process.arguments = [worker, dir.path, "0", "slow-exit"]; process.environment = [:]
        process.standardInput = input; process.standardOutput = output; process.standardError = err
        let pipe = try ClusterOwnerPipe(input: output.fileHandleForReading.fileDescriptor,
            output: input.fileHandleForWriting.fileDescriptor, readingCommands: false)
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close(); try err.fileHandleForWriting.close()
        let deadline = DispatchTime.now().uptimeNanoseconds + 7_000_000_000
        let open = OwnerWire(kind: "open", epoch: fixtureIdentity.membershipEpoch, lease: UUID(), incarnation: nil,
            sequence: 0, clusterID: "cpu-test", remaining: 6_000_000_000)
        try pipe.write(open.encoded(commandStream: true), until: deadline)
        guard let hello = try pipe.read(until: deadline), let ready = try pipe.read(until: deadline) else { throw OwnerWire.invalid("Owner setup missing") }
        let helloValue = try OwnerWire.decode(hello, commandStream: false)
        try require(helloValue.kind == "hello", "Owner hello missing")
        let readyValue = try OwnerWire.decode(ready, commandStream: false)
        try require(readyValue.kind == "event", "Owner ready missing")
        pipe.closeOutput(); try input.fileHandleForWriting.close()
        guard let terminal = try pipe.read(until: deadline) else { throw OwnerWire.invalid("EOF cleanup terminal missing") }
        let result = try OwnerWire.decode(terminal, commandStream: false)
        // Losing the leader fences the child by closing its command stream. The
        // child is left to end by its own path: no SIGTERM (which this stand-in
        // would report as status 99) and no SIGKILL two seconds later.
        try require(result.kind == "terminal" && result.termination == .exited(status: 3), "EOF did not leave the native child to end itself: \(String(describing: result.termination))")
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); throw OwnerWire.invalid("Owner failed to stop after EOF") }
        process.waitUntilExit()
        try require(process.terminationStatus != 0, "An owner that lost its leader reported a clean release")
        // The owner observed its own child's exit, so no journal is left behind
        // even though the release handshake never happened.
        _ = try ClusterDeviceLease(directoryURL: dir)
        try output.fileHandleForReading.close(); try err.fileHandleForReading.close()
    }

    static func admissionExpiry(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = try endpoint(owner, worker, dir, behavior: "slow-admit")
        _ = try event(e)
        let now = DispatchTime.now().uptimeNanoseconds
        try e.sendWorkerCommand(.reserve(.init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2], stopTokenIDs: [],
            outputCount: 2, chunkSize: 1, deadlineUptimeNanoseconds: now + 8_000_000_000, capacityLimitBytes: 1024, sampling: nil)),
            requestID: UUID(), deadline: now + 100_000_000)
        try rejects { _ = try event(e) }
        let end = now + 3_000_000_000
        while !e.nativeCleanupObserved && DispatchTime.now().uptimeNanoseconds < end { Thread.sleep(forTimeInterval: 0.01) }
        try require(e.nativeCleanupObserved, "Admission expiry waited for generation lifetime")
    }
    static func blockedCallback(_ owner: URL, _ worker: String) throws {
        let a = try directory(), b = try directory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let first = try endpoint(owner, worker, a, behavior: "normal", rank: 0)
        let second = try endpoint(owner, worker, b, behavior: "delayed-exit", rank: 1)
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
        let request = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
            promptTokenIDs: [1, 2], stopTokenIDs: [], outputCount: 2, chunkSize: 1,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000, capacityLimitBytes: 1800, sampling: nil))
        let entered = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        defer { unblock.signal(); first.requestNativeCleanup(); second.requestNativeCleanup() }
        try request.start { event in
            if case .token = event { entered.signal(); _ = unblock.wait(timeout: .now() + 6) }
            return true
        }
        try require(entered.wait(timeout: .now() + 2) == .success, "Token callback did not start")
        let end = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while (!first.nativeCleanupObserved || !second.nativeCleanupObserved) && DispatchTime.now().uptimeNanoseconds < end {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try require(first.nativeCleanupObserved && second.nativeCleanupObserved && pair.readiness == nil,
            "Remote exit did not invalidate/fence peer while callback blocked")
        unblock.signal()
        while !request.isRetired && DispatchTime.now().uptimeNanoseconds < end + 1_000_000_000 { Thread.sleep(forTimeInterval: 0.01) }
        try require(request.isRetired, "Request retirement missing after native proof")
        request.releaseResources()
    }

    static func bootstrap(_ owner: URL, _ worker: String) throws {
        let a = try directory(), b = try directory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let relay = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        let first = try endpoint(owner, worker, a, behavior: "bootstrap-normal", rank: 0, bootstrapRelay: relay)
        let second = try endpoint(owner, worker, b, behavior: "bootstrap-normal", rank: 1, bootstrapRelay: relay)
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        let request = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
            promptTokenIDs: [1, 2], stopTokenIDs: [], outputCount: 2, chunkSize: 1,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 8_000_000_000, capacityLimitBytes: 1800, sampling: nil))
        try request.start { _ in true }
        let end = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !request.isRetired && DispatchTime.now().uptimeNanoseconds < end { Thread.sleep(forTimeInterval: 0.01) }
        try require(request.isRetired, "Bootstrap-attached paired request did not retire")
        request.releaseResources()
        let done = DispatchSemaphore(value: 0)
        Task.detached { await pair.shutdown(); done.signal() }
        try require(done.wait(timeout: .now() + 4) == .success, "Bootstrap-attached owners did not shut down")
        try require(first.nativeCleanupObserved && second.nativeCleanupObserved, "Missing bootstrap native cleanup proof")
    }
    static func invalidBootstrap(_ owner: URL, _ worker: String) throws {
        let a = try directory(), b = try directory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let relay = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 3_000_000_000)
        let first = try endpoint(owner, worker, a, behavior: "bootstrap-bad-length", rank: 0, bootstrapRelay: relay)
        let second = try endpoint(owner, worker, b, behavior: "bootstrap-normal", rank: 1, bootstrapRelay: relay)
        try rejects { _ = try ClusterWorkerPair(workers: [first, second], startupDeadline: DispatchTime.now().uptimeNanoseconds + 4_000_000_000) }
        first.requestNativeCleanup(); second.requestNativeCleanup()
        let end = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        while (!first.nativeCleanupObserved || !second.nativeCleanupObserved) && DispatchTime.now().uptimeNanoseconds < end { Thread.sleep(forTimeInterval: 0.01) }
        try require(first.nativeCleanupObserved && second.nativeCleanupObserved, "Invalid scalar failed to fence attached natives")
    }

    static func bootstrapContracts() throws {
        for (sequence, bytes) in [(UInt64(0), Data([1, 0, 0, 0])), (1, Data(repeating: 0, count: 32)),
                                   (2, Data([1, 0, 0, 0])), (3, Data([0, 0])), (4, Data([0, 0, 0, 0]))] {
            try rejects { try ClusterOwnerBootstrapProfile.mesh2.validate(sequence: sequence, contribution: bytes) }
        }
        let binding = try ClusterOwnerBinding(clusterID: "cpu-test", ownerIncarnation: UUID(), leaseID: UUID(),
            identity: fixtureIdentity, profile: fixtureProfile, rank: 0, executionPlanSHA256: fixturePlan)
        let skip = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        try rejects { _ = try skip.exchange(binding: binding, sequence: 1, contribution: Data(repeating: 0, count: 64)) }
        let cancelled = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        cancelled.cancel()
        try rejects { _ = try cancelled.exchange(binding: binding, sequence: 0, contribution: Data([2, 0, 0, 0])) }
        var wrong = OwnerWire(kind: "bootstrapReply", epoch: fixtureIdentity.membershipEpoch, lease: UUID(), incarnation: UUID(), sequence: 1,
            bootstrapSequence: 0, bootstrapBytes: Data(repeating: 0, count: 131_073))
        try rejects { _ = try wrong.encoded(commandStream: true) }
        // Past the most rounds any profile carries (the combined profile's seven).
        wrong.bootstrapBytes = Data([2, 0, 0, 0, 2, 0, 0, 0]); wrong.bootstrapSequence = 7
        try rejects { _ = try wrong.encoded(commandStream: true) }
    }

    /// The combined profile (S07): the native key prelude through both owners
    /// and the leader's relay, then the mesh rounds on the same connections.
    static func combinedBootstrap(_ owner: URL, _ worker: String) throws {
        let a = try directory(), b = try directory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let relay = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            profile: .nativeKeyPreludeMesh2, deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 8_000_000_000,
            nativeStarts: try fixtureNativeStarts())
        let first = try endpoint(owner, worker, a, behavior: "bootstrap-prelude", rank: 0, bootstrapRelay: relay)
        let second = try endpoint(owner, worker, b, behavior: "bootstrap-prelude", rank: 1, bootstrapRelay: relay)
        let pair = try ClusterWorkerPair(workers: [first, second], startupDeadline: DispatchTime.now().uptimeNanoseconds + 8_000_000_000)
        let request = try pair.reserve(requestID: UUID(), reservation: .init(profileID: fixtureProfile.id,
            promptTokenIDs: [1, 2], stopTokenIDs: [], outputCount: 2, chunkSize: 1,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 8_000_000_000, capacityLimitBytes: 1800, sampling: nil))
        try request.start { _ in true }
        let end = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !request.isRetired && DispatchTime.now().uptimeNanoseconds < end { Thread.sleep(forTimeInterval: 0.01) }
        try require(request.isRetired, "Combined-profile paired request did not retire")
        request.releaseResources()
        let done = DispatchSemaphore(value: 0)
        Task.detached { await pair.shutdown(); done.signal() }
        try require(done.wait(timeout: .now() + 6) == .success, "Combined-profile owners did not shut down")
        try require(first.nativeCleanupObserved && second.nativeCleanupObserved, "Missing combined-profile native cleanup proof")
        for e in [first, second] {
            try require(e.waitForOwnerReleased(deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000), "Combined-profile owner release missing")
        }
    }

    static func combinedBootstrapContracts() throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        let starts = try fixtureNativeStarts()
        // A relay for the combined profile needs both ranks' starts of its membership.
        try rejects { _ = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            profile: .nativeKeyPreludeMesh2, deadlineUptimeNanoseconds: deadline) }
        try rejects { _ = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            profile: .nativeKeyPreludeMesh2, deadlineUptimeNanoseconds: deadline, nativeStarts: [starts[0], starts[0]]) }
        try rejects { _ = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            profile: .nativeKeyPreludeMesh2, deadlineUptimeNanoseconds: deadline, nativeStarts: try fixtureNativeStarts(epoch: UUID())) }
        try rejects { _ = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: String(repeating: "f", count: 64),
            profile: .nativeKeyPreludeMesh2, deadlineUptimeNanoseconds: deadline, nativeStarts: starts) }
        try rejects { _ = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            profile: .nativeKeyPrelude, deadlineUptimeNanoseconds: deadline, nativeStarts: starts) }
        try rejects { _ = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            deadlineUptimeNanoseconds: deadline, nativeStarts: starts) }
        // An owner whose route is not the one its start names is refused.
        let relay = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            profile: .nativeKeyPreludeMesh2, deadlineUptimeNanoseconds: deadline, nativeStarts: starts)
        let stranger = try ClusterOwnerBinding(clusterID: "cpu-test", ownerIncarnation: UUID(), leaseID: starts[0].leaseID,
            identity: fixtureIdentity, profile: fixtureProfile, rank: 0, executionPlanSHA256: fixturePlan)
        try rejects { _ = try relay.exchange(binding: stranger, sequence: 0, contribution: Data(repeating: 1, count: 32)) }
        // Profile rounds: prelude 0-2, mesh 3-6, nothing past.
        let profile = ClusterOwnerBootstrapProfile.nativeKeyPreludeMesh2
        try require(profile.rounds == 7 && profile.preludeRounds == 3 && profile.meshRounds == 4, "Combined profile rounds differ")
        try profile.validate(sequence: 3, contribution: Data([2, 0, 0, 0]))
        try profile.validate(sequence: 4, contribution: Data(repeating: 9, count: 64))
        try profile.validate(sequence: 6, contribution: Data([0, 0, 0, 0]))
        try profile.validate(sequence: 1, contribution: Data(repeating: 9, count: 32))
        try rejects { try profile.validate(sequence: 7, contribution: Data([0, 0, 0, 0])) }
        try rejects { try profile.validate(sequence: 3, contribution: Data(repeating: 9, count: 32)) }
        try rejects { try profile.validate(sequence: 0, contribution: Data([2, 0, 0, 0])) }
        // The combined open carries the start and never a host uptime.
        var open = OwnerWire(kind: "open", epoch: fixtureIdentity.membershipEpoch, lease: starts[1].leaseID, incarnation: nil,
            sequence: 0, clusterID: "cpu-test", remaining: 6_000_000_000, bootstrapProfile: profile)
        try rejects { _ = try open.encoded(commandStream: true) }
        open.nativeStart = starts[1].canonicalBytes
        let decoded = try OwnerWire.decode(try open.encoded(commandStream: true), commandStream: true)
        try require(decoded.nativeStart == starts[1].canonicalBytes && decoded.nativeLocalDeadline == nil, "Combined open lost its start")
        open.nativeLocalDeadline = 5
        try rejects { _ = try open.encoded(commandStream: true) }
    }

    static func cancelledInflightRound(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let relay = try ClusterOwnerBootstrapRelay(identity: fixtureIdentity, executionPlanSHA256: fixturePlan,
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 6_000_000_000)
        let e = try endpoint(owner, worker, dir, behavior: "inflight-round", rank: 0, bootstrapRelay: relay)
        e.requestNativeCleanup()
        let end = DispatchTime.now().uptimeNanoseconds + 6_000_000_000
        while !e.nativeCleanupObserved && DispatchTime.now().uptimeNanoseconds < end { Thread.sleep(forTimeInterval: 0.01) }
        try require(e.nativeCleanupObserved, "Valid in-flight round closed terminal-proof channel after cancel")
        var size: UInt64 = 1
        while size != 0 && DispatchTime.now().uptimeNanoseconds < end {
            if let n = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("native-device.lease").path)[.size] as? NSNumber { size = n.uint64Value }
            Thread.sleep(forTimeInterval: 0.01)
        }
        try require(size == 0, "In-flight cancel lost owner release acknowledgement")
    }

}
