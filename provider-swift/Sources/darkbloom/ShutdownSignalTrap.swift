import Dispatch
import Foundation
import ProviderCore
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
/// The first signal also arms an ESCALATION: the graceful path needs the
/// loop actor (`beginShutdownDrain` is actor-isolated), and a wedged loop
/// actor — the one case the crash-recovery watchdog's `kickstart -k` exists
/// for — never runs it: the link stays up, heartbeats keep advertising
/// capacity, routed requests hang to their deadline, and the process lingers
/// until launchd's SIGKILL. If `beginShutdownDrain` has not started within
/// `Escalation.delay` of the first signal (`GracefulShutdownProgress`, a
/// lock-boxed flag that needs no actor), the trap exits with
/// `forcedExitStatus` — the pre-trap instant death, a few seconds late.
///
/// The disposition is a no-op C handler, NOT `SIG_IGN`. An ignored signal is
/// inherited across `exec`, and this daemon spawns bounded children all day
/// (tar, codesign, the runtime-smoke child, launchctl) that `BoundedProcess`
/// terminates with SIGTERM on timeout — `SIG_IGN` would make every such bound
/// silently fall through to its SIGKILL fallback. A custom handler resets to
/// `SIG_DFL` in the child, and `DispatchSource`'s EVFILT_SIGNAL fires either
/// way. (`WatchdogSignalTrap` keeps `SIG_IGN`: the watchdog only spawns
/// launchctl.) `cancelled()` (the serve task ended on its own) restores
/// `SIG_DFL`, so a later signal takes the default action again.
enum ShutdownSignalTrap {
    /// Exit status used when a second signal, or the escalation, cuts the
    /// graceful shutdown short.
    static let forcedExitStatus: Int32 = 130

    /// The hard stop for a wedged loop actor (see the type comment).
    /// Injectable so the tests that raise a real SIGTERM at the runner can
    /// observe the decision instead of exiting the process.
    struct Escalation: Sendable {
        /// How long after the first signal the drain must have started.
        var delay: Duration
        /// Whether `ProviderLoop.beginShutdownDrain` has begun.
        var drainStarted: @Sendable () -> Bool
        /// The forced exit.
        var exit: @Sendable (Int32) -> Void

        static let productionDelay: Duration = .seconds(5)

        static let production = Escalation(
            delay: productionDelay,
            drainStarted: { GracefulShutdownProgress.drainStarted },
            exit: { status in Darwin.exit(status) })

        /// Never fires (the drain counts as started).
        static let disabled = Escalation(
            delay: productionDelay, drainStarted: { true }, exit: { _ in })
    }

    /// True once the signal sources are installed and resumed. Test seam:
    /// a test must not raise SIGTERM at itself before the trap is armed.
    static var isArmed: Bool { armed.value }

    static func waitForTermination(escalation: Escalation = .production) async {
        #if canImport(Darwin)
        let noop: @convention(c) (Int32) -> Void = { _ in }
        signal(SIGTERM, noop)
        signal(SIGINT, noop)
        let state = TrapState(escalation: escalation)
        current.set(state)
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

    /// The serve task has returned (its drain is done, or there was no loop
    /// to drain): a pending escalation must not exit the process during the
    /// tail (telemetry flush).
    static func disarmEscalation() {
        current.value?.cancelEscalation()
    }

    /// Test seam: tear the trap down between tests — sources cancelled,
    /// dispositions restored, escalation cancelled, `isArmed` false — so a
    /// stale source from a previous test cannot turn the next test's
    /// SIGTERM into the second-signal exit.
    static func disarmForTesting() {
        current.value?.cancelled()
        current.set(nil)
    }

    private static let armed = ArmedFlag()
    private static let current = CurrentTrap()

    private final class ArmedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func set(_ v: Bool) { lock.withLock { flag = v } }
    }

    private final class CurrentTrap: @unchecked Sendable {
        private let lock = NSLock()
        private var state: TrapState?
        var value: TrapState? { lock.withLock { state } }
        func set(_ s: TrapState?) { lock.withLock { state = s } }
    }

    private final class TrapState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var fired = false
        private var sources: [DispatchSourceSignal] = []
        private var escalationItem: DispatchWorkItem?
        private let escalation: Escalation

        init(escalation: Escalation) {
            self.escalation = escalation
        }

        func arm(_ continuation: CheckedContinuation<Void, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func retain(_ sources: DispatchSourceSignal...) {
            lock.withLock { self.sources = sources }
        }

        /// First signal: hand the waiter back and arm the escalation.
        /// Second signal: exit now.
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
            armEscalation()
            pending?.resume()
        }

        private func armEscalation() {
            let escalation = self.escalation
            let item = DispatchWorkItem {
                guard !escalation.drainStarted() else { return }
                FileHandle.standardError.write(Data(
                    ("termination signal received but the graceful drain did not start within "
                        + "\(escalation.delay.components.seconds)s (loop actor wedged): exiting\n").utf8))
                escalation.exit(ShutdownSignalTrap.forcedExitStatus)
            }
            lock.withLock { escalationItem = item }
            let delay = DispatchTimeInterval.milliseconds(
                Int(escalation.delay.components.seconds * 1000)
                    + Int(escalation.delay.components.attoseconds / 1_000_000_000_000_000))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
        }

        func cancelEscalation() {
            let item: DispatchWorkItem? = lock.withLock {
                let item = escalationItem
                escalationItem = nil
                return item
            }
            item?.cancel()
        }

        func cancelled() {
            let pending: CheckedContinuation<Void, Never>? = lock.withLock {
                let pending = continuation
                continuation = nil
                sources.forEach { $0.cancel() }
                sources.removeAll()
                return pending
            }
            cancelEscalation()
            #if canImport(Darwin)
            signal(SIGTERM, SIG_DFL)
            signal(SIGINT, SIG_DFL)
            #endif
            ShutdownSignalTrap.armed.set(false)
            pending?.resume()
        }
    }
}
