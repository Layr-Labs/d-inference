import Foundation
import ProviderCore

extension Status {
    /// This Mac's cluster service: whether it starts at login, whether it runs
    /// now, and its supervisor's phase (review finding 12). Empty on a Mac that
    /// is not part of a cluster.
    static func clusterServiceLines() -> [String] {
        let now = Date().timeIntervalSince1970
        let directory = try? ClusterService.paths().lock.deletingLastPathComponent()
        let supervisor = directory.flatMap {
            ClusterSupervisionFiles.read(ClusterMemberSupervisorState.self,
                                         from: ClusterServiceAgent.supervisorStatePath(serviceDirectory: $0))
        }
        return ClusterServiceAgentPlan.statusLines(
            agents: ClusterServiceAgent.status().map { (label: $0.label, loaded: $0.loaded) },
            serviceRunning: ClusterService.running(), paired: !ClusterService.holdsNoPairing(),
            supervisor: supervisor, now: now, bootTime: now - ProcessInfo.processInfo.systemUptime)
    }
}
