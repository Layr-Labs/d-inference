import Foundation
import SandboxRuntimeVZ

enum AccountlessGUISession {
    /// Drain both tasks before returning. A session error must not hide the
    /// operation's later failure to stop its VM or cancel an OS installation.
    static func run<Value: Sendable>(operation: @escaping @Sendable () async throws -> Value,
                                    monitor: @escaping @Sendable () async throws -> Void) async throws -> Value {
        try Task.checkCancellation()
        let completed: Result<Value, any Error> = await withTaskGroup(of: Event<Value>.self) { group in
            group.addTask {
                do { return .operation(.success(try await operation())) }
                catch { return .operation(.failure(error)) }
            }
            group.addTask {
                do { try await monitor(); return .session(SandboxGUISessionError.changed) }
                catch { return .session(error) }
            }
            guard let first = await group.next() else { return .failure(SandboxGUISessionError.changed) }
            group.cancelAll()
            var operationResult: Result<Value, any Error>?
            var sessionError: (any Error)?
            switch first {
            case .operation(let result): operationResult = result
            case .session(let error): sessionError = error
            }
            for await event in group {
                if case .operation(let result) = event { operationResult = result }
            }
            guard let result = operationResult else { return .failure(SandboxGUISessionError.changed) }
            if case .failure(let error) = result, !(error is CancellationError) { return .failure(error) }
            if let sessionError { return .failure(sessionError) }
            return result
        }
        return try completed.get()
    }

    private enum Event<Value: Sendable>: Sendable {
        case operation(Result<Value, any Error>)
        case session(any Error)
    }
}
