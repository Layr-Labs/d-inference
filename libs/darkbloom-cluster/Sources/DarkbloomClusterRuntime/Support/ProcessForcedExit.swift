import Darwin
import os
#if canImport(DarkbloomClusterProtocol)
import DarkbloomClusterProtocol
#endif

/// The one way a rank process leaves when it will not finish its normal unwind.
///
/// Every forced end goes through here: the lifetime deadline (124), the startup
/// deadline (123), SIGTERM and the other routed signals, a worker whose input
/// was lost or failed, and a failure the native executor caught (a JACCL guard
/// error among them). The first caller claims the exit; every later caller
/// either does nothing (`begin`) or waits for the claimed exit (`exit`). The
/// claim, in this order:
///
/// 1. arms a dead-man thread that ends the process with the claimed status
///    after `deadManNanoseconds`, whatever any other thread is doing;
/// 2. runs the installed release: MLX's wired limit back to zero first, then
///    the buffer cache returned (see `ProcessNativeMemoryRelease`). The owner's
///    tools found that clearing the cache alone left 146-176 GB wired with no
///    owning process, and that resetting the wired limit first released it;
/// 3. leaves the rest to its caller: `exit` ends the process at once, `begin`
///    lets the caller unwind (cancel, release the model) inside the dead-man
///    bound and then call `finish`.
///
/// The dead-man thread never writes, locks or allocates after it is armed, so
/// a blocked release, a full diagnostic pipe or a wedged native call cannot
/// keep the process alive past the bound.
///
/// One extension, for work that is demonstrably progressing: a release or an
/// unwind that completes a durable write (a cache snapshot, a journal) calls
/// `noteProgress()` after each one. At its deadline the dead-man reads that
/// stamp once; if a write completed within the last half of the bound, the
/// deadline moves by one more bound, exactly once, and the next deadline is
/// final. Progress that stopped, or that never started, gets no extension.
/// The extension is reported (`phase=extended`) by a notice thread armed with
/// the dead-man, so the dead-man itself still never writes: a full
/// diagnostic pipe blocks only the notice.
/// This is the owner's engine-teardown rule (oMLX `_EngineTeardown`, a58afee1:
/// the close budget doubles once, only while persistence reports a recently
/// completed write, and is fatal otherwise).
///
/// What a release from a thread other than the native executor cannot do while
/// that executor is inside a native collective: it does not tear down the JACCL
/// group (its queue pairs and registered buffers belong to the polling thread
/// and end with the process), it does not free the model's arrays (they belong
/// to the executor), and a buffer that an already committed command buffer
/// uses stays resident until that command buffer ends or the process does. It
/// only shrinks MLX's residency set and returns cached buffers, through the C
/// API and the allocator's own lock; it never takes mlx-swift's evaluation
/// lock, which a blocked executor holds. If the allocator lock itself is held
/// by a thread that never returns, the release waits and the dead-man ends the
/// process at its bound.
public enum ProcessForcedExit {
    /// Bound on the release and on any unwind that follows a claim, as the
    /// owner's rank-exit dead-man.
    public static let defaultDeadManNanoseconds: UInt64 = ClusterForcedExitBounds.deadManNanoseconds

    public struct Claim: Equatable, Sendable {
        public let status: Int32
        public let reason: String
    }

    private struct State {
        var release: (@Sendable () -> String)?
        var deadManNanoseconds = ProcessForcedExit.defaultDeadManNanoseconds
        var claim: Claim?
        var claimedAt: UInt64 = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// Uptime of the last completed durable write, 0 when none. One aligned
    /// 64-bit word: stored by the writer, read by the dead-man without a lock
    /// (an aligned word store is single-copy atomic on every Mac this runs on).
    nonisolated(unsafe) private static let progressStamp: UnsafeMutablePointer<UInt64> = {
        let pointer = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        pointer.initialize(to: 0)
        return pointer
    }()

