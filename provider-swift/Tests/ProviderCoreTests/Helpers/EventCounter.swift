import Foundation
import XCTest

/// Counts a test double's events, and lets a test wait for a count to be reached.
final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(target: Int, expectation: XCTestExpectation)] = []
    func increment() {
        let reached = lock.withLock {
            count += 1
            let due = waiters.filter { $0.target <= count }
            waiters.removeAll { $0.target <= count }
            return due
        }
        for waiter in reached { waiter.expectation.fulfill() }
    }
    var value: Int { lock.withLock { count } }
    /// Fulfilled by the increment that reaches `target`, or at once if the
    /// count already has. A test awaits the event itself, not a clock.
    func expectation(reaching target: Int, _ description: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: description)
        let reached = lock.withLock {
            if count >= target { return true }
            waiters.append((target, expectation))
            return false
        }
        if reached { expectation.fulfill() }
        return expectation
    }
}
