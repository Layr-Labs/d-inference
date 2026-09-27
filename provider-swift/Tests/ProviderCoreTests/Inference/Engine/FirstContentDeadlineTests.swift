import Foundation
import Testing

@testable import ProviderCore

@Suite("First-content monotonic deadline")
struct FirstContentDeadlineTests {
    @Test("relative budget is anchored once and reports elapsed remaining time")
    func relativeBudgetConversion() {
        let receivedAt = ContinuousClock.now
        let deadline = FirstContentDeadline(
            relativeBudgetMilliseconds: 250,
            receivedAt: receivedAt)

        #expect(deadline.instant == receivedAt.advanced(by: .milliseconds(250)))
        #expect(
            deadline.remainingDuration(
                now: receivedAt.advanced(by: .milliseconds(100)))
                == .milliseconds(150))
        #expect(
            deadline.remainingDuration(now: deadline.instant)
                == .zero)
        #expect(
            deadline.remainingDuration(
                now: deadline.instant.advanced(by: .milliseconds(1)))
                == .milliseconds(-1))
    }

    @Test("absolute expiry throws the typed pre-content refusal")
    func expiryCheck() {
        let receivedAt = ContinuousClock.now
        let deadline = FirstContentDeadline(
            relativeBudgetMilliseconds: 10,
            receivedAt: receivedAt)

        #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            try deadline.check(now: deadline.instant)
        }
        #expect(throws: Never.self) {
            try deadline.check(
                now: deadline.instant.advanced(by: .milliseconds(-1)))
        }
    }

    @Test("cancellation-safe awaits race the same absolute instant")
    func deadlineRace() async throws {
        // The full suite runs thousands of tests concurrently; leave enough
        // wall time that executor saturation cannot turn this success arm into
        // a scheduler-jitter test.
        let live = FirstContentDeadline(relativeBudgetMilliseconds: 60_000)
        let value = try await live.race {
            try await Task.sleep(for: .milliseconds(1))
            return 42
        }
        #expect(value == 42)
        try live.check()

        let expiring = FirstContentDeadline(relativeBudgetMilliseconds: 20)
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await expiring.race {
                try await Task.sleep(for: .seconds(5))
                return 0
            }
        }
    }
}
