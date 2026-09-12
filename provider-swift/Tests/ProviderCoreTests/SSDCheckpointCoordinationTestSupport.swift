import Foundation

enum SSDCheckpointCoordinationTestSupport {
    enum Failure: Error { case timedOut }

    static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    final class Barrier: @unchecked Sendable {
        private let condition = NSCondition()
        private var entered = false
        private var released = false

        var isEntered: Bool {
            condition.lock()
            defer { condition.unlock() }
            return entered
        }

        func block() throws {
            condition.lock()
            defer { condition.unlock() }
            entered = true
            let deadline = Date().addingTimeInterval(10)
            while !released {
                guard condition.wait(until: deadline) else { throw Failure.timedOut }
            }
        }

        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }
}
