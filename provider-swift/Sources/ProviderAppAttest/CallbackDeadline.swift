import Foundation

/// Apple callbacks cannot be cancelled. Resume our caller once at the deadline
/// or cancellation; a late callback is harmless. Avoid a task-group timeout that waits
/// forever for a child suspended on a continuation.
final class CallbackDeadline<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var completed = false
    private var earlyResult: Result<Value, Error>?
    private var timer: Task<Void, Never>?

    private func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result = earlyResult {
            earlyResult = nil
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func installTimer(_ timer: Task<Void, Never>) {
        lock.lock()
        let alreadyCompleted = completed
        if !alreadyCompleted { self.timer = timer }
        lock.unlock()
        if alreadyCompleted { timer.cancel() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let current = continuation
        continuation = nil
        if current == nil { earlyResult = result }
        let timer = timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        current?.resume(with: result)
    }
    static func call(seconds: Double = 25, start: @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let gate = CallbackDeadline()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                start { gate.finish($0) }
                gate.installTimer(Task {
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return }
                    gate.finish(.failure(ShadowFailure.operationTimeout))
                })
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}
