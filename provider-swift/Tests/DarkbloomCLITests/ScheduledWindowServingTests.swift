import Foundation
import Testing
@testable import darkbloom

@Suite("Scheduled serving: the end of a window")
struct ScheduledWindowServingTests {
    private struct RestartNeeded: Error {}

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// The serving loop's wait for the window's close (its cancellation), within a bound: a window that never
    /// closes fails the test instead of hanging it.
    private static func untilCancelled() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Cleanup that a cancelled task still waits for.
    private static func cleanup() async {
        await Task.detached { try? await Task.sleep(for: .milliseconds(300)) }.value
    }

    @Test func anErrorTheLoopEndsWithAfterTheWindowClosesEndsTheSchedule() async {
        let closed = Flag()
        await #expect(throws: RestartNeeded.self, "no later window starts another loop in this process") {
            _ = try await ScheduledWindowServing.run(until: Date().addingTimeInterval(0.2)) {
                await Self.untilCancelled()
                if Task.isCancelled { closed.set() }
                await Self.cleanup()
                throw RestartNeeded()
            }
        }
        #expect(closed.isSet, "the window closed first")
    }

    @Test func aLoopThatEndsNormallyAfterTheWindowClosesLetsTheNextWindowBegin() async throws {
        let cleanedUp = Flag()
        let outcome = try await ScheduledWindowServing.run(until: Date().addingTimeInterval(0.2)) {
            await Self.untilCancelled()
            await Self.cleanup()
            cleanedUp.set()
        }
        #expect(outcome == .windowClosed)
        #expect(cleanedUp.isSet, "the loop's end comes before the next window")
    }

    @Test func aLoopThatEndsWithACancellationErrorAfterTheWindowClosesLetsTheNextWindowBegin() async throws {
        let outcome = try await ScheduledWindowServing.run(until: Date().addingTimeInterval(0.2)) {
            await Self.untilCancelled()
            throw CancellationError()
        }
        #expect(outcome == .windowClosed)
    }

    @Test func aCancelledScheduleWaitsForTheLoopsCleanupAndReportsNoWindowsEnd() async throws {
        let entered = Flag()
        let cleanedUp = Flag()
        let ended = Flag()
        let schedule = Task { () -> ScheduledWindowServing.Outcome? in
            defer { ended.set() }
            return try? await ScheduledWindowServing.run(until: Date().addingTimeInterval(3600)) {
                entered.set()
                await Self.untilCancelled()
                await Self.cleanup()
                cleanedUp.set()
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !entered.isSet, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(entered.isSet, "the loop began")
        schedule.cancel()
        while !ended.isSet, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ended.isSet)
        // Only a task that has ended is awaited: one that went on would fail here, not hang the run.
        if ended.isSet {
            #expect(await schedule.value != .windowClosed, "a cancelled schedule isn't a window's end")
            #expect(cleanedUp.isSet, "the loop's cleanup came first")
        }
    }

    @Test func aLoopThatEndsBeforeTheWindowClosesEndsIt() async throws {
        #expect(try await ScheduledWindowServing.run(until: Date().addingTimeInterval(60)) {} == .loopEnded)
        #expect(try await ScheduledWindowServing.run(until: nil) {} == .loopEnded)
        await #expect(throws: RestartNeeded.self) {
            _ = try await ScheduledWindowServing.run(until: Date().addingTimeInterval(60)) { throw RestartNeeded() }
        }
    }
}
