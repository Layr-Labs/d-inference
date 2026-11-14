import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

// A launch's check runs on the spawned child before that child has executed
// anything: the kernel reports it stopped, with no process of its own. A
// refusal kills and reaps the child before the launch fails, and nothing is
// written to its input; an accepted child is resumed and runs normally. The
// child is this binary in `--record` mode: it keeps the first line it reads
// from its input in the named file.

private struct Failure: Error, CustomStringConvertible { let description: String }
private struct Refused: Error {}
private func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw Failure(description: message()) }
}

extension LaunchStates {
    func requireUnstarted(_ what: String) throws -> pid_t {
        switch unstarted() {
        case .success(let pid): return pid
        case .failure(let fault): throw Failure(description: "\(what): \(fault)")
        }
    }
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
            try acceptedWorker(directory)
            try refusedWorker(directory)
            print("{\"passed\":true,\"groups\":2,\"launchCheckedBeforeTheChildRuns\":true,\"modelOrGPUExecution\":false}")
        } catch {
            FileHandle.standardError.write(Data("FAILED \(error)\n".utf8)); exit(1)
        }
    }

    static func worker(_ file: URL, verify: (@Sendable (pid_t) throws -> Void)?) throws -> ClusterWorkerProcess {
        let now = DispatchTime.now().uptimeNanoseconds
        return try ClusterWorkerProcess(launch: .init(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
                arguments: ["--record", file.path], environment: [:], initialInput: secret, verifyLaunched: verify),
            expectedIdentity: fixtureIdentity, rank: 0, profile: fixtureProfile, executionPlanSHA256: fixturePlan,
            startupDeadline: now + 5_000_000_000, initialLeaseDeadline: now + 5_000_000_000)
    }

    /// The check sees a child that has not run; once accepted, the child runs,
    /// reads its input and its exit is reported.
    static func acceptedWorker(_ directory: URL) throws {
        let file = directory.appendingPathComponent("worker-accepted"), states = LaunchStates()
        let accepted = try worker(file, verify: { states.record($0) })
        try accepted.launch()
        let pid = try states.requireUnstarted("accepted worker")
        try require(accepted.launchedProcessIdentifier == pid, "the checked child is not the launched one")
        try require(accepted.waitForExit(until: DispatchTime.now().uptimeNanoseconds + 5_000_000_000), "the accepted worker did not exit")
        try require(accepted.termination == .exited(0) && accepted.observedExit, "the accepted worker's exit was not reported")
        try require((try? Data(contentsOf: file)) == secret, "the accepted worker did not receive its input")
        try require(launchedChildReaped(pid), "the accepted worker was not reaped")
        accepted.fence()
    }

    /// A refused child is killed and reaped before the launch fails like one
    /// that could not start, and its input line is never written.
    static func refusedWorker(_ directory: URL) throws {
        let file = directory.appendingPathComponent("worker-refused"), states = LaunchStates()
        let refused = try worker(file, verify: { states.record($0); throw Refused() })
        var threw = false
        do { try refused.launch() } catch is Refused { threw = true }
        try require(threw, "a refused worker launch did not fail with the check's error")
        let pid = try states.requireUnstarted("refused worker")
        try require(launchedChildReaped(pid), "a refused worker was not killed and reaped before its launch failed")
        try require(refused.termination == .launchFailed && refused.observedExit && refused.launchedProcessIdentifier == nil,
            "a refused worker launch did not fail as a launch")
        Thread.sleep(forTimeInterval: 0.3)
        try require(!FileManager.default.fileExists(atPath: file.path), "a refused worker received its input")
    }
}
