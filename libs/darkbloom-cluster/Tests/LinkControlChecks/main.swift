import CryptoKit
import Darwin
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
import Foundation

// Link control channel check runner.
//
//   link-check two-process            two processes over loopback (default)
//   link-check listen <options>       one listener; secret on standard input
//   link-check probe  <options>       one measuring client; secret on standard input
//
// Options: --interface NAME --local-address A --peer-address A --port N
//   --policy thunderboltOnly|thunderboltOrWired|loopbackForTests --epoch UUID --edge UUID
//   --seconds S --pings N --spaced N --gaps us,us --typed N --bulk-frames N --bulk-bytes N
//   --no-reverse --resume-seconds S --connect-seconds S --heartbeat-ms N --silence-ms N
//
// The secret is one hex line on standard input, never an argument. Output
// names interfaces and counts, never addresses. A loopback pass is not a
// hardware pass.

let standardOutput = FileHandle.standardOutput
@Sendable func emit(_ line: String) { standardOutput.write(Data((line + "\n").utf8)) }

struct Arguments {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    init(_ list: ArraySlice<String>) throws {
        var iterator = list.makeIterator()
        while let item = iterator.next() {
            guard item.hasPrefix("--") else { throw CheckError("unexpected argument") }
            let name = String(item.dropFirst(2))
            if ["no-reverse"].contains(name) { flags.insert(name); continue }
            guard let value = iterator.next() else { throw CheckError("missing value for \(name)") }
            values[name] = value
        }
    }
    func string(_ name: String) -> String? { values[name] }
    func int(_ name: String, _ fallback: Int) -> Int { values[name].flatMap(Int.init) ?? fallback }
    func double(_ name: String, _ fallback: Double) -> Double { values[name].flatMap(Double.init) ?? fallback }
}

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func options(from arguments: Arguments) throws -> ClusterLinkControlQualification.Options {
    guard let interface = arguments.string("interface"),
          let policy = ClusterLinkInterfacePolicy(rawValue: arguments.string("policy") ?? "thunderboltOnly"),
          let epoch = arguments.string("epoch").flatMap(UUID.init(uuidString:)),
          let edge = arguments.string("edge").flatMap(UUID.init(uuidString:)) else {
        throw CheckError("--interface, --epoch and --edge are required; --policy must be known")
    }
    func address(_ name: String) throws -> ClusterLinkIPv4Address? {
        guard let text = arguments.string(name) else { return nil }
        guard let value = ClusterLinkIPv4Address(text) else { throw CheckError("--\(name) is not an IPv4 address") }
        return value
    }
    var result = ClusterLinkControlQualification.Options(interface: interface, localAddress: try address("local-address"),
        peerAddress: try address("peer-address"), port: UInt16(arguments.int("port", Int(ClusterLinkControlListener.defaultPort))),
        policy: policy, epoch: epoch, edgeID: edge)
    result.seconds = arguments.double("seconds", 600)
    result.resumeSeconds = arguments.double("resume-seconds", 0)
    result.connectSeconds = arguments.double("connect-seconds", 20)
    result.probe.pings = arguments.int("pings", result.probe.pings)
    result.probe.spacedPings = arguments.int("spaced", result.probe.spacedPings)
    if let gaps = arguments.string("gaps") {
        result.probe.pingGapsMicroseconds = gaps.split(separator: ",").compactMap { UInt32($0) }
    }
    result.probe.typedEchoes = arguments.int("typed", result.probe.typedEchoes)
    result.probe.bulkFrames = arguments.int("bulk-frames", result.probe.bulkFrames)
    result.probe.bulkFrameBytes = arguments.int("bulk-bytes", result.probe.bulkFrameBytes)
    result.probe.reverseBulk = !arguments.flags.contains("no-reverse")
    if let value = arguments.string("heartbeat-ms").flatMap(Int.init) { result.limits.heartbeatInterval = .milliseconds(value) }
    if let value = arguments.string("silence-ms").flatMap(Int.init) { result.limits.silenceTimeout = .milliseconds(value) }
    return result
}

func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

// MARK: Child process control (two-process check)

final class Child: @unchecked Sendable {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let condition = NSCondition()
    private var lines: [String] = []
    private var finished = false

