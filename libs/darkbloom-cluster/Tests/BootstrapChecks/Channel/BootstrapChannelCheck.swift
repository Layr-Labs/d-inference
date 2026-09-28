import Darwin
import Foundation
@testable import DarkbloomClusterBootstrap

enum TestFailure: Error { case failed(String) }
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw TestFailure.failed(message) }
}
func reject(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch is TestFailure { throw TestFailure.failed(message) } catch { return }
    throw TestFailure.failed(message)
}
func deadline(_ milliseconds: UInt64 = 1500) -> UInt64 {
    DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
}

final class Completion: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var error: Error?
    func finish(_ value: Error?) { lock.withLock { error = value }; semaphore.signal() }
    func wait() throws -> Error? {
        try require(semaphore.wait(timeout: .now() + 2) == .success, "background operation did not finish")
        return lock.withLock { error }
    }
}

@main enum BootstrapChannelCheck {
    static let epoch = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!
    static func identity(_ rank: Int) throws -> ClusterBootstrapIdentity { try .init(membershipEpoch: epoch, rank: rank) }

    static func main() {
        do {
            if CommandLine.arguments.count > 1 { try child(); return }
            try codec(); try matching(); try peerChecks(); try invalidStreams(); try lifecycle()
            print("PASS 5 bootstrap check groups; 12 actual local children; no model, RDMA or remote network")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func spawn(_ listener: ClusterBootstrapListener, mode: String, rank: Int = 0,
                      until: UInt64, ownerPID: Int32 = getpid()) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [mode, listener.socketPath, String(ownerPID), String(rank), String(until)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); return process
    }

    static func reap(_ process: Process) throws {
        let limit = deadline(2500)
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < limit { usleep(1000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); throw TestFailure.failed("child required fixture fence") }
        process.waitUntilExit()
        try require(process.terminationReason == .exit && process.terminationStatus == 0, "child did not finish its asserted path")
    }

    static func child() throws {
        signal(SIGALRM) { _ in _exit(99) }; alarm(3)
        let args = CommandLine.arguments, mode = args[1], path = args[2]
        let owner = Int32(args[3])!, rank = Int(args[4])!, until = UInt64(args[5])!
        if mode == "wrong-owner" {
            try reject("wrong owner was accepted") { _ = try ClusterBootstrapConnection.connect(path: path,
                ownerProcessID: owner, identity: identity(rank), deadlineUptimeNanoseconds: until) }
            return
        }
        if ["partial", "oversized", "stale", "wrong-rank", "slow"].contains(mode) {
            var address = try bootstrapAddress(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            let channel = try BootstrapSocket(taking: fd, deadline: until)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            } }
            try require(result == 0, "fixture connect")
            let id = try ClusterBootstrapIdentity(membershipEpoch: mode == "stale" ? UUID() : epoch,
                rank: mode == "wrong-rank" ? 1 : rank)
            let round = try ClusterBootstrapRound(identity: id, sequence: 0, contribution: Data([1, 2, 3, 4]))
            var header = BootstrapHeader(round: round, reply: false).encoded()
            if mode == "oversized" { header[32] = 1 }
            if mode == "partial" || mode == "slow" { header = Data(header.prefix(7)) }
            // Exercise fragmented header delivery, not a single write assumption.
            for byte in header { try channel.write(Data([byte])) }
            if mode == "slow" { usleep(350_000) }
            return
        }
        let connection = try ClusterBootstrapConnection.connect(path: path, ownerProcessID: owner,
            identity: identity(rank), deadlineUptimeNanoseconds: until)
        if mode == "idle" { usleep(350_000); return }
        if mode == "refused" {
            try reject("refused exchange returned") { _ = try connection.exchange(sequence: 0, contribution: Data([1, 2, 3, 4])) }
            return
        }
        let count = rank == 0 ? 4 : 6
        for sequence in 0..<count {
            let bytes = sequence == count - 1 ? 65_536 : 4 + sequence
            let local = Data(repeating: UInt8(10 + sequence), count: bytes)
            let gathered = try connection.exchange(sequence: UInt64(sequence), contribution: local)
            let remote = Data(repeating: 99, count: bytes)
            try require(gathered == (rank == 0 ? local + remote : remote + local), "rank order changed")
        }
        try reject("worker sequence replay") { _ = try connection.exchange(sequence: 0, contribution: Data([1])) }
    }

