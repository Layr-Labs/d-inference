import DarkbloomClusterRuntime
import Darwin
import Foundation

/// The worker's own hard deadline for becoming ready.
///
/// Loading and the native bootstrap can block where nothing in the process can
/// interrupt them: a rank that listens for a peer that never arrives waits
/// forever. Its owner will not signal it before the worker's own deadline has
/// passed, so without this the only such deadline is the whole lifetime. When
/// the owner names a startup deadline, the worker ends itself there unless it
/// became ready first, and the owner may treat that moment as final.
///
/// Like the lifetime deadline this is a last resort, not a cleanup path: it
/// takes the process's one forced exit (`ProcessForcedExit`), which resets
/// MLX's wired limit and returns its cache behind the dead-man, and does not
/// unwind the load. It is disarmed as soon as the runtime is loaded, after
/// which ordinary control and the lifetime apply.
final class WorkerStartupDeadline: @unchecked Sendable {
    /// Distinct from the lifetime deadline's 124.
    static let exitStatus: Int32 = 123
    private let lock = NSLock()
    private var armed = true
    private let deadline: UInt64
    private let expire: @Sendable () -> Void

    private init(deadline: UInt64, expire: @escaping @Sendable () -> Void) {
        self.deadline = deadline; self.expire = expire
    }

    /// `uptimeNanoseconds` is on the `DispatchTime.now().uptimeNanoseconds` clock.
    static func arm(uptimeNanoseconds deadline: UInt64,
                    expire: @escaping @Sendable () -> Void = {
                        ProcessForcedExit.exit(status: WorkerStartupDeadline.exitStatus, reason: "startup-deadline")
                    }) throws -> WorkerStartupDeadline {
        let value = WorkerStartupDeadline(deadline: deadline, expire: expire)
        let retained = Unmanaged.passRetained(value).toOpaque()
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { raw in
            Unmanaged<WorkerStartupDeadline>.fromOpaque(raw).takeRetainedValue().wait()
            return nil
        }, retained)
        guard created == 0, let thread else {
            Unmanaged<WorkerStartupDeadline>.fromOpaque(retained).release()
            throw WorkerFailure.invalid("Could not start the startup deadline thread")
        }
        pthread_detach(thread)
        return value
    }

    /// Readiness was reached. The deadline thread ends without acting.
    func disarm() { lock.lock(); armed = false; lock.unlock() }

    private func wait() {
        while true {
            lock.lock()
            if !armed { lock.unlock(); return }
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if now >= deadline { armed = false; lock.unlock(); expire(); return }
            lock.unlock()
            // Short naps keep a disarmed thread from lingering for the whole wait.
            let remaining = min(deadline - now, 100_000_000)
            var nap = timespec(tv_sec: 0, tv_nsec: Int(remaining))
            nanosleep(&nap, nil)
        }
    }
}
