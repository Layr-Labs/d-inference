import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// `BoundedCommand` on the paths a real system rarely takes, through `BoundedCommandHooks`: a failed setup step starts
/// nothing and leaves nothing open, an interrupted wait goes on, a child another reaper took is never signalled, and a
/// failed wait falls back to polling that still stops and reaps the child.
@Suite("Bounded command: setup failures and wait paths")
struct BoundedCommandTests {
    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Records the processes a hook signalled.
    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: [pid_t] = []
        func note(_ pid: pid_t) { lock.withLock { pids.append(pid) } }
        var all: [pid_t] { lock.withLock { pids } }
    }

    /// A counter a hook can step through.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    @Test("each failing setup step starts no child and leaves no descriptor open")
    func setupFailures() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Which steps there are: each one, failed, starts nothing; the run past the last one starts the child.
        var failedSteps: [Int] = []
        var step = 1
        while true {
            let marker = directory.appendingPathComponent("ran-\(step)").path
            var hooks = BoundedCommandHooks.live
            hooks.failingSetupStep = step
            do {
                _ = try BoundedCommand.run("/bin/sh", ["-c", "touch '\(marker)'"], timeout: 5, outputLimit: 1_024,
                                           hooks: hooks)
                #expect(FileManager.default.fileExists(atPath: marker), "the first step past the setup runs it")
                break
            } catch {
                #expect(error is POSIXError, "step \(step): \(error)")
                #expect(!FileManager.default.fileExists(atPath: marker), "step \(step): no child started")
                failedSteps.append(step)
            }
            step += 1
            try #require(step <= 40, "the setup has a bounded number of steps")
        }
        #expect(failedSteps == Array(1...20), "two pipes of five steps and a spawn of ten")

        // Each step failed a hundred times more: a step that left one descriptor open would add a hundred, which
        // fails the check; growth below that is what other tests open meanwhile.
        let before = try OpenDescriptors.count()
        for _ in 0..<100 {
            for step in failedSteps {
                var hooks = BoundedCommandHooks.live
                hooks.failingSetupStep = step
                #expect(throws: POSIXError.self, "step \(step)") {
                    _ = try BoundedCommand.run("/usr/bin/true", [], timeout: 5, outputLimit: 1_024, hooks: hooks)
                }
            }
        }
        let growth = try await OpenDescriptors.settledGrowth(since: before)
        #expect(growth < 100, "\(growth) more descriptors open after \(100 * failedSteps.count) failed setups")
    }

    @Test("an interrupted wait for the exit is made again")
    func interruptedWait() throws {
        let calls = Calls()
        var hooks = BoundedCommandHooks.live
        hooks.waitForExit = { pid in
            calls.next() == 1 ? (-1, EINTR) : BoundedCommandHooks.live.waitForExit(pid)
        }
        let result = try BoundedCommand.run("/bin/sh", ["-c", "printf done; exit 3"], timeout: 5, outputLimit: 1_024,
                                            hooks: hooks)
        #expect(result.terminationStatus == 3 && result.stdout == "done")
    }

    @Test("a child another reaper took is never signalled, and its exit is reported as unseen")
    func childReapedElsewhere() throws {
        let signals = Signals()
        var hooks = BoundedCommandHooks.live
        // Another reaper takes the child first: this wait then finds no child of its own.
        hooks.waitForExit = { pid in
            _ = BoundedCommandHooks.live.reap(pid, 0)
            return (-1, ECHILD)
        }
        hooks.signal = { signals.note($0) }
        #expect(throws: SecurityCommandRunner.CommandError.exitUnobserved) {
            _ = try BoundedCommand.run("/bin/sh", ["-c", "exit 0"], timeout: 5, outputLimit: 1_024, hooks: hooks)
        }
        #expect(signals.all.isEmpty, "no signal to a process that isn't ours")
    }

    @Test("a failed wait falls back to polling: a still-running child is reaped when it exits")
    func pollingReaps() throws {
        let polls = Calls()
        var hooks = BoundedCommandHooks.live
        hooks.waitForExit = { _ in (-1, EINVAL) }
        hooks.reap = { pid, options in
            // Twice "still running", then the real nonblocking reap.
            polls.next() <= 2 ? (0, 0, 0) : BoundedCommandHooks.live.reap(pid, options)
        }
        let result = try BoundedCommand.run("/bin/sh", ["-c", "exit 7"], timeout: 5, outputLimit: 1_024, hooks: hooks)
        #expect(result.terminationStatus == 7)
    }

    @Test("a failed wait still lets a timeout stop the child, which polling then reaps")
    func pollingStopsAndReaps() throws {
        let signals = Signals()
        var hooks = BoundedCommandHooks.live
        hooks.waitForExit = { _ in (-1, EINVAL) }
        hooks.signal = { pid in
            signals.note(pid)
            BoundedCommandHooks.live.signal(pid)
        }
        #expect(throws: SecurityCommandRunner.CommandError.timedOut) {
            _ = try BoundedCommand.run("/bin/sh", ["-c", "exec sleep 30"], timeout: 0.5, outputLimit: 1_024,
                                       hooks: hooks)
        }
        let pid = try #require(signals.all.first)
        #expect(signals.all.count == 1)
        let deadline = ContinuousClock.now + .seconds(5)
        while Darwin.kill(pid, 0) == 0, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH, "stopped and reaped: no process, not even a zombie")
    }
}

/// The descriptors this test process has open. Other tests open and close descriptors meanwhile, so a check counts
/// only growth on the scale of descriptors left open, and takes the least of a few counts over about a second:
/// those stay open.
enum OpenDescriptors {
    static func count() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    static func settledGrowth(since before: Int) async throws -> Int {
        var least = try count() - before
        var counts = 1
        while least > 0, counts < 6 {
            try await Task.sleep(for: .milliseconds(200))
            least = min(least, try count() - before)
            counts += 1
        }
        return least
    }
}
