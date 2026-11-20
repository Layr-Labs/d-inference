import Foundation

/// One availability window of scheduled serving: the provider loop runs until it ends or the window closes. When the
/// window closes first, the loop is cancelled and its end awaited before the next window can begin. An error it ends
/// with then (a stop that left native model owners pending needs a process restart) is thrown, as one it ends with
/// during the window is, so no later window starts another loop in this process. A cancelled loop that returns, or
/// ends with `CancellationError`, is the window's ordinary end.
enum ScheduledWindowServing {
    enum Outcome: Equatable, Sendable {
        case loopEnded
        case windowClosed
    }

    /// `windowEnd` nil: the windows cover the full week, and only the loop's own end ends this.
    static func run(until windowEnd: Date?, serve: @escaping @Sendable () async throws -> Void) async throws -> Outcome {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                try await serve()
                return .loopEnded
            }
            if let windowEnd {
                group.addTask {
                    try await Task.sleep(nanoseconds: sleepNanoseconds(for: windowEnd.timeIntervalSinceNow))
                    return .windowClosed
                }
            }

            guard let first = try await group.next() else { return .loopEnded }
            group.cancelAll()
            guard first == .windowClosed else { return first }
            do {
                while try await group.next() != nil {}
            } catch is CancellationError {}
            return .windowClosed
        }
    }

    static func sleepNanoseconds(for interval: TimeInterval) -> UInt64 {
        let seconds = max(0.0, min(interval, Double(UInt64.max) / 1_000_000_000))
        return UInt64(seconds * 1_000_000_000)
    }
}