    init(executable: String, arguments: [String], secretHex: String) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        input.fileHandleForWriting.write(Data((secretHex + "\n").utf8))
        let handle = output.fileHandleForReading
        Thread.detachNewThread { [self] in
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    condition.withLock { lines.append(line); condition.broadcast() }
                }
            }
            condition.withLock { finished = true; condition.broadcast() }
        }
    }

    func waitForLine(prefix: String, seconds: Double) -> String? {
        let deadline = Date(timeIntervalSinceNow: seconds)
        condition.lock(); defer { condition.unlock() }
        while true {
            if let line = lines.first(where: { $0.hasPrefix(prefix) }) { return line }
            if finished || !condition.wait(until: deadline) { return lines.first(where: { $0.hasPrefix(prefix) }) }
        }
    }

    var allLines: [String] { condition.withLock { lines } }

    /// Closes standard input (the child's signal to finish) and waits.
    func finish(seconds: Double = 10) -> String? {
        try? input.fileHandleForWriting.close()
        let summary = waitForLine(prefix: "SUMMARY ", seconds: seconds)
        process.waitUntilExit()
        return summary
    }

    func kill() {
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        try? input.fileHandleForWriting.close()
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ClusterLinkControlEvent] = []
    func record(_ event: ClusterLinkControlEvent) { lock.withLock { events.append(event) } }
    var all: [ClusterLinkControlEvent] { lock.withLock { events } }
    func count(_ match: (ClusterLinkControlEvent) -> Bool) -> Int { all.filter(match).count }
}

func randomHex(_ bytes: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
}

