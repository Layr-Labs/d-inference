import Darwin

/// A hard process deadline for the driver, independent of signal delivery: a
/// detached thread that only sleeps, compares the uptime clock and exits. The
/// same last resort as the runtime's `ProcessDeadline`, which this MLX-free
/// module cannot link.
///
/// The driver holds no model and no RDMA resources, so ending it this way
/// loses only its report. Its workers then see their input end and exit by
/// themselves.
public enum QualificationDeadline {
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
                let remaining = min(arguments.deadline - now, 1_000_000_000)
                var wait = timespec(tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
                nanosleep(&wait, nil)
            }
        }, arguments)
        guard created == 0, let thread else {
            arguments.deallocate()
            throw QualificationError("Could not start the driver deadline thread")
        }
        pthread_detach(thread)
    }
}
