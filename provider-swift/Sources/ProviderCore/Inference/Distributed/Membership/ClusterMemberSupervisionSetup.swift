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

/// What one member heartbeat reports from the loop actor.
public struct ClusterMemberHeartbeatSample: Sendable, Equatable {
    public let phase: ClusterMemberHealth.Phase
    /// Seconds the pair slot's engine has been wedged (its watchdog's
    /// "crashed" verdict: a stall with no engine steps), nil when it is not.
    public let engineWedgedSeconds: Double?
    public let warmup: String?
    /// A request is in flight on the pair this member leads.
    public var busy: Bool

    public init(phase: ClusterMemberHealth.Phase, engineWedgedSeconds: Double?, warmup: String?, busy: Bool = false) {
        self.phase = phase
        self.engineWedgedSeconds = engineWedgedSeconds
        self.warmup = warmup
        self.busy = busy
    }
}

extension ProviderLoop {
    /// One heartbeat of a control-only member, taken ON the loop actor so a
    /// wedged loop stops beating. Refreshes the daemon state too: the launchd
    /// watchdog treats a live process whose daemon state went stale as down,
    /// and a member otherwise writes it only when it connects.
    public func clusterMemberHeartbeat() -> ClusterMemberHeartbeatSample {
        guard isClusterMember else { return .init(phase: .stopping, engineWedgedSeconds: nil, warmup: nil) }
        writeDaemonState()
        let warmup = clusterPairWarmup?.description
        if isShuttingDown || memberControlRequiresStop {
            return .init(phase: .stopping, engineWedgedSeconds: nil, warmup: warmup)
        }
        guard let slot = clusterPairSlot, clusterPairSlotServes(slot.modelID) else {
            clusterPairWedgedSince = nil
            return .init(phase: memberConnectionID != nil ? .registered : .starting, engineWedgedSeconds: nil, warmup: warmup)
        }
        let crashed = state.backendCapacity?.slots.contains { $0.model == slot.modelID && $0.state == "crashed" } ?? false
        if crashed { clusterPairWedgedSince = clusterPairWedgedSince ?? .now } else { clusterPairWedgedSince = nil }
        let wedged = clusterPairWedgedSince.map { since -> Double in
            let duration = ContinuousClock.now - since
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        var sample = ClusterMemberHeartbeatSample(phase: .serving, engineWedgedSeconds: wedged, warmup: warmup)
        sample.busy = state.inferenceActive
        return sample
    }
}
