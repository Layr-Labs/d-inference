import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// SIGTERM/SIGINT trap for the coordinator-serving daemon (`start
/// --foreground`, i.e. launchd, and a human foreground run).
///
/// The FIRST signal resolves `waitForTermination()`; the caller cancels the
/// serve task and `ProviderLoop.run()`'s cancellation path takes over: refuse
/// new work → drain in-flight requests (bounded) → close the coordinator link
/// with a goingAway frame → exit. A SECOND signal exits the process at once —
/// the human "I meant it" path for a foreground Ctrl-C twice, and the same
/// escape launchd's `ExitTimeOut` SIGKILL provides for a daemon.
///
/// The disposition is a no-op C handler, NOT `SIG_IGN`. An ignored signal is
/// inherited across `exec`, and this daemon spawns bounded children all day
/// (tar, codesign, the runtime-smoke child, launchctl) that `BoundedProcess`
/// terminates with SIGTERM on timeout — `SIG_IGN` would make every such bound
/// silently fall through to its SIGKILL fallback. A custom handler resets to
/// `SIG_DFL` in the child, and `DispatchSource`'s EVFILT_SIGNAL fires either
/// way. (`WatchdogSignalTrap` keeps `SIG_IGN`: the watchdog only spawns
/// launchctl.)
enum ShutdownSignalTrap {
    /// Exit status used when a second signal cuts the graceful shutdown short.
    static let forcedExitStatus: Int32 = 130

    /// True once the signal sources are installed and resumed. Test seam:
    /// a test must not raise SIGTERM at itself before the trap is armed.
    static var isArmed: Bool { armed.value }

    static func waitForTermination() async {
        #if canImport(Darwin)
        let noop: @convention(c) (Int32) -> Void = { _ in }
        signal(SIGTERM, noop)
        signal(SIGINT, noop)
        let state = TrapState()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                state.arm(continuation)
                let term = DispatchSource.makeSignalSource(
                    signal: SIGTERM, queue: .global(qos: .utility))
                let interrupt = DispatchSource.makeSignalSource(
                    signal: SIGINT, queue: .global(qos: .utility))
                term.setEventHandler { state.signalled() }
                interrupt.setEventHandler { state.signalled() }
                state.retain(term, interrupt)
                term.resume()
                interrupt.resume()
                armed.set(true)
            }
        } onCancel: {
            // The serve task ended on its own (loop exit): release the waiter
            // so the enclosing task group can finish, and drop the sources so
            // a later signal takes the default action again.
            state.cancelled()
        }
        #else
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
        }
        #endif
    }

    private static let armed = ArmedFlag()

    private final class ArmedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func set(_ v: Bool) { lock.withLock { flag = v } }
    }

    private final class TrapState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var fired = false
        private var sources: [DispatchSourceSignal] = []

        func arm(_ continuation: CheckedContinuation<Void, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func retain(_ sources: DispatchSourceSignal...) {
            lock.withLock { self.sources = sources }
        }

        /// First signal: hand the waiter back. Second signal: exit now.
        func signalled() {
            let (pending, second): (CheckedContinuation<Void, Never>?, Bool) = lock.withLock {
                if fired { return (nil, true) }
                fired = true
                let pending = continuation
                continuation = nil
                return (pending, false)
            }
            if second {
                FileHandle.standardError.write(
                    Data("second termination signal: exiting without draining\n".utf8))
                exit(ShutdownSignalTrap.forcedExitStatus)
            }
            pending?.resume()
        }

        func cancelled() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                let pending = continuation
                continuation = nil
                sources.forEach { $0.cancel() }
                sources.removeAll()
                return pending
            }
            ShutdownSignalTrap.armed.set(false)
            pending?.resume()
        }
    }
}
