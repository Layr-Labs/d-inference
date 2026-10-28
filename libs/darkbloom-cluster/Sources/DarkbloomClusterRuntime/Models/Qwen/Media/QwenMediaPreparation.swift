import Foundation

/// One charged host preparation. Cancellation requests stop but does not prove
/// release: the executor retains this owner and its allowance until `finished`.
/// Only ordinary host values leave the task; no model or lazy MLX graph does.
final class QwenMediaPreparation: @unchecked Sendable {
    enum Outcome: Equatable { case pending, prepared, failed, cancelled }
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var values: [[Float]]?
    private var failure: Error?
    private var done = false
    private var cancelled = false

    func start(_ body: @escaping @Sendable () async throws -> [[Float]]) throws {
        try lock.withLock {
            guard task == nil, !done, !cancelled else {
                throw ProbeError("Qwen media preparation was already started or retired")
            }
            let producer = Task.detached { [self] in
                let result: Result<[[Float]], Error>
                do { result = .success(try await body()) }
                catch { result = .failure(error) }
                lock.withLock {
                    // Results created after cancellation never become visible.
                    if !cancelled {
                        switch result {
                        case .success(let prepared): values = prepared
                        case .failure(let error): failure = error
                        }
                    }
                }
            }
            task = producer
            // Publishing from inside the producer would precede destruction of
            // its local result and captured decoder. Wait for the entire task,
            // including closure teardown, before allowing the charge to retire.
            Task.detached { [self] in
                await producer.value
                lock.withLock { done = true }
            }
        }
    }
    var finished: Bool { lock.withLock { task == nil || done } }
    var outcome: Outcome { lock.withLock {
        guard done else { return .pending }
        if cancelled { return .cancelled }
        return values == nil ? .failed : .prepared
    } }
    /// The ended task's own error, unconsumed, when it failed.
    var error: Error? { lock.withLock { done && !cancelled ? failure : nil } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
    func take() throws -> [[Float]] {
        try lock.withLock {
            guard done, !cancelled else { throw ProbeError("Qwen media preparation is unfinished or cancelled") }
            if let failure { throw failure }
            guard let values else { throw ProbeError("Qwen media preparation has no unconsumed result") }
            self.values = nil
            return values
        }
    }
    /// Releases host payloads only after their producing task ended. Returning
    /// false keeps the owner's bytes charged while AVFoundation unwinds.
    @discardableResult func releaseIfFinished() -> Bool {
        lock.withLock {
            guard task == nil || done else { return false }
            task = nil; values = nil; failure = nil; done = true; cancelled = true
            return true
        }
    }
}
