import Foundation
import os

private let bootSecurityLogger = Logger(subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "security")

extension ProviderLoop {
    /// How often the hold looks for a stop, update or other service change.
    internal static let bootSecurityHoldPollInterval: Duration = .seconds(2)

    /// Darkbloom serving needs Apple's default boot security (see
    /// `BootSecuritySnapshot.servingRefusals`). Without it this process stays
    /// up with no coordinator connection until a stop, update or other service
    /// change begins, keeping the daemon-state stamp fresh: an exit would read
    /// to the crash-recovery watchdog as a crash loop and roll the update back.
    /// App Nap stays off so the stamp keeps its schedule; idle sleep is allowed.
    internal func holdWithoutDarkbloomServing(_ refusals: [BootSecurityIssue]) async {
        for refusal in refusals {
            bootSecurityLogger.error(
                "Darkbloom serving is off on this Mac. \(refusal.name, privacy: .public): \(refusal.detail, privacy: .public). Fix: \(refusal.fix, privacy: .public)"
            )
        }
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Darkbloom provider waiting: boot security keeps serving off")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        bootSecurityHoldActive = true
        bootSecurityHoldKinds = refusals.map(\.kind.rawValue)
        defer {
            bootSecurityHoldActive = false
            bootSecurityHoldKinds = nil
        }
        writeDaemonState()
        let liveness = startPreloadLivenessRefresh()
        defer { liveness.cancel() }
        while !Task.isCancelled, !isShuttingDown, !servingDrain.refusingForServiceChange {
            try? await taskSleep(Self.bootSecurityHoldPollInterval)
        }
    }
}
