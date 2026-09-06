import Darwin
import Foundation
import ProviderCoreFoundation

/// Synchronizes cancellation with launch and targets only this Process's captured
/// kernel identity. Never sends a global stop command or signals a discovered PID.
final class LocalAPIOwnedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let terminationGrace: Duration
    private var identity: ProcessIdentity?
    private var cancelled = false
    private var finished = false
    private var escalation: Task<Void, Never>?

    init(process: Process, terminationGrace: Duration) {
        self.process = process
        self.terminationGrace = terminationGrace
    }

    var wasCancelled: Bool { lock.withLock { cancelled } }

    func launch() throws -> ProcessIdentity? {
        try lock.withLock {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            try process.run()
            identity = ProcessIdentity.read(pid: process.processIdentifier)
            // Missing identity cannot authorize readiness or a PID signal. Keep
            // observing the owned child; shutdown must refuse to approve quit if
            // it cannot prove this child has exited (rather than orphaning it).
            return identity
        }
    }

    func cancel() {
        lock.withLock {
            guard !cancelled, !finished else { return }
            cancelled = true
            signalIfStillOwned(SIGTERM)
            let grace = terminationGrace
            escalation = Task { [weak self] in
                do { try await Task.sleep(for: grace) } catch { return }
                self?.forceStop()
            }
        }
    }

    private func forceStop() {
        lock.withLock {
            guard cancelled, !finished else { return }
            signalIfStillOwned(SIGKILL)
        }
    }

    private func signalIfStillOwned(_ signal: Int32) {
        guard process.isRunning, let identity,
              ProcessIdentity.read(pid: identity.pid) == identity else { return }
        _ = Darwin.kill(identity.pid, signal)
    }

    func finish(_ resume: () -> Void) {
        let shouldResume = lock.withLock {
            guard !finished else { return false }
            finished = true
            escalation?.cancel()
            escalation = nil
            return true
        }
        if shouldResume { resume() }
    }
}
