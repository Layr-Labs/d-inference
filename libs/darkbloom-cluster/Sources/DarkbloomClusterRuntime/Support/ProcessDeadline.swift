import Darwin

/// A hard process deadline that does not depend on signal delivery.
///
/// A native collective that blocks or spins cannot be interrupted from inside
/// the process, so a rank needs a last resort that ends it. `alarm` is not
/// enough: on two Macs, a rank spinning in the RDMA completion poll after its
/// peer died ran for minutes past a 40-second `alarm`. A dedicated thread that
/// only sleeps and compares the uptime clock is independent of the process
/// timer and of signal dispositions.
///
/// This is the last resort, not the cleanup path. When it fires it takes the
/// process's one forced exit (`ProcessForcedExit`): it claims the exit, arms
/// the dead-man and runs the installed release (MLX's wired limit to zero, then
/// the buffer cache) from this thread before ending the process with `status`.
/// That release is safe from here while the executor is inside a native
/// collective, and limited there: it neither tears down the JACCL group nor
/// frees the executor's arrays (see `ProcessForcedExit`). If another path has
/// already claimed the exit, this thread waits for that exit instead. Every
/// caller must still set a shorter bound that fails in-process first (the
/// collective progress limit, the request deadline) and treat an exit with
/// `status` as a fault.
public enum ProcessDeadline {
    private struct Arguments {
        let lease: ClusterLeaseDeadline
        let status: Int32
        let reason: StaticString
    }

    /// `uptimeNanoseconds` is on the `DispatchTime.now().uptimeNanoseconds` clock.
    /// A fixed deadline, for a bounded check or tool run.
    public static func arm(uptimeNanoseconds deadline: UInt64, status: Int32) throws {
        try arm(lease: ClusterLeaseDeadline(uptimeNanoseconds: deadline), status: status, reason: "process-deadline")
    }

    /// A renewable deadline: the thread reads `lease` on every wake, so a
    /// renewal moves the end without re-arming. A worker that stops being
    /// renewed ends here within its time to live, through the forced exit.
    public static func arm(lease: ClusterLeaseDeadline, status: Int32, reason: StaticString = "lease-expired") throws {
        let arguments = UnsafeMutablePointer<Arguments>.allocate(capacity: 1)
        arguments.initialize(to: .init(lease: lease, status: status, reason: reason))
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { raw in
            let arguments = raw.assumingMemoryBound(to: Arguments.self).pointee
            while true {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let deadline = arguments.lease.uptimeNanoseconds
                if now >= deadline {
                    ProcessForcedExit.exit(status: arguments.status, reason: "\(arguments.reason)")
                }
                // Wake at least once a second so a renewal is seen and a clock
                // step cannot strand the wait.
                let remaining = min(deadline - now, 1_000_000_000)
                var wait = timespec(tv_sec: Int(remaining / 1_000_000_000),
                                    tv_nsec: Int(remaining % 1_000_000_000))
                nanosleep(&wait, nil)
            }
        }, arguments)
        guard created == 0, let thread else {
            arguments.deallocate()
            throw ProbeError("Could not start the process deadline thread")
        }
        pthread_detach(thread)
    }
}
