import Foundation

/// Owns only cache-eligible preparation tasks. Closing signals cancellation
/// synchronously; draining waits for actual completion without refunding work
/// which is still waiting for the model container or executing native code.
final class VisionFeaturePreparationOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var closed = false
    private var tasks: [UUID: @Sendable () -> Void] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 128) { self.limit = max(0, limit) }

    /// A full owner declines optional caching before launching a task. The
    /// caller retains the ordinary uncached preparation path and its admission.
    func perform<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value? {
        try Task.checkCancellation()
        let registered: (UUID, Task<Value, Error>)? = try lock.withLock {
            guard !closed else { throw CancellationError() }
            guard tasks.count < limit else { return nil }
            let id = UUID()
            let task = Task {
                try Task.checkCancellation()
                return try await operation()
            }
            // Register before close can observe the owner. Even a task that
            // completes immediately remains owned until its caller joins it.
            tasks[id] = { task.cancel() }
            return (id, task)
        }
        guard let (id, task) = registered else { return nil }
        defer { finished(id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func close() {
        let cancel = lock.withLock {
            closed = true
            return Array(tasks.values)
        }
        for operation in cancel { operation() }
    }

    var isClosed: Bool { lock.withLock { closed } }

    var isDrained: Bool { lock.withLock { closed && tasks.isEmpty } }

    func drain() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if tasks.isEmpty { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func finished(_ id: UUID) {
        let resume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            tasks.removeValue(forKey: id)
            guard tasks.isEmpty else { return [] }
            let result = waiters
            waiters.removeAll()
            return result
        }
        for waiter in resume { waiter.resume() }
    }
}