    static func codec() throws {
        let round = try ClusterBootstrapRound(identity: identity(0), sequence: 5, contribution: Data(repeating: 3, count: 65_536))
        let header = BootstrapHeader(round: round, reply: true)
        let decoded = try BootstrapHeader(header.encoded())
        try require(decoded.identity == round.identity && decoded.sequence == 5 && decoded.payloadBytes == 131_072, "header roundtrip")
        for offset in [0, 4, 5, 6, 7, 24, 32, 36] {
            var bytes = header.encoded(); bytes[offset] = 255
            try reject("malformed header accepted") { _ = try BootstrapHeader(bytes) }
        }
        try reject("empty round") { _ = try ClusterBootstrapRound(identity: identity(0), sequence: 0, contribution: Data()) }
        try reject("extra round") { _ = try ClusterBootstrapRound(identity: identity(0), sequence: 6, contribution: Data([1])) }
        try reject("oversized round") { _ = try ClusterBootstrapRound(identity: identity(0), sequence: 0, contribution: Data(count: 65_537)) }
        try reject("bad rank") { _ = try identity(2) }
    }

    static func matching() throws {
        for rank in 0...1 {
            let until = deadline(), listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            var statValue = stat()
            try require(lstat(listener.socketPath, &statValue) == 0 && statValue.st_mode & 0o777 == 0o600, "socket mode")
            let process = try spawn(listener, mode: "match", rank: rank, until: until)
            let connection = try listener.accept(processID: process.processIdentifier, identity: identity(rank), deadlineUptimeNanoseconds: until)
            for sequence in 0..<(rank == 0 ? 4 : 6) {
                let round = try connection.receiveRound()
                try require(round.sequence == UInt64(sequence), "sequence changed")
                let peer = Data(repeating: 99, count: round.contribution.count)
                let gathered = rank == 0 ? round.contribution + peer : peer + round.contribution
                // Public Data may be a slice whose startIndex is not zero.
                try connection.reply(to: round, gathered: (Data([255]) + gathered).dropFirst())
            }
            try reap(process)
            try reject("listener reused") { _ = try listener.accept(processID: process.processIdentifier,
                identity: identity(rank), deadlineUptimeNanoseconds: until) }
        }
    }

    static func peerChecks() throws {
        let until = deadline(), listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
        let process = try spawn(listener, mode: "refused", until: until)
        try reject("wrong native PID accepted") { _ = try listener.accept(processID: process.processIdentifier + 1,
            identity: identity(0), deadlineUptimeNanoseconds: until) }
        try reap(process)
        let other = try ClusterBootstrapListener(deadlineUptimeNanoseconds: deadline())
        try reap(spawn(other, mode: "wrong-owner", until: deadline(), ownerPID: getpid() + 1))
    }

    static func invalidStreams() throws {
        for mode in ["partial", "oversized", "stale", "wrong-rank", "slow"] {
            let until = deadline(200), listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let process = try spawn(listener, mode: mode, until: until)
            let connection = try listener.accept(processID: process.processIdentifier, identity: identity(0), deadlineUptimeNanoseconds: until)
            try reject("bad stream accepted: \(mode)") { _ = try connection.receiveRound() }
            try reject("poisoned stream reused") { _ = try connection.receiveRound() }
            try reap(process)
        }
    }

    static func lifecycle() throws {
        do {
            let until = deadline(), listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let process = try spawn(listener, mode: "refused", until: until)
            let connection = try listener.accept(processID: process.processIdentifier, identity: identity(0), deadlineUptimeNanoseconds: until)
            let round = try connection.receiveRound()
            try reject("altered local echo accepted") { try connection.reply(to: round, gathered: Data(repeating: 9, count: 8)) }
            try reap(process)
        }
        do {
            let until = deadline(), listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let process = try spawn(listener, mode: "idle", until: until)
            let connection = try listener.accept(processID: process.processIdentifier, identity: identity(0), deadlineUptimeNanoseconds: until)
            let completion = Completion()
            DispatchQueue.global().async {
                do { _ = try connection.receiveRound(); completion.finish(TestFailure.failed("cancelled read returned")) }
                catch { completion.finish(error) }
            }
            usleep(20_000); connection.cancel()
            let error = try completion.wait()
            try require(error is ClusterBootstrapError, "cancel failed to interrupt read")
            try reap(process)
        }
        do {
            let until = deadline(), listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: until)
            let process = try spawn(listener, mode: "refused", until: until)
            let connection = try listener.accept(processID: process.processIdentifier, identity: identity(0), deadlineUptimeNanoseconds: until)
            _ = try connection.receiveRound()
            try reject("second read with pending round") { _ = try connection.receiveRound() }
            try reap(process)
        }
        do {
            let listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: deadline(1000)), began = DispatchTime.now().uptimeNanoseconds
            try reject("shorter accept deadline ignored") { _ = try listener.accept(processID: getpid(),
                identity: identity(0), deadlineUptimeNanoseconds: deadline(50)) }
            try require(DispatchTime.now().uptimeNanoseconds - began < 300_000_000, "accept did not charge shorter deadline")
        }
        var path = ""
        do { let listener = try ClusterBootstrapListener(deadlineUptimeNanoseconds: deadline()); path = listener.socketPath }
        try require(!FileManager.default.fileExists(atPath: path), "private socket path leaked")
    }
}
