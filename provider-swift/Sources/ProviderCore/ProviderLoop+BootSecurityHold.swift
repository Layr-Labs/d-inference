import Foundation

extension ProviderLoop {
    /// How often the hold looks for a stop, update or other service change.
    internal static let bootSecurityHoldPollInterval: Duration = .seconds(2)

    /// Darkbloom serving needs Apple's default boot security (see
    /// `BootSecuritySnapshot.servingRefusals`). Without it this process stays
    /// up with no coordinator connection until a stop, update or other service
    /// change begins, keeping the daemon-state stamp fresh: an exit would read
    /// to the crash-recovery watchdog as a crash loop and roll the update back.
    internal func holdWithoutDarkbloomServing(_ refusals: [BootSecurityIssue]) async {
        for refusal in refusals {
            logger.error("Darkbloom serving is off on this Mac. \(refusal.name): \(refusal.detail). Fix: \(refusal.fix)")
        }
        writeDaemonState()
        let liveness = startPreloadLivenessRefresh()
        defer { liveness.cancel() }
        while !Task.isCancelled, !isShuttingDown, !servingDrain.refusingForServiceChange {
            try? await taskSleep(Self.bootSecurityHoldPollInterval)
        }
    }
}
