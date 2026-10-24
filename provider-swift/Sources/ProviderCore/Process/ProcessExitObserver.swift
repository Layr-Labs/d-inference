import Foundation

/// Observes the exit of a Foundation `Process` without a run loop.
///
/// `Process.waitUntilExit()` runs the calling thread's run loop in 62.5 ms
/// slices. Once the child is reaped it keeps doing so until a block that
/// Foundation queued on the run loop of the thread that called `run()` has
/// executed, whenever it believes the caller is that thread. Measured on
/// macOS 27.2:
///
/// - Same thread starts and waits, child already gone: one whole slice is
///   spent first, about 66 ms, on every call.
/// - Another thread waits: the exit is noticed only at a slice boundary. If
///   that thread once started a `Process` whose address the current one
///   reuses, Foundation takes it for the starting thread and waits for a
///   block only the real starting thread's run loop can execute. On a
///   dispatch or cooperative thread nobody runs that loop, so the call never
///   returns.
///
/// Foundation calls `terminationHandler` from its own exit source with no run
/// loop involved, so this latch is released by that alone.
///
/// Once released the latch stays released: an exit that precedes the first
/// wait is kept, and every later wait returns at once.
public final class ProcessExitObserver: @unchecked Sendable {
    /// Thrown by a second `run(_:)`: one observer reports one child.
    public struct AlreadyStarted: Error {}

    private enum Phase { case unstarted, awaitingExit, settled }

    private let observed = DispatchGroup()
    private let lock = NSLock()
    private var phase = Phase.unstarted

    public init() {}

    /// Installs the exit handler and then starts `process`; use it in place of
    /// `process.run()`. The handler has to be in place before the launch, or a
    /// child that exits at once would never be reported; it replaces any
    /// `terminationHandler` already set. A launch that throws settles the
    /// latch, because no exit will ever follow it.
    public func run(_ process: Process) throws {
        try lock.withLock {
            guard phase == .unstarted else { throw AlreadyStarted() }
            phase = .awaitingExit
            observed.enter()
        }
        process.terminationHandler = { [self] _ in settle() }
        do { try process.run() } catch { settle(); throw error }
    }

    /// Blocks until Foundation has reported the exit; `terminationStatus` and
    /// `terminationReason` are valid from then on. Returns at once if it
    /// already was, if the launch threw, or if nothing was ever started.
    public func wait() { observed.wait() }

    /// As `wait()`, but gives up after `timeout` seconds; false means not yet
    /// reported.
    public func wait(timeout: TimeInterval) -> Bool {
        observed.wait(timeout: .now() + max(0, timeout)) == .success
    }

    private func settle() {
        lock.withLock {
            guard phase == .awaitingExit else { return }
            phase = .settled
            observed.leave()
        }
    }
}
