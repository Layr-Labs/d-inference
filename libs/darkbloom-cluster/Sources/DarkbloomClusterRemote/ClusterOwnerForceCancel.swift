import Darwin
import Foundation
import DarkbloomClusterProcess

/// The owner-side force-cancel hook: SIGUSR1 to a `cluster worker-owner`
/// process fences its native child (the command stream closes, the worker
/// cancels its requests, releases its model and exits by itself; the owner
/// records the terminal and reports it to the leader). This is the protocol's
/// own drain, triggered locally, without the leader and without SSH: the
/// owner's oMLX cancel file (85480430) by another transport. Nothing is
/// invented on the wire: the owner only stops forwarding and stops renewing.
public enum ClusterOwnerForceCancel {
    nonisolated(unsafe) private static var child: (any ClusterWorkerEndpoint)?
    nonisolated(unsafe) private static var signalThread: pthread_t?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routed = false

    /// Routes SIGUSR1 to this owner's fence. Idempotent; call before the
    /// child is created. Errors are reported, never fatal: an owner that
    /// cannot route the hook still serves.
    public static func route() -> String? {
        lock.lock(); defer { lock.unlock() }
        if routed { return nil }
        var set = sigset_t()
        sigemptyset(&set); sigaddset(&set, SIGUSR1)
        guard pthread_sigmask(SIG_BLOCK, &set, nil) == 0 else { return "Could not block SIGUSR1" }
        let arguments = UnsafeMutablePointer<sigset_t>.allocate(capacity: 1)
        arguments.initialize(to: set)
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { raw in
            var set = raw.assumingMemoryBound(to: sigset_t.self).pointee
            while true {
                var received: Int32 = 0
                guard sigwait(&set, &received) == 0, received == SIGUSR1 else { continue }
                ClusterOwnerForceCancel.fire(reason: "signal-usr1")
            }
        }, arguments)
        guard created == 0, let thread else {
            arguments.deinitialize(count: 1); arguments.deallocate()
            return "Could not start the force-cancel signal thread"
        }
        pthread_detach(thread)
        signalThread = thread
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { received in
            if let target = ClusterOwnerForceCancel.signalThread { pthread_kill(target, received) }
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        guard sigaction(SIGUSR1, &action, nil) == 0 else { return "Could not route SIGUSR1" }
        routed = true
        return nil
    }

    /// The child a force-cancel fences; nil again once it has exited.
    public static func register(_ value: (any ClusterWorkerEndpoint)?) {
        lock.lock(); child = value; lock.unlock()
    }

    /// Fences the registered child and says so on standard error (the
    /// member log keeps the owner's diagnostics). Also the test seam.
    @discardableResult
    public static func fire(reason: String) -> Bool {
        lock.lock(); let current = child; lock.unlock()
        let line: String
        if let current {
            current.requestNativeCleanup()
            line = "darkbloom-force-cancel-v1 role=owner reason=\(reason) applied=fence"
        } else {
            line = "darkbloom-force-cancel-v1 role=owner reason=\(reason) applied=no state=no-child"
        }
        var bytes = Array(line.utf8); bytes.append(10)
        _ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
        return current != nil
    }
}
