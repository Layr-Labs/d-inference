import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Scoped to an explicit CLI login. Termination signals cancel its task instead
/// of terminating the process in the middle of credential publication. Awaiting
/// the task keeps the handlers installed until publication or rollback finishes.
/// Other provider commands retain their existing signal behavior.
public enum DeviceLoginSignalCancellation {
    public static func run<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let cancellation = LoginSignalCancellationState()
        let signals = LoginTerminationSignals { cancellation.requestCancellation() }
        defer { signals.restore() }

        let task = Task { try await operation() }
        cancellation.attach { task.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.requestCancellation()
        }
    }
}

private final class LoginSignalCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var cancel: (@Sendable () -> Void)?

    func attach(_ cancel: @escaping @Sendable () -> Void) {
        let alreadyRequested = lock.withLock {
            self.cancel = cancel
            return requested
        }
        if alreadyRequested { cancel() }
    }

    func requestCancellation() {
        let action = lock.withLock {
            requested = true
            return cancel
        }
        action?()
    }
}

private final class LoginTerminationSignals {
    private var sources: [DispatchSourceSignal] = []
    private var restoreHandlers: [() -> Void] = []

    init(onSignal: @escaping @Sendable () -> Void) {
        // This queue must be able to cancel a task even while that task is
        // synchronously holding the credential lock and renaming files.
        let queue = DispatchQueue(label: "io.darkbloom.login-signals")
        for number in [SIGTERM, SIGINT] {
            let registered = DispatchSemaphore(value: 0)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler(handler: onSignal)
            source.setRegistrationHandler { registered.signal() }
            source.resume()
            registered.wait()
            // Register before ignoring the default disposition, and finish
            // setup before starting the task that can mutate credentials.
            let previous = signal(number, SIG_IGN)
            restoreHandlers.append { _ = signal(number, previous) }
            sources.append(source)
        }
    }

    func restore() {
        sources.forEach { $0.cancel() }
        restoreHandlers.forEach { $0() }
        sources.removeAll()
        restoreHandlers.removeAll()
    }
}
