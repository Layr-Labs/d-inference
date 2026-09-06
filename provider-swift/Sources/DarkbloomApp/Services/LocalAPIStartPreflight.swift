import Foundation
import ProviderCoreFoundation

/// Read-only launch checks. CLI policy and the single-instance lock remain in
/// the CLI. These checks never stop, restart, enroll, or replace a provider.
enum LocalAPIStartPreflight {
    static func validateModel(
        modelID: String,
        models: [ModelSummary],
        modelsAreLive: Bool
    ) throws {
        guard modelsAreLive else { throw LocalAPIStartError.fixtureMode }
        guard !modelID.isEmpty, !modelID.contains("\0"),
              let model = models.first(where: { $0.id == modelID }), model.isInstalled
        else { throw LocalAPIStartError.modelNotInstalled }
        guard !modelID.hasPrefix("-") else {
            throw LocalAPIStartError.modelUnavailable("This installed model has an unsupported command-line identifier.")
        }
        if let reason = model.fit.runtimeBlockReason {
            throw LocalAPIStartError.modelUnavailable(reason)
        }
        if case .tooLarge(let required, let available) = model.fit {
            throw LocalAPIStartError.modelUnavailable(
                "This model requires \(required) GB; this Mac reports \(available) GB. Choose another installed model."
            )
        }
    }

    static func conflict(
        snapshot: ProviderSnapshot?,
        discovery: LocalEndpointInfo?,
        readIdentity: (Int32) -> ProcessIdentity?
    ) -> LocalAPIStartConflict? {
        if let discovery,
           LocalEndpointRuntimeTruth.belongsToLiveProcess(discovery, readIdentity: readIdentity) {
            return .localEndpoint
        }
        if let discovery, readIdentity(discovery.pid) != nil {
            return .providerStateUncertain
        }
        guard let snapshot else { return .providerStateUncertain }
        if snapshot.runState.isTransitioning { return .providerTransitioning }
        if snapshot.isRunning { return .providerRunning }
        // A stale heartbeat does not establish that its process has stopped.
        if let pid = snapshot.pid, readIdentity(pid) != nil { return .providerStateUncertain }
        if snapshot.runState == .scheduledOff { return .providerRunning }
        return nil
    }

    static func liveDaemonConflict() -> LocalAPIStartConflict? {
        if DarkbloomServiceLabels.providerLaunchAgentLoaded() { return .providerRunning }
        if let state = DaemonStateFile.read() {
            if DaemonStateRuntimeTruth.belongsToLiveProcess(state) { return .providerRunning }
            if ProcessIdentity.read(pid: state.pid) != nil { return .providerStateUncertain }
        }
        // The mandatory --no-replace CLI option adjudicates its owner record
        // under the kernel lock. A leftover file after SIGTERM is not a live
        // provider and must not permanently block another local session.
        return nil
    }
}
