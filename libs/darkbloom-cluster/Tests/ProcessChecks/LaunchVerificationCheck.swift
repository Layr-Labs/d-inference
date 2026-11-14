import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

// A launch's verifier runs on the spawned child before anything is written to
// its input. A refusal kills the child, the launch fails, and the child never
// reads a byte. The child is this binary in `--record` mode: it keeps the
// first line it reads from its input in the named file.

private struct Failure: Error, CustomStringConvertible { let description: String }
private struct Refused: Error {}
private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw Failure(description: message()) }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [pid_t] = []
    func add(_ pid: pid_t) { lock.withLock { values.append(pid) } }
    var pids: [pid_t] { lock.withLock { values } }
}

@main struct LaunchVerificationCheck {
    static let secret = Data("credential-line-that-must-not-reach-an-unverified-child\n".utf8)

    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--record" {
            guard let line = readLine(strippingNewline: false) else { exit(0) }
            try? Data(line.utf8).write(to: URL(fileURLWithPath: arguments[2])); exit(0)
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("launch-verification-\(getpid())")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try processExit(directory)
            try workerProcess(directory)
            print("{\"passed\":true,\"groups\":2,\"launchVerifiedBeforeInput\":true,\"modelOrGPUExecution\":false}")
        } catch {
            FileHandle.standardError.write(Data("FAILED \(error)\n".utf8)); exit(1)
        }
    }

    static func recorder(_ file: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--record", file.path]
        return process
    }

    /// The verifier sees the child it launched; a refusal is thrown only after
    /// that child was killed and its exit observed.
    static func processExit(_ directory: URL) throws {
        let seen = Seen(), process = recorder(directory.appendingPathComponent("exit-refused")), exit = ClusterProcessExit()
        process.standardInput = Pipe()
        var refused = false
        do { try exit.run(process, verifyLaunched: { seen.add($0); throw Refused() }) } catch is Refused { refused = true }
        try require(refused, "a refused launch did not fail with the verifier's error")
        try require(seen.pids == [process.processIdentifier], "the verifier did not see the launched child")
        try require(exit.hasExited && process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL,
            "a refused child was not killed and reaped before the launch failed")

        let accepted = Seen(), running = recorder(directory.appendingPathComponent("exit-accepted")), other = ClusterProcessExit()
        let input = Pipe(); running.standardInput = input
        try other.run(running, verifyLaunched: { accepted.add($0) })
        try require(accepted.pids == [running.processIdentifier] && !other.hasExited, "an accepted child was not left running")
        try input.fileHandleForWriting.close()
        other.wait()
        try require(running.terminationReason == .exit && running.terminationStatus == 0, "the accepted child did not end by itself")
    }

    /// A worker whose launch is refused fails like a launch that could not
    /// start, and its credential line is never written.
    static func workerProcess(_ directory: URL) throws {
        func worker(_ file: URL, verify: (@Sendable (pid_t) throws -> Void)?) throws -> ClusterWorkerProcess {
            let now = DispatchTime.now().uptimeNanoseconds
            return try ClusterWorkerProcess(launch: .init(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
                    arguments: ["--record", file.path], environment: [:], initialInput: secret, verifyLaunched: verify),
                expectedIdentity: fixtureIdentity, rank: 0, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
                startupDeadline: now + 5_000_000_000, initialLeaseDeadline: now + 5_000_000_000)
        }
        let refusedFile = directory.appendingPathComponent("worker-refused")
        let refused = try worker(refusedFile, verify: { _ in throw Refused() })
        var threw = false
        do { try refused.launch() } catch { threw = true }
        try require(threw && refused.termination == .launchFailed && refused.observedExit
            && refused.launchedProcessIdentifier == nil, "a refused worker launch did not fail as a launch")
        Thread.sleep(forTimeInterval: 0.3)
        try require(!FileManager.default.fileExists(atPath: refusedFile.path), "a refused worker received its input")

        // The same child, accepted, reads the line: the refusal above is what kept it out.
        let acceptedFile = directory.appendingPathComponent("worker-accepted")
        let accepted = try worker(acceptedFile, verify: { _ in })
        try accepted.launch()
        try require(accepted.waitForExit(until: DispatchTime.now().uptimeNanoseconds + 5_000_000_000), "the accepted worker did not exit")
        try require((try? Data(contentsOf: acceptedFile)) == secret, "the accepted worker did not receive its input")
        accepted.fence()
    }
}
