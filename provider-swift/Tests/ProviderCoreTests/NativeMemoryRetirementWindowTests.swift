import Foundation
import Testing

@testable import ProviderCore

@Suite("Bounded native physical-reclaim window")
struct NativeMemoryRetirementWindowTests {
    @Test func expiresFromRetirementNotFromEveryLoadAttempt() {
        let start = ContinuousClock.now
        let window = NativeMemoryRetirementWindow(retiredAt: start)
        #expect(window.nextDelay(now: start) == .milliseconds(25))
        #expect(window.nextDelay(now: start.advanced(by: .milliseconds(1990))) == .milliseconds(10))
        #expect(window.nextDelay(now: start.advanced(by: .seconds(2))) == nil)
        #expect(window.nextDelay(now: start.advanced(by: .seconds(3))) == nil)
    }

    @Test func expiredWindowDoesNotPause() async throws {
        let window = NativeMemoryRetirementWindow(retiredAt: .now.advanced(by: .seconds(-3)))
        #expect(try await window.pauseForRecheck() == false)
    }

    @Test func cancelledLoadDoesNotWaitOrGainAdmission() async {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await NativeMemoryRetirementWindow().pauseForRecheck()
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation must propagate out of the reclaim recheck")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected reclaim error: \(error)")
        }
    }
}
