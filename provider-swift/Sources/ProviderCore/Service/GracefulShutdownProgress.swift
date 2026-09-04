/// Process-global "the graceful drain has started" flag.
///
/// `ShutdownSignalTrap` (the serve command's SIGTERM/SIGINT trap) cancels the
/// serve task on the first signal and expects `ProviderLoop.run()`'s
/// cancellation path to run `beginShutdownDrain` on the loop actor. When that
/// actor is wedged — the one case the crash-recovery watchdog's `kickstart
/// -k` exists for — nothing runs: the coordinator link stays up, heartbeats
/// keep advertising capacity, and the process lingers until launchd's
/// SIGKILL. `beginShutdownDrain` flips this flag before its first suspension
/// so the trap can tell "draining" from "wedged" and escalate to a forced
/// exit in the latter case. Lock-boxed, not an actor: the reader is a
/// DispatchQueue timer that must not depend on any actor being free.
import Foundation

public enum GracefulShutdownProgress {
    private static let flag = LockedFlag()

    /// True once `beginShutdownDrain` has started (refuse → drain → close).
    public static var drainStarted: Bool { flag.value }

    public static func markDrainStarted() { flag.set(true) }

    /// Test seam: the flag is process-global and the test runner hosts every
    /// suite in one process.
    public static func resetForTesting() { flag.set(false) }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var value: Bool { lock.withLock { raised } }
        func set(_ value: Bool) { lock.withLock { raised = value } }
    }
}
