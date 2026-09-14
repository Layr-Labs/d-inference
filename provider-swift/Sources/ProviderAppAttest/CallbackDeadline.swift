import Foundation

/// Apple callbacks cannot be cancelled. Resume our caller once at the deadline;
/// a late callback is harmless. This avoids a task-group timeout that waits
/// forever for a child suspended on a continuation.
final class CallbackDeadline<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation=continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let current=continuation; continuation=nil; lock.unlock()
        current?.resume(with:result)
    }
    static func call(seconds: Double = 25, start: @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let gate=CallbackDeadline(continuation)
            start { gate.finish($0) }
            Task {
                try? await Task.sleep(for:.seconds(seconds))
                gate.finish(.failure(ShadowFailure.operationTimeout))
            }
        }
    }
}
