import Foundation
import Testing
@testable import ProviderCore

@Suite("Bounded child process")
struct BoundedProcessTests {
    private let exitsAtOnce = URL(fileURLWithPath: "/usr/bin/true")

    /// `Process.waitUntilExit()` runs the calling thread's run loop for at
    /// least one 62.5 ms slice once the child is gone. Anything scheduled on
    /// that run loop then fires inside the call, and the call returns late.
    @Test("Waiting for a child does not run the calling thread's run loop")
    func callersRunLoopIsLeftAlone() throws {
        let probe = RunLoopServiceProbe()
        defer { probe.cancel() }

        try BoundedProcess.run(exitsAtOnce, arguments: [], timeout: 10)

        #expect(!probe.runLoopWasServiced)
    }

    /// Polling `isRunning` every 50 ms and then calling `waitUntilExit()` took
    /// about 120 ms to report an exited child, and never less than the 62.5 ms
    /// run-loop slice. Taking the fastest of several runs keeps a busy
    /// machine from failing this.
    @Test("A child that has exited is reported without a polling or run-loop delay")
    func exitedChildIsReportedPromptly() {
        let fastest = (0..<10).map { _ in
            outcome(of: { try BoundedProcess.run(exitsAtOnce, arguments: [], timeout: 10) }).seconds
        }.min() ?? .infinity
        #expect(fastest < 0.06)
    }

    @Test("A child that outlives its timeout is sent SIGTERM and reported as timed out")
    func timeoutSendsSIGTERM() {
        let run = outcome(of: {
            try BoundedProcess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.3)
        })
        #expect(run.timeoutLimit == 0.3)
        // SIGTERM ended it, so the two-second wait before SIGKILL never ran out.
        #expect(run.seconds >= 0.3 && run.seconds < 2)
    }

    @Test("A child that ignores SIGTERM gets it once and SIGKILL two seconds later")
    func ignoredSIGTERMEscalatesToSIGKILL() throws {
        let received = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-bounded-process-\(UUID().uuidString).signals")
        defer { try? FileManager.default.removeItem(at: received) }
        // `$0` is the file the shell appends to each time SIGTERM arrives.
        let script = "trap 'echo TERM >> \"$0\"' TERM; while :; do /bin/sleep 0.05; done"

        // One second lets a slow machine start the shell and set the trap first.
        let run = outcome(of: {
            try BoundedProcess.run(
                URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, received.path], timeout: 1)
        })

        #expect(run.timeoutLimit == 1)
        #expect(run.seconds >= 3 && run.seconds < 5)
        #expect(try String(contentsOf: received, encoding: .utf8) == "TERM\n")
    }

    private struct Outcome {
        var failure: (any Error)?
        var seconds: TimeInterval

        /// The limit carried by a `.timedOut` failure; nil for anything else.
        var timeoutLimit: TimeInterval? {
            guard case .timedOut(let limit)? = failure as? BoundedProcess.Failure else { return nil }
            return limit
        }
    }

    private func outcome(of body: () throws -> Void) -> Outcome {
        let started = ProcessInfo.processInfo.systemUptime
        var failure: (any Error)?
        do { try body() } catch { failure = error }
        return Outcome(failure: failure, seconds: ProcessInfo.processInfo.systemUptime - started)
    }
}
