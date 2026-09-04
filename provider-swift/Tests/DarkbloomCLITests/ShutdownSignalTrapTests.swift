import Foundation
import Testing
@testable import darkbloom

/// The serve command's SIGTERM/SIGINT trap (T1-08 phase 2). These raise a
/// real signal at the test process, so the trap must be armed first — an
/// unarmed SIGTERM takes the default action and kills the runner.
@Suite("Shutdown signal trap", .serialized)
struct ShutdownSignalTrapTests {

    private func waitUntilArmed() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !ShutdownSignalTrap.isArmed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ShutdownSignalTrap.isArmed, "trap never armed")
    }

    @Test("cancelling the waiter (serve task ended) releases it without a signal")
    func cancellationReleasesWaiter() async throws {
        let waiter = Task { await ShutdownSignalTrap.waitForTermination() }
        try await waitUntilArmed()
        waiter.cancel()
        let released = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await waiter.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(released, "waiter did not release on cancellation")
        #expect(!ShutdownSignalTrap.isArmed)
    }

    @Test("the first SIGTERM releases the waiter (the graceful path), never kills the process")
    func firstSignalReleasesWaiter() async throws {
        let waiter = Task { await ShutdownSignalTrap.waitForTermination() }
        try await waitUntilArmed()
        // Exactly one signal: a second one is the forced exit by design.
        kill(getpid(), SIGTERM)
        let released = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await waiter.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(released, "SIGTERM did not release the waiter")
    }
}