func hexData(_ hex: String) -> Data {
    var data = Data(); var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

nonisolated(unsafe) var failures = 0
func check(_ condition: Bool, _ label: String) {
    emit((condition ? "PASS " : "FAIL ") + label)
    if !condition { failures += 1 }
}

func twoProcess(executable: String) throws {
    let epoch = UUID(), edgeID = UUID()
    let secretHex = randomHex(32)
    var limits = ClusterLinkControlLimits()
    limits.heartbeatInterval = .milliseconds(200)
    limits.silenceTimeout = .milliseconds(1500)
    limits.reconnectMaximumDelay = .milliseconds(200)
    let key = try ClusterLinkControlKey.qualification(secret: hexData(secretHex), epoch: epoch, edgeID: edgeID)
    let edge = try ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: key, peerAddress: .loopback, limits: limits)
    func listenArguments(port: UInt16, epoch: UUID = epoch) -> [String] {
        ["listen", "--interface", "lo0", "--policy", "loopbackForTests", "--port", String(port),
         "--epoch", epoch.uuidString, "--edge", edgeID.uuidString, "--seconds", "60",
         "--heartbeat-ms", "200", "--silence-ms", "1500"]
    }

    // A. Child listener, this process connects; then the child is killed and restarted.
    var child = try Child(executable: executable, arguments: listenArguments(port: 0), secretHex: secretHex)
    guard let portLine = child.waitForLine(prefix: "PORT ", seconds: 10), let port = UInt16(portLine.dropFirst(5)) else {
        child.kill(); throw CheckError("listener did not report a port")
    }
    let recorder = Recorder()
    let probe = ClusterLinkControlProbe()
    let client = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: port,
        policy: .loopbackForTests, edge: edge)) { event, peer in recorder.record(event); probe.handle(event, peer: peer) }
    client.start()
    check(client.peer.waitUntilConnected(timeout: .seconds(5)), "A1 connected to a listener in another process (secret over stdin)")
    var options = ClusterLinkControlProbe.Options()
    options.pings = 2000; options.spacedPings = 200; options.pingGapsMicroseconds = [1000]
    options.typedEchoes = 300; options.bulkFrames = 128; options.bulkFrameBytes = 1 << 20
    let report = try probe.run(peer: client.peer, options: options)
    emit("REPORT loopback " + json(report))
    check(report.latency.count == 4 && report.throughput.count == 2, "A2 ping, typed echo and 1 MiB throughput both directions measured")
    let killedAt = DispatchTime.now().uptimeNanoseconds
    child.kill()
    child = try Child(executable: executable, arguments: listenArguments(port: port), secretHex: secretHex)
    _ = child.waitForLine(prefix: "PORT ", seconds: 10)
    var resumed = false
    let resumeDeadline = Date(timeIntervalSinceNow: 10)
    while Date() < resumeDeadline {
        if recorder.count({ if case .peerRestarted = $0 { return true }; return false }) >= 1, client.peer.status.connected { resumed = true; break }
        usleep(5000)
    }
    let outage = Double(DispatchTime.now().uptimeNanoseconds - killedAt) / 1e6
    check(resumed, "A3 listener killed (SIGKILL) and restarted: client reconnected and reported the peer restart")
    emit(String(format: "INFO A3 kill-to-resumed %.1f ms (includes starting the new process)", outage))
    let echo = ClusterLinkControlProbe.Options()
    var small = echo; small.pings = 100; small.spacedPings = 0; small.pingGapsMicroseconds = []; small.typedEchoes = 20; small.bulkFrames = 4
    let after = try probe.run(peer: client.peer, options: small)
    check(after.latency.contains { $0.label == "typed-message-echo" && $0.count == 20 }, "A4 typed messages flow again after the restart")
    client.stop()
    let summaryA = child.finish()
    check(summaryA?.contains("\"sessions\":1") == true, "A5 restarted listener saw exactly one session")

    // B. Wrong secret and wrong epoch: refused by the listener, never connected.
    for (label, arguments, secret, reason) in [
        ("B1 wrong secret", listenArguments(port: 0), randomHex(32), "authenticationFailed"),
        ("B2 wrong epoch", listenArguments(port: 0, epoch: UUID()), secretHex, "wrongEpoch"),
    ] {
        let wrong = try Child(executable: executable, arguments: arguments, secretHex: secret)
        guard let line = wrong.waitForLine(prefix: "PORT ", seconds: 10), let wrongPort = UInt16(line.dropFirst(5)) else {
            wrong.kill(); throw CheckError("listener did not report a port")
        }
        let refused = try ClusterLinkControlClient(configuration: .init(interface: "lo0", port: wrongPort,
            policy: .loopbackForTests, edge: edge)) { _, _ in }
        refused.start()
        let connected = refused.peer.waitUntilConnected(timeout: .seconds(2))
        refused.stop()
        let summary = wrong.finish() ?? ""
        check(!connected && summary.contains("\(reason)"), "\(label): refused by the listener (\(reason)), no session")
    }

    // C. This process listens; a child client measures, then is killed mid-run and restarted.
    let listenRecorder = Recorder()
    let responder = ClusterLinkControlProbe()
    let listener = try ClusterLinkControlListener(configuration: .init(interface: "lo0", port: 0,
        policy: .loopbackForTests, edges: [try ClusterLinkControlEdge(edgeID: edgeID, epoch: epoch, key: key,
            peerAddress: .loopback, limits: limits)])) { event, peer in listenRecorder.record(event); responder.handle(event, peer: peer) }
    let listenPort = try listener.start()
    func probeArguments() -> [String] {
        ["probe", "--interface", "lo0", "--policy", "loopbackForTests", "--peer-address", "127.0.0.1",
         "--port", String(listenPort), "--epoch", epoch.uuidString, "--edge", edgeID.uuidString,
         "--pings", "200", "--spaced", "0", "--gaps", "", "--typed", "50", "--bulk-frames", "8",
         "--resume-seconds", "3", "--heartbeat-ms", "200", "--silence-ms", "1500"]
    }
    let first = try Child(executable: executable, arguments: probeArguments(), secretHex: secretHex)
    let firstConnected = listener.peer(for: edgeID)!.waitUntilConnected(timeout: .seconds(5))
    usleep(800_000)
    first.kill()
    let second = try Child(executable: executable, arguments: probeArguments(), secretHex: secretHex)
    let summaryC = second.finish(seconds: 30) ?? ""
    let restarts = listenRecorder.count { if case .peerRestarted = $0 { return true }; return false }
    check(firstConnected && restarts >= 1, "C1 client killed (SIGKILL) mid-run: listener reported the restart of the new client")
    check(summaryC.contains("\"report\":{") && summaryC.contains("\"unacknowledgedAtEnd\":0"),
          "C2 restarted client measured and ended with every message acknowledged")
    emit("SUMMARY-C " + summaryC.dropFirst("SUMMARY ".count))
    listener.stop()
}

// MARK: Entry

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "two-process"
do {
    switch mode {
    case "two-process":
        try twoProcess(executable: URL(fileURLWithPath: arguments[0]).standardizedFileURL.path)
        emit(failures == 0 ? "LINK CONTROL TWO-PROCESS CHECKS PASSED" : "LINK CONTROL TWO-PROCESS CHECKS FAILED: \(failures)")
        exit(failures == 0 ? 0 : 1)
    case "listen":
        let parsed = try options(from: try Arguments(arguments.dropFirst(2)))
        let secret = try ClusterLinkControlQualification.readSecret()
        let summary = try ClusterLinkControlQualification.listen(options: parsed, secret: secret, output: emit)
        emit("SUMMARY " + json(summary))
    case "probe":
        let parsed = try options(from: try Arguments(arguments.dropFirst(2)))
        let secret = try ClusterLinkControlQualification.readSecret()
        let summary = try ClusterLinkControlQualification.probe(options: parsed, secret: secret, output: emit)
        emit("SUMMARY " + json(summary))
        exit(summary.report == nil ? 2 : 0)
    default:
        throw CheckError("unknown mode")
    }
} catch {
    emit("ERROR \(error)")
    exit(1)
}
