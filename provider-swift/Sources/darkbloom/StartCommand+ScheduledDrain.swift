import Foundation
import ProviderCore

extension Start {
    /// Outside a schedule window there is no ProviderLoop, connection or
    /// admitted work. Keep command handling/liveness alive instead of sleeping
    /// through stop/restart. Once a command is acknowledged, never open another
    /// window in this process; only the requested new launch may serve again.
    internal func waitOutsideSchedule(seconds: TimeInterval, coordinatorURL: String) async throws -> Bool {
        guard let identity = ProcessIdentity.current() else { return true }
        let mailbox = LifecycleMailbox(identity: identity)
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var draining = false
        var status = ProviderDrainStatus(outcome: .drained)
        repeat {
            if await ProviderTermination.shared.terminationRequested { return true }
            if let request = mailbox.readRequest(), request.isValid(for: identity) {
                draining = true
                status = ProviderDrainStatus(requestID: request.id, outcome: request.force ? .forced : .drained,
                                             coordinatorAcknowledged: false)
                try mailbox.writeStatus(status)
            }
            DaemonStateFile.write(DaemonState(pid: identity.pid, processIdentity: identity,
                version: ProviderCore.version, writtenAt: Date().timeIntervalSince1970,
                startedAt: Double(identity.startTimeMicros) / 1_000_000,
                coordinatorURL: coordinatorURL, lifecycle: status))
            if !draining && ContinuousClock.now >= deadline { return false }
            try await Task.sleep(nanoseconds: 250_000_000)
        } while !Task.isCancelled
        return true
    }
}
