import Darwin
import Foundation

/// The rank-side force-cancel hook (owner's oMLX 85480430, ported): a signal
/// the local supervisor, `darkbloom cluster cancel-all` or an operator sends
/// to a worker when the leader or the link is gone and the protocol cannot
/// carry a cancel. SIGUSR1 ends every active request of this rank the way a
/// lost input does: the forced exit is claimed first (wired memory released,
/// dead-man armed), each active request is cancelled and published as failed,
/// the model is released and the process exits; the owner records the
/// terminal and the pair re-forms. The acknowledgement is one line on
/// standard error (`darkbloom-force-cancel-v1`) and the owner's terminal.
///
/// Routed like the termination signals: blocked in the calling thread before
/// any other thread exists, taken by one dedicated thread with `sigwait`, so
/// the handler never runs on the native executor or inside a collective.
enum WorkerForceCancelSignal {
    nonisolated(unsafe) private static var handler: (@Sendable (String) -> Void)?
    nonisolated(unsafe) private static var signalThread: pthread_t?
    private static let lock = NSLock()

    /// Call first thing, before other threads; the handler may be set later.
    static func route() throws {
        var set = sigset_t()
        sigemptyset(&set); sigaddset(&set, SIGUSR1)
        guard pthread_sigmask(SIG_BLOCK, &set, nil) == 0 else { throw WorkerFailure.invalid("Could not block SIGUSR1") }
        let arguments = UnsafeMutablePointer<sigset_t>.allocate(capacity: 1)
        arguments.initialize(to: set)
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { raw in
            var set = raw.assumingMemoryBound(to: sigset_t.self).pointee
            while true {
                var received: Int32 = 0
                guard sigwait(&set, &received) == 0, received == SIGUSR1 else { continue }
                WorkerForceCancelSignal.fire(reason: "signal-usr1")
            }
        }, arguments)
        guard created == 0, let thread else {
            arguments.deinitialize(count: 1); arguments.deallocate()
            throw WorkerFailure.invalid("Could not start the force-cancel signal thread")
        }
        pthread_detach(thread)
        signalThread = thread
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { received in
            if let target = WorkerForceCancelSignal.signalThread { pthread_kill(target, received) }
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        guard sigaction(SIGUSR1, &action, nil) == 0 else { throw WorkerFailure.invalid("Could not route SIGUSR1") }
    }

    /// What a force-cancel does; set once the coordinator exists. A signal
    /// before that is a start that has not loaded: it is noted and ignored
    /// (the lease and the startup deadline bound a load).
    static func install(_ value: @escaping @Sendable (String) -> Void) {
        lock.lock(); handler = value; lock.unlock()
    }

    static func fire(reason: String) {
        lock.lock(); let current = handler; lock.unlock()
        guard let current else {
            note("darkbloom-force-cancel-v1 reason=\(reason) applied=no state=loading"); return
        }
        current(reason)
    }

    static func note(_ line: String) {
        var bytes = Array(line.utf8); bytes.append(10)
        _ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
    }
}
