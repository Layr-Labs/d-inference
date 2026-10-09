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
/// This is the last resort, not the cleanup path. It ends the process without
/// releasing RDMA registrations or the Metal cache, so every caller must set a
/// shorter bound that fails in-process first (the collective progress limit,
/// the request deadline) and treat an exit with `status` as a fault.
public enum ProcessDeadline {
    private struct Arguments {
        let deadline: UInt64
        let status: Int32
    }

    /// `uptimeNanoseconds` is on the `DispatchTime.now().uptimeNanoseconds` clock.
    public static func arm(uptimeNanoseconds deadline: UInt64, status: Int32) throws {
        let arguments = UnsafeMutablePointer<Arguments>.allocate(capacity: 1)
        arguments.initialize(to: .init(deadline: deadline, status: status))
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { raw in
            let arguments = raw.assumingMemoryBound(to: Arguments.self).pointee
            while true {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if now >= arguments.deadline { Darwin._exit(arguments.status) }
                // Wake at least once a second so a clock step cannot strand the wait.
                let remaining = min(arguments.deadline - now, 1_000_000_000)
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
