import Dispatch
import Foundation
@testable import SandboxRuntime

/// Test hooks must eventually release the production reaper even when an
/// assertion fails or a CI executor stops scheduling the test continuation.
final class ProcessRaceGate: @unchecked Sendable {
    private let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let maximumWait: DispatchTimeInterval
    private var observed = false
    private var expired = false

    init(maximumWait: DispatchTimeInterval = .seconds(5)) {
        self.maximumWait = maximumWait
    }

    var didExpire: Bool { lock.lock(); defer { lock.unlock() }; return expired }

    func blockReaper() {
        lock.lock(); observed = true; lock.unlock()
        if proceed.wait(timeout: .now() + maximumWait) != .success {
            lock.lock(); expired = true; lock.unlock()
        }
    }

    func waitUntilObserved() async throws {
        try await ProcessRaceCompletion.wait(seconds: 5) { [self] in
            lock.lock(); defer { lock.unlock() }; return observed
        }
    }

    func release() { proceed.signal() }
}

final class ProcessRaceCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func record() { lock.lock(); completed = true; lock.unlock() }
    var isComplete: Bool { lock.lock(); defer { lock.unlock() }; return completed }

    func wait(seconds: Double) async -> Bool {
        do { try await Self.wait(seconds: seconds) { [self] in isComplete }; return true }
        catch { return false }
    }

    static func wait(seconds: Double, condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProcessRaceFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func waitForExit(_ execution: ProcessExecution) async throws {
        let completed = ProcessRaceCompletion()
        // An unstructured observer can be cancelled without a task-group scope
        // waiting forever for a broken, non-cancellable production exit signal.
        let observer = Task { await execution.waitUntilExit(); completed.record() }
        defer { observer.cancel() }
        guard await completed.wait(seconds: 10) else { throw ProcessRaceFixtureError.timedOut }
    }
}

enum ProcessRaceFixtureError: Error {
    case identityUnavailable
    case timedOut
    case childWaitFailed
}