    /// A durable write just completed (a cache snapshot, a journal). Cheap;
    /// call after every completed write, never before it starts. Only a stamp
    /// within the last half of the dead-man bound earns the one extension.
    public static func noteProgress() {
        progressStamp.pointee = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    /// The stamp `noteProgress()` last wrote, for reports; 0 when none.
    public static var lastProgressUptimeNanoseconds: UInt64 { progressStamp.pointee }

    /// Installs what a claim releases. A process that holds native memory
    /// installs it once, before it touches that memory; a process that never
    /// installs one exits without a release. The release must not take a lock
    /// that an evaluation holds, and returns a short description for the log.
    public static func install(release: @escaping @Sendable () -> String,
                               deadManNanoseconds: UInt64 = defaultDeadManNanoseconds) {
        state.withLock { $0.release = release; $0.deadManNanoseconds = max(1, deadManNanoseconds) }
    }

    /// The exit already claimed, if any.
    public static var claim: Claim? { state.withLock { $0.claim } }

    /// Claims the exit, arms the dead-man and runs the release. Returns false,
    /// having done nothing, when another path claimed first.
    @discardableResult
    public static func begin(status: Int32, reason: String) -> Bool {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let won = state.withLock { value -> (release: (@Sendable () -> String)?, deadMan: UInt64)? in
            guard value.claim == nil else { return nil }
            value.claim = .init(status: status, reason: reason); value.claimedAt = now
            return (value.release, value.deadManNanoseconds)
        }
        guard let won else { return false }
        // Without a bound the release could keep a rank alive indefinitely;
        // a rank that cannot be bounded leaves at once instead.
        guard armDeadMan(status: status, after: won.deadMan) else { Darwin._exit(status) }
        note("darkbloom-forced-exit-v1 status=\(status) reason=\(reason) phase=claimed dead_man_ms=\(won.deadMan / 1_000_000)")
        release(won.release, status: status, since: now)
        return true
    }

    /// Claims (or joins) the exit and ends the process. A caller that lost the
    /// claim waits: the winner's exit, or its dead-man, ends this thread too.
    public static func exit(status: Int32, reason: String) -> Never {
        if begin(status: status, reason: reason) { Darwin._exit(status) }
        park()
    }

    /// The end of every unwind, clean or not. Claims with `status` if nothing
    /// has, otherwise keeps the first claim's status; runs the release once
    /// more (an unwind may have returned more buffers to the cache since) and
    /// ends the process.
    public static func finish(status: Int32, reason: String) -> Never {
        if !begin(status: status, reason: reason) {
            let (current, since) = state.withLock { ($0.release, $0.claimedAt) }
            release(current, status: claim?.status ?? status, since: since)
        }
        Darwin._exit(claim?.status ?? status)
    }

    // MARK: Termination signals

    /// The status a routed signal ends the process with: 124 for SIGALRM (the
    /// lifetime alarm, as the deadline thread), otherwise 128 + the signal.
    public static func status(forSignal signal: Int32) -> Int32 { signal == SIGALRM ? 124 : 128 + signal }

    /// Routes SIGTERM and SIGALRM, and SIGINT and SIGHUP unless this process
    /// inherited them ignored, through `exit`. Call first thing, before any
    /// other thread is started: the signals are blocked in the calling thread,
    /// so in every thread started after it, and one dedicated thread takes
    /// them with `sigwait`. A thread that existed before still has them
    /// unblocked; its handler only forwards the signal to that thread.
    ///
    /// A launcher that ignores SIGINT and SIGHUP before starting the worker
    /// (an interrupted driver must not take a loaded worker down) keeps that:
    /// an inherited ignore is never replaced. Returns the routed signals.
    @discardableResult
    public static func routeTerminationSignals() throws -> [Int32] {
        var set = sigset_t()
        sigemptyset(&set)
        var routed: [Int32] = []
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGALRM] {
            if signal == SIGINT || signal == SIGHUP {
                var current = sigaction()
                guard sigaction(signal, nil, &current) == 0 else { continue }
                if unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self) { continue }
            }
            sigaddset(&set, signal); routed.append(signal)
        }
        guard pthread_sigmask(SIG_BLOCK, &set, nil) == 0 else { throw ProbeError("Could not block the termination signals") }
        let arguments = UnsafeMutablePointer<sigset_t>.allocate(capacity: 1)
        arguments.initialize(to: set)
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { raw in
            var set = raw.assumingMemoryBound(to: sigset_t.self).pointee
            while true {
                var received: Int32 = 0
                guard sigwait(&set, &received) == 0 else { continue }
                ProcessForcedExit.exit(status: ProcessForcedExit.status(forSignal: received), reason: "signal-\(received)")
            }
        }, arguments)
        guard created == 0, let thread else {
            arguments.deinitialize(count: 1); arguments.deallocate()
            throw ProbeError("Could not start the termination signal thread")
        }
        pthread_detach(thread)
        signalThread = thread
        for signal in routed {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { received in
                // Async-signal-safe: forward to the thread that takes it.
                if let target = ProcessForcedExit.signalThread { pthread_kill(target, received) }
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESTART
            guard sigaction(signal, &action, nil) == 0 else { throw ProbeError("Could not route signal \(signal)") }
        }
        return routed
    }

    /// Written once, before any handler that reads it is installed.
    nonisolated(unsafe) private static var signalThread: pthread_t?

    // MARK: Internals

    private struct DeadMan {
        let deadline: UInt64
        let bound: UInt64
        let status: Int32
        let progress: UnsafeMutablePointer<UInt64>
        /// Signalled once per extension; 0 when no notice thread runs.
        let notice: semaphore_t
    }

    /// The line the notice thread writes for an extension, prepared before
    /// the dead-man is armed (the dead-man never formats or allocates).
    static func extensionNotice(status: Int32, bound: UInt64) -> String {
        "darkbloom-forced-exit-v1 status=\(status) phase=extended dead_man_ms=\(bound / 1_000_000) "
            + "extension=1/\(ClusterForcedExitBounds.extensions) reason=durable-write-completed-in-last-half-of-bound"
    }

