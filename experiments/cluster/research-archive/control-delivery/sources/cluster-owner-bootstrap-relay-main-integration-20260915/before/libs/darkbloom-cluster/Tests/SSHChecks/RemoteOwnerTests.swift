import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ClusterOwnerStateError.invalid(message) }
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
        try failure(owner, worker)
        try transportLoss(owner, worker)
        try ownerEOF(owner, worker)
        try admissionExpiry(owner, worker)
        try blockedCallback(owner, worker)
        print("remote-owner: 9 CPU groups passed")
    }
    static func codec() throws {
        let epoch = UUID(), lease = UUID(), inc = UUID(), request = UUID()
        let original = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 2, requestID: request,
            command: .reserve(.init(profileID: "cpu", promptTokenIDs: [1, 2], stopTokenIDs: [], outputCount: 2,
                chunkSize: 1, deadlineUptimeNanoseconds: 9_000, capacityLimitBytes: 100)))
        let wire = try OwnerWire.command(original, lease: lease, incarnation: inc, sequence: 3, now: 8_000, deliveryDeadline: 8_200)
        let data = try wire.encoded(commandStream: true)
        try require(!String(decoding: data, as: UTF8.self).contains("deadlineUptimeNanoseconds"), "Foreign uptime leaked")
        let decoded = try OwnerWire.decode(data, commandStream: true)
        try require(decoded.deliveryRemaining == 200, "Admission duration lost")
        let local = try decoded.localCommand(now: 300, lifetimeDeadline: 1_100)
        if case .reserve(let r) = local.command { try require(r.deadlineUptimeNanoseconds == 1_100, "Remote translation failed") }
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
        try rejects { _ = try ClusterSSHConfiguration(host: "peer;touch-bad", user: "gaj", port: 22,
            knownHostsFile: known, identityFile: key, installedDarkbloom: "/bin/sh -c") }
    }
    static func endpoint(_ owner: URL, _ worker: String, _ dir: URL, behavior: String, rank: Int = 0) throws -> ClusterRemoteWorkerEndpoint {
        try .init(transport: .init(executable: owner, arguments: [worker, dir.path, String(rank), behavior], environment: [:]),
            clusterID: "cpu-test", expectedIdentity: fixtureIdentity, profile: fixtureProfile, rank: rank,
            executionPlanSHA256: fixturePlan, lifetimeDeadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
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
            outputCount: 2, chunkSize: 1, deadlineUptimeNanoseconds: deadline, capacityLimitBytes: 1024)), requestID: id, deadline: deadline)
        if case .admitted = try event(e).event {} else { throw OwnerWire.invalid("Expected admission") }
        try e.sendWorkerCommand(.start, requestID: id, deadline: deadline)
        for i in 0..<2 {
            if case .committedToken(let ordinal, _, _) = try event(e).event { try require(ordinal == i, "Token ordinal differs") }
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
        process.executableURL = owner; process.arguments = [worker, dir.path, "0", "hang"]; process.environment = [:]
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
        try require(result.kind == "terminal" && result.termination == .signalled(signal: SIGKILL), "EOF did not observe actual fenced native child")
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); throw OwnerWire.invalid("Owner failed to stop after EOF") }
        process.waitUntilExit()
        try rejects { _ = try ClusterDeviceLease(directoryURL: dir) }
        try output.fileHandleForReading.close(); try err.fileHandleForReading.close()
    }

    static func admissionExpiry(_ owner: URL, _ worker: String) throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let e = try endpoint(owner, worker, dir, behavior: "slow-admit")
        _ = try event(e)
        let now = DispatchTime.now().uptimeNanoseconds
        try e.sendWorkerCommand(.reserve(.init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2], stopTokenIDs: [],
            outputCount: 2, chunkSize: 1, deadlineUptimeNanoseconds: now + 8_000_000_000, capacityLimitBytes: 1024)),
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
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000, capacityLimitBytes: 1800))
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

}
