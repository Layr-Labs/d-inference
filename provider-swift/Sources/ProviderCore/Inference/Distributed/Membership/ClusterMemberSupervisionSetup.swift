import Foundation

/// The two facts a cluster-member supervisor needs from the saved setup, read
/// without validating models, hashing weights or taking the device lease (the
/// member it starts does all of that itself): the cluster ID (it fixes the
/// coordinated update slot) and this Mac's RDMA device (the link gate).
public struct ClusterMemberSupervisionSetup: Sendable, Equatable {
    public let clusterID: String
    public let linkDevice: String
    public let role: String

    /// Nil when the provider configuration names no saved cluster setup; a
    /// malformed or unsafe setup throws, so the supervisor reports it rather
    /// than restarting a member that cannot start.
    public static func load(providerConfiguration: URL) throws -> Self? {
        guard let reference = try ClusterConfigurationStore.optionalInstalledReference(
            providerConfiguration: providerConfiguration) else { return nil }
        let saved = try ClusterConfigurationStore(paths: ClusterUserPaths()).load(reference: reference)
        let configuration = saved.configuration
        guard let local = configuration.peers.first(where: { $0.rank == configuration.localRank }) else {
            throw ClusterConfigurationError.invalid("Saved cluster setup has no entry for this Mac's rank")
        }
        return Self(clusterID: configuration.clusterID, linkDevice: local.jacclDevice, role: configuration.role.rawValue)
    }

    /// The whole-Mac and saved-device link verdicts for `ClusterMemberLinkGate`.
    public static func inspectLink(device: String) -> (machine: ClusterLinkReadinessState, device: ClusterLinkReadinessState?) {
        let report = ClusterLinkReadinessProbe.inspectLocalLink(isolation: false)
        return (report.state, report.devices.first { $0.device == device }?.verdict)
    }
}

extension ProviderLoop {
    /// One heartbeat of a control-only member, taken ON the loop actor so a
    /// wedged loop stops beating. Refreshes the daemon state too: the launchd
    /// watchdog treats a live process whose daemon state went stale as down,
    /// and a member otherwise writes it only when it connects.
    public func clusterMemberHeartbeat() -> ClusterMemberHealth.Phase {
        guard isClusterMember else { return .stopping }
        writeDaemonState()
        if isShuttingDown || memberControlRequiresStop { return .stopping }
        return memberConnectionID != nil ? .registered : .starting
    }
}
