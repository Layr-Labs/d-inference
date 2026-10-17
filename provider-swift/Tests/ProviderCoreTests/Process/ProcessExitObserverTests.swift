import Foundation
import Testing
@testable import ProviderCore

@Suite("Child process exit observation")
struct ProcessExitObserverTests {
    @Test("An exit that precedes the first wait is kept, and every later wait returns")
    func exitBeforeTheFirstWaitIsKept() throws {
        let process = child("/usr/bin/true")
        let childExit = ProcessExitObserver()
        try childExit.run(process)
        while process.isRunning { usleep(1_000) }

        #expect(childExit.wait(timeout: 5))
        childExit.wait()
        #expect(childExit.wait(timeout: 0))
        #expect(process.terminationStatus == 0)
    }

    @Test("A timed wait reports a running child as not exited, then its exit")
    func timedWaitFollowsTheChild() throws {
        let process = child("/bin/sleep", "30")
        let childExit = ProcessExitObserver()
        try childExit.run(process)

        #expect(!childExit.wait(timeout: 0.05))
        process.terminate()
        #expect(childExit.wait(timeout: 5))
        #expect(process.terminationReason == .uncaughtSignal)
    }

    @Test("A launch that fails leaves nothing to wait for")
    func failedLaunchSettles() {
        let childExit = ProcessExitObserver()
        #expect(throws: (any Error).self) {
            try childExit.run(child("/nonexistent/darkbloom-test-command"))
        }
        #expect(childExit.wait(timeout: 0))
    }

    @Test("One observer reports one child")
    func secondStartIsRefused() throws {
        let childExit = ProcessExitObserver()
        try childExit.run(child("/usr/bin/true"))
        #expect(throws: ProcessExitObserver.AlreadyStarted.self) {
            try childExit.run(child("/usr/bin/true"))
        }
        #expect(childExit.wait(timeout: 5))
    }

    /// One thread starts the child, another reads its output to the end and
    /// then waits for the exit, session after session on recycled dispatch
    /// threads. This is the shape in which `Process.waitUntilExit()` never
    /// returns: measured on macOS 27.2, 103 of 300 such sessions were lost
    /// when the waiting thread called it. The share depends on which earlier
    /// `Process` addresses the waiting thread happens to hold, so one session
    /// proves nothing; this many do.
    @Test("An exit is reported in every session when another thread waits")
    func exitIsReportedToAnotherThreadInEverySession() throws {
        let sessions = 60
        for number in 1...sessions {
            let session = CrossThreadSession(child("/bin/sleep", "0.02"))
            session.run()
            try session.launch?.get()
            // Stop at the first loss: each one waits out the whole five seconds.
            try #require(session.exitReported, "Session \(number) of \(sessions): exit not reported within 5 s")
        }
    }

    private func child(_ path: String, _ arguments: String...) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}

/// One child started on one dispatch thread and waited for on another. Both
/// results are written before `finished` is signalled and read only after
/// `run()` has returned, which is what makes the unlocked state safe.
private final class CrossThreadSession: @unchecked Sendable {
    private let process: Process
    private let output = Pipe()
    private let childExit = ProcessExitObserver()
    private let finished = DispatchSemaphore(value: 0)
    private(set) var launch: Result<Void, any Error>?
    private(set) var exitReported = false

    init(_ process: Process) {
        self.process = process
        process.standardOutput = output
    }

    func run() {
        DispatchQueue(label: "process-exit-observer-tests.start").async { [self] in
            launch = Result { try childExit.run(process) }
            try? output.fileHandleForWriting.close()
            DispatchQueue(label: "process-exit-observer-tests.wait").async { [self] in
                _ = output.fileHandleForReading.readDataToEndOfFile()
                exitReported = childExit.wait(timeout: 5)
                finished.signal()
            }
            // The starting thread stays busy, so the waiter gets another.
            usleep(5_000)
        }
        finished.wait()
    }
}
