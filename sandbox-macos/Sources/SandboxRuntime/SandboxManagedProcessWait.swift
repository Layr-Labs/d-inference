import Foundation

enum SandboxManagedProcessWait {
    private enum Outcome: Sendable { case exited, timedOut, cancelled }

    static func run(execution: ProcessExecution, timeoutSeconds: UInt32,
                    cooperativeGracePeriod: Duration, signalGracePeriod: Duration) async throws -> SandboxProcessResult {
        guard timeoutSeconds > 0, cooperativeGracePeriod >= .zero, signalGracePeriod >= .zero else {
            // The process already exists. Invalid wait settings still require
            // cleanup before a caller may release its surrounding authority.
            await Task.detached { await execution.stop(cooperativeGracePeriod: .zero, signalGracePeriod: .seconds(2)) }.value
            throw SandboxRuntimeError.unsupported("managed process wait limits must be positive")
        }
        let outcome = await withTaskCancellationHandler {
            await withTaskGroup(of: Outcome.self) { group in
                group.addTask { await execution.waitUntilExit(); return .exited }
                group.addTask {
                    do { try await Task.sleep(for: .seconds(timeoutSeconds)); return .timedOut }
                    catch { return .cancelled }
                }
                let first = await group.next() ?? .cancelled
                if first != .exited {
                    // A cancelled parent must not cancel the grace period or
                    // abandon the actual owner before its exit is observed.
                    await Task.detached {
                        await execution.stop(cooperativeGracePeriod: cooperativeGracePeriod,
                                             signalGracePeriod: signalGracePeriod)
                    }.value
                }
                group.cancelAll()
                while await group.next() != nil {}
                return first
            }
        } onCancel: {
            if !execution.requestCooperativeStop() { execution.requestStop() }
        }
        try Task.checkCancellation()
        switch outcome {
        case .exited: return execution.result()
        case .timedOut: throw SandboxRuntimeError.operationTimedOut("managed process")
        case .cancelled: throw CancellationError()
        }
    }
}
