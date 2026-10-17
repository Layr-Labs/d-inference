import Foundation

/// Observes the exit of a Foundation `Process` without a run loop.
///
/// `Process.waitUntilExit()` parks the calling thread in that thread's run
/// loop and returns only when the run loop is woken. On a dispatch worker
/// thread the wake-up is not reliably delivered: after the child has exited
/// and been reaped (`isRunning` already false) the call was measured to
/// return late by about 70 ms in most sessions, by seconds in some, and never
/// in others. Foundation calls `terminationHandler` from its own exit source
/// with no run loop involved, so this latch is released by that alone.
///
/// The latch stays released: any number of waits, before or after the exit,
/// get the same answer, and an exit that precedes the first waiter is kept.
public final class ClusterProcessExit: @unchecked Sendable {
    private let observed = DispatchGroup()
    private let lock = NSLock()
    private var started = false
    private var settled = false

    public init() {}

    /// Installs the exit handler and then starts `process`; use it in place of
    /// `process.run()`. The handler has to be in place before the launch, or a
    /// child that exits at once would never be reported. A launch that throws
    /// settles the latch, because no exit will ever follow it.
    public func run(_ process: Process) throws {
        try lock.withLock {
            guard !started else { throw ClusterWorkerOwnerError.invalid("Process exit observer started twice") }
            started = true
        }
        observed.enter()
        process.terminationHandler = { [self] _ in settle() }
        do { try process.run() } catch { settle(); throw error }
    }

    /// True once Foundation has reported the exit. `terminationStatus` and
    /// `terminationReason` are valid from then on.
    public var hasExited: Bool { lock.withLock { settled } }

    /// Blocks until the exit has been reported. Returns at once if it already
    /// was, or if nothing was ever started.
    public func wait() { observed.wait() }

    /// As `wait()`, but gives up at `deadline`; false means not yet reported.
    public func wait(untilUptimeNanoseconds deadline: UInt64) -> Bool {
        observed.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .success
    }

    private func settle() {
        let first = lock.withLock { () -> Bool in
            if settled { return false }
            settled = true; return true
        }
        if first { observed.leave() }
    }
}
