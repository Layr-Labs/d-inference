import Darwin
import Dispatch
import Foundation

public enum SandboxSignalCancellationError: Error, Sendable {
    case alreadyInstalled
    case signalOperationFailed(Int32)
}

/// Process-entrypoint scope for cooperative SIGINT/SIGTERM handling. The body
/// receives task cancellation and remains awaited through its own cleanup.
/// Signal dispositions are restored when the scope ends. Only one scope may
/// own these process-global handlers at a time.
public enum SandboxSignalCancellation {
    private static let ownership = SignalOwnership()

    public static func run<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let state = SignalCancellationState()
        let watcher = try SignalWatcher(state: state, ownership: ownership)
        defer { try? watcher.close() }
        let task = Task {
            try state.checkCancellation()
            try Task.checkCancellation()
            return try await operation()
        }
        state.attach { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        try watcher.close()
        return try result.get()
    }
}

private final class SignalOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var installed = false
    func acquire() throws {
        try lock.withLock {
            guard !installed else { throw SandboxSignalCancellationError.alreadyInstalled }
            installed = true
        }
    }
    func release() { lock.withLock { installed = false } }
}

private final class SignalCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var active = true
    private var cancel: (@Sendable () -> Void)?
    func request() {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            guard active else { return nil }
            requested = true
            return cancel
        }
        callback?()
    }
    func attach(_ callback: @escaping @Sendable () -> Void) {
        let cancelled = lock.withLock { cancel = callback; return requested }
        if cancelled { callback() }
    }
    func checkCancellation() throws {
        if lock.withLock({ requested }) { throw CancellationError() }
    }
    func close() { lock.withLock { active = false; cancel = nil } }
}

private final class SignalWatcher {
    private let state: SignalCancellationState
    private let ownership: SignalOwnership
    private var sources: [any DispatchSourceSignal] = []
    private var dispositions: [(number: Int32, previous: sigaction)] = []
    private var closed = false
    private var ownsSignals = false

    init(state: SignalCancellationState, ownership: SignalOwnership) throws {
        self.state = state; self.ownership = ownership
        try ownership.acquire()
        ownsSignals = true
        do {
            let queue = DispatchQueue(label: "io.darkbloom.sandbox.termination")
            for number in [SIGINT, SIGTERM] {
                var ignored = sigaction(), previous = sigaction()
                ignored.__sigaction_u.__sa_handler = SIG_IGN
                sigemptyset(&ignored.sa_mask)
                guard sigaction(number, &ignored, &previous) == 0 else {
                    throw SandboxSignalCancellationError.signalOperationFailed(errno)
                }
                dispositions.append((number, previous))
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { state.request() }
                source.resume()
                sources.append(source)
            }
        } catch {
            try? close()
            throw error
        }
    }
    deinit { try? close() }

    func close() throws {
        guard !closed else { return }
        closed = true
        state.close()
        for source in sources { source.cancel() }
        sources.removeAll()
        var failure: Int32?
        for item in dispositions.reversed() {
            var previous = item.previous
            if sigaction(item.number, &previous, nil) != 0, failure == nil { failure = errno }
        }
        dispositions.removeAll()
        if ownsSignals { ownership.release(); ownsSignals = false }
        if let failure { throw SandboxSignalCancellationError.signalOperationFailed(failure) }
    }
}
