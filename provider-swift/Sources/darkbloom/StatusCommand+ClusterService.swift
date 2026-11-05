import Foundation
import ProviderCore

extension Status {
    /// This Mac's cluster service: whether it starts at login, whether it runs
    /// now, and its supervisor's phase (review finding 12). Empty on a Mac that
    /// is not part of a cluster.
    static func clusterServiceLines() -> [String] {
        guard ClusterPairSummary.readsThisMacsCluster else { return [] }
        let now = Date().timeIntervalSince1970
        let directory = try? ClusterService.paths().lock.deletingLastPathComponent()
        let supervisor = directory.flatMap {
            ClusterSupervisionFiles.read(ClusterMemberSupervisorState.self,
                                         from: ClusterServiceAgent.supervisorStatePath(serviceDirectory: $0))
        }
        return clusterServiceLines(
            agents: ClusterServiceAgent.status().map { (label: $0.label, loaded: $0.loaded) },
            serviceRunning: ClusterService.running(), paired: !ClusterService.holdsNoPairing(),
            supervisor: supervisor, now: now, bootTime: now - ProcessInfo.processInfo.systemUptime)
    }

    /// `ClusterServiceAgentPlan.statusLines`, its commands named for this build (`darkbloom-dev` in the DevNet app).
    static func clusterServiceLines(agents: [(label: String, loaded: Bool)], serviceRunning: Bool, paired: Bool,
                                    supervisor: ClusterMemberSupervisorState?, now: Double, bootTime: Double) -> [String] {
        ClusterServiceAgentPlan.statusLines(agents: agents, serviceRunning: serviceRunning, paired: paired,
                                            supervisor: supervisor, now: now, bootTime: bootTime).map(ClusterOnboardingCommand.named)
    }

    /// No running provider (no state, or a stale one): on a Mac in a cluster single-Mac serving is off, which
    /// `darkbloom start` would not fix. `unsure`: its pairing record couldn't be read.
    /// Why single-Mac serving isn't running on a paired Mac when it stepped aside for the pair by itself
    /// (`ClusterSoloChoice`); nil otherwise.
    static func steppedAsideLine(paired: Bool) -> String? {
        guard paired, ClusterPairSummary.readsThisMacsCluster, let directory = ClusterService.soloChoiceDirectory(),
              let note = ClusterSoloChoice.steppedAside(in: directory) else { return nil }
        return ClusterSoloChoice.line(note, cli: BuildEnvironment.current.cliName)
    }

    static func daemonNotRunningLine(paired: Bool, unsure: Bool = false, staleStateFile: Bool = false) -> String {
        if paired { return unsure ? ClusterPairSummary.singleMacServingOffUnsureLine : ClusterPairSummary.singleMacServingOffLine }
        return staleStateFile ? "Daemon: not running (stale state file)" : "Daemon: not running (run `\(BuildEnvironment.current.cliName) start`)"
    }

    /// Under the daemon line when the running provider is the cluster's part on this Mac.
    static let clusterPartLine = "  This is the cluster's part on this Mac, not single-Mac serving (`\(ClusterPairSummary.cli) cluster status`)."
}
