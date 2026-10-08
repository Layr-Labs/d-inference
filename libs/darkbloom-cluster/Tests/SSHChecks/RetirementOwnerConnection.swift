import Foundation
import Darwin
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

func retirementRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ClusterOwnerStateError.invalid(message) }
}

/// Actual local service and child. Only transport scheduling is controlled here;
/// production service/state/process code supplies terminal and journal evidence.
final class RetirementOwnerConnection {
    let process = Process(), input = Pipe(), output = Pipe()
    let directory: URL, rank: Int, deadline: UInt64
    let lease = UUID(), request = UUID()
    let pipe: ClusterOwnerPipe
    let diagnostics: FileHandle
    private(set) var incarnation: UUID!
    private(set) var terminal: OwnerWire?
    private(set) var nativeEvents: [ClusterWorkerEventFrame] = []
    private(set) var released = false
    private var nextWire: UInt64 = 1, nextCommand: UInt64 = 0, nextEvent: UInt64 = 0

    init(owner: URL, worker: String, directory: URL, rank: Int, behavior: String) throws {
        self.directory = directory; self.rank = rank
        deadline = DispatchTime.now().uptimeNanoseconds + 12_000_000_000
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let errorURL = directory.appendingPathComponent("owner.stderr")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else { throw OwnerWire.invalid("Cannot retain stderr") }
        diagnostics = try FileHandle(forWritingTo: errorURL)
        pipe = try ClusterOwnerPipe(input: output.fileHandleForReading.fileDescriptor,
            output: input.fileHandleForWriting.fileDescriptor, readingCommands: false)
        process.executableURL = owner
        process.arguments = [worker, directory.path, String(rank), behavior]
        process.environment = [:]
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        try process.run()
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        let open = OwnerWire(kind: "open", epoch: fixtureIdentity.membershipEpoch, lease: lease,
            incarnation: nil, sequence: 0, clusterID: "cpu-test", remaining: 10_000_000_000)
        try pipe.write(open.encoded(commandStream: true), until: deadline)
        let hello = try receive()
        try retirementRequire(hello.kind == "hello" && hello.launchID != nil, "Missing owner hello")
        incarnation = hello.incarnation
        try retirementRequire(incarnation != nil, "Missing incarnation")
        let ready = try receive()
        try retirementRequire(ready.kind == "event" && nativeEvents.count == 1, "Missing actual ready")
    }

    func receive() throws -> OwnerWire {
        guard let bytes = try pipe.read(until: deadline) else { throw OwnerWire.invalid("Owner read timed out") }
        let frame = try OwnerWire.decode(bytes, commandStream: false)
        try retirementRequire(frame.epoch == fixtureIdentity.membershipEpoch && frame.lease == lease
            && frame.sequence == nextEvent, "Owner event identity/sequence differs")
        if let incarnation { try retirementRequire(frame.incarnation == incarnation, "Owner incarnation changed") }
        nextEvent += 1
        if frame.kind == "event", let payload = frame.payload {
            nativeEvents.append(try ClusterWorkerCodec.decodeEvent(payload))
        }
        if frame.kind == "terminal" {
            try retirementRequire(frame.termination != nil && terminal == nil, "Missing/repeated native terminal")
            terminal = frame
        }
        if frame.kind == "released" { released = true }
        return frame
    }

    func command(_ command: ClusterWorkerCommand, requestID: UUID?, wireOffset: UInt64 = 0) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let frame = ClusterWorkerCommandFrame(membershipEpoch: fixtureIdentity.membershipEpoch,
            sequence: nextCommand, requestID: requestID, command: command)
        let wire = try OwnerWire.command(frame, lease: lease, incarnation: incarnation,
            sequence: nextWire + wireOffset, now: now, deliveryDeadline: deadline)
        try pipe.write(wire.encoded(commandStream: true), until: deadline)
        nextWire += 1; nextCommand += 1
    }

    func reserve() throws {
        try command(.reserve(.init(profileID: fixtureProfile.id, promptTokenIDs: [1, 2],
            stopTokenIDs: [], outputCount: 2, chunkSize: 1, deadlineUptimeNanoseconds: deadline,
            capacityLimitBytes: 1024)), requestID: request)
        _ = try receive()
        try retirementRequire(nativeEvents.last?.event == .admitted(reservedBytes: 800), "Missing actual admission")
    }

    func completeRequest() throws {
        try reserve()
        try command(.start, requestID: request)
        if rank == 0 {
            for ordinal in 0..<2 {
                _ = try receive()
                try retirementRequire(nativeEvents.last?.event == .committedToken(ordinal: ordinal,
                    tokenID: 9 + ordinal, committedTokens: 2 + ordinal), "Two-token sequence differs")
                try command(.tokenDecision(ordinal: ordinal, decision: .proceed), requestID: request)
            }
        }
        _ = try receive()
        try retirementRequire(nativeEvents.last?.event == .finished(.length), "Missing clean length")
        _ = try receive()
        try retirementRequire(nativeEvents.last?.event == .retired(.clean), "Missing actual request retirement")
        try retirementRequire(journalBytes > 0, "Request retirement cleared device journal")
    }

    func awaitTerminal() throws {
        while terminal == nil { _ = try receive() }
        try retirementRequire(journalBytes > 0, "Native terminal cleared journal before explicit release")
    }

    func release() throws {
        let frame = OwnerWire(kind: "release", epoch: fixtureIdentity.membershipEpoch, lease: lease,
            incarnation: incarnation, sequence: nextWire)
        try pipe.write(frame.encoded(commandStream: true), until: deadline); nextWire += 1
    }

    func awaitOwnerExit() throws {
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(5_000) }
        try retirementRequire(!process.isRunning, "Owner failed to exit within fixed bound")
        process.waitUntilExit()
    }

    var journalBytes: Int {
        (try? Data(contentsOf: directory.appendingPathComponent("native-device.lease")).count) ?? -1
    }
    var summary: [String: Any] {
        ["rank": rank, "requestRetired": nativeEvents.contains { $0.event == .retired(.clean) },
         "nativeTerminalObserved": terminal != nil, "released": released, "journalBytes": journalBytes,
         "shutdownCompleteCount": nativeEvents.filter { $0.event == .shutdownComplete }.count,
         "ownerExited": !process.isRunning, "ownerStatus": process.isRunning ? -999 : process.terminationStatus]
    }
    func close() {
        pipe.closeOutput(); try? input.fileHandleForWriting.close()
        let end = DispatchTime.now().uptimeNanoseconds + 4_000_000_000
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < end { usleep(5_000) }
        if process.isRunning { process.terminate() }
        if !process.isRunning { process.waitUntilExit() }
        try? output.fileHandleForReading.close(); try? diagnostics.close()
    }
    deinit { close() }
}