    /// A thread that waits for the dead-man's extension signal and then
    /// writes the prepared notice once. Returns the semaphore to signal, or 0
    /// when it could not be started (the extension then goes unreported).
    private static func armExtensionNotice(status: Int32, bound: UInt64) -> semaphore_t {
        var semaphore: semaphore_t = 0
        guard semaphore_create(mach_task_self_, &semaphore, SYNC_POLICY_FIFO, 0) == KERN_SUCCESS else { return 0 }
        var bytes = Array(extensionNotice(status: status, bound: bound).utf8)
        bytes.append(10)
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
        _ = buffer.initialize(from: bytes)
        struct Notice { let semaphore: semaphore_t; let bytes: UnsafeMutableBufferPointer<UInt8> }
        let arguments = UnsafeMutablePointer<Notice>.allocate(capacity: 1)
        arguments.initialize(to: .init(semaphore: semaphore, bytes: buffer))
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { raw in
            let value = raw.assumingMemoryBound(to: Notice.self).pointee
            while semaphore_wait(value.semaphore) == KERN_ABORTED {}
            _ = Darwin.write(STDERR_FILENO, value.bytes.baseAddress, value.bytes.count)
            return nil
        }, arguments)
        guard created == 0, let thread else {
            arguments.deinitialize(count: 1); arguments.deallocate(); buffer.deallocate()
            semaphore_destroy(mach_task_self_, semaphore)
            return 0
        }
        pthread_detach(thread)
        return semaphore
    }

    /// The extension rule, pure: with the stamp of the last completed write,
    /// the deadline just reached, the bound and the time the dead-man read
    /// the stamp (`now`, at or after the deadline: its sleep overshoots), the
    /// new deadline (one bound after the deadline) or nil when the process
    /// must end now. Granted at most `ClusterForcedExitBounds.extensions`
    /// times by the caller. A write counts if it completed within the last
    /// half of the bound before the deadline or after it, and not later than
    /// the read: a write that lands between the deadline and the dead-man's
    /// wake-up is the most recent progress there is, not one from the future.
    static func extendedDeadline(progress: UInt64, deadline: UInt64, bound: UInt64, now: UInt64? = nil) -> UInt64? {
        let read = max(deadline, now ?? deadline)
        guard progress != 0, progress <= read, deadline - min(progress, deadline) <= bound / 2 else { return nil }
        let sum = deadline.addingReportingOverflow(bound)
        return sum.overflow ? UInt64.max : sum.partialValue
    }

    private static func armDeadMan(status: Int32, after nanoseconds: UInt64) -> Bool {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let sum = now.addingReportingOverflow(nanoseconds)
        let notice = armExtensionNotice(status: status, bound: nanoseconds)
        let arguments = UnsafeMutablePointer<DeadMan>.allocate(capacity: 1)
        arguments.initialize(to: .init(deadline: sum.overflow ? UInt64.max : sum.partialValue, bound: nanoseconds,
                                       status: status, progress: progressStamp, notice: notice))
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { raw in
            let value = raw.assumingMemoryBound(to: DeadMan.self).pointee
            var deadline = value.deadline
            var extensionsLeft = ClusterForcedExitBounds.extensions
            while true {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if now >= deadline {
                    // No lock, no allocation, no write: one word read, one
                    // decision, then the end or the extension (reported by
                    // the notice thread, which a signal only wakes).
                    if extensionsLeft > 0, let later = ProcessForcedExit.extendedDeadline(
                        progress: value.progress.pointee, deadline: deadline, bound: value.bound,
                        now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) {
                        extensionsLeft -= 1; deadline = later
                        if value.notice != 0 { semaphore_signal(value.notice) }
                        continue
                    }
                    Darwin._exit(value.status)
                }
                let remaining = min(deadline - now, 100_000_000)
                var nap = timespec(tv_sec: 0, tv_nsec: Int(remaining))
                nanosleep(&nap, nil)
            }
        }, arguments)
        guard created == 0, let thread else { arguments.deinitialize(count: 1); arguments.deallocate(); return false }
        pthread_detach(thread)
        return true
    }

    private static func release(_ release: (@Sendable () -> String)?, status: Int32, since: UInt64) {
        guard let release else {
            note("darkbloom-forced-exit-v1 status=\(status) phase=released release=none"); return
        }
        let detail = release()
        let elapsed = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- since) / 1_000_000
        note("darkbloom-forced-exit-v1 status=\(status) phase=released \(detail) since_claim_ms=\(elapsed)")
    }

    /// One bounded write; a diagnostic is never worth blocking an exit for
    /// longer than the dead-man allows, and the dead-man does not wait for it.
    private static func note(_ line: String) {
        var bytes = Array((line.count > 480 ? String(line.prefix(480)) : line).utf8)
        bytes.append(10)
        _ = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
    }

    private static func park() -> Never {
        while true {
            var nap = timespec(tv_sec: 1, tv_nsec: 0)
            nanosleep(&nap, nil)
        }
    }
}
