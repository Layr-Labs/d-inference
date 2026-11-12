import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote

@MainActor final class CancellationRemoteFactory {
    private(set) var endpoints: [ClusterRemoteWorkerEndpoint] = []
    private var watchdogs: [DispatchSourceTimer] = []

    func open(epoch: UUID, configuration: CancellationSettings, lifetimeDeadline: UInt64) async throws -> CancellationOwnedPair {
        let template = try qualificationTemplate(configuration.readyTemplateBase64)
        let identity = ClusterWorkerIdentity(membershipEpoch: epoch, modelID: template.identity.modelID,
            artifactSHA256: template.identity.artifactSHA256, configurationSHA256: template.identity.configurationSHA256,
            peers: template.identity.peers)
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < lifetimeDeadline else { throw QualificationFailure.invalid("Owner lifetime expired before endpoint creation") }
        let startup = min(lifetimeDeadline, now + UInt64(configuration.startupSeconds) * 1_000_000_000)
        let relay = try ClusterOwnerBootstrapRelay(identity: identity, executionPlanSHA256: template.executionPlanSHA256,
            deadlineUptimeNanoseconds: min(startup, now + 30_000_000_000))
        var opened: [ClusterRemoteWorkerEndpoint] = []
        do {
            for rank in 0..<2 {
                let peer = configuration.peers[rank]
                let ssh = try ClusterSSHConfiguration(host: peer.host, user: peer.user, port: peer.port,
                    knownHostsFile: URL(fileURLWithPath: peer.knownHostsFile), identityFile: URL(fileURLWithPath: peer.identityFile),
                    installedDarkbloom: peer.installedOwner)
                let endpoint = try ClusterRemoteWorkerEndpoint(configuration: ssh, clusterID: configuration.clusterID,
                    expectedIdentity: identity, profile: template.profile, rank: rank, executionPlanSHA256: template.executionPlanSHA256,
                    lifetimeDeadlineUptimeNanoseconds: lifetimeDeadline, bootstrapRelay: relay)
                opened.append(endpoint); endpoints.append(endpoint)
            }
            let retained = opened
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .init(uptimeNanoseconds: lifetimeDeadline))
            let fence: @Sendable () -> Void = { for endpoint in retained { endpoint.requestNativeCleanup() } }
            timer.setEventHandler(handler: fence)
            timer.resume(); watchdogs.append(timer)
            let pair = try ClusterWorkerPair(workers: opened, startupDeadline: startup)
            return CancellationOwnedPair(pair: pair, endpoints: opened,
                leaseReleaseObserved: { retained.map(\.ownerDeviceLeaseReleasedObserved) })
        } catch {
            // Partial construction cannot be forgotten; retain it for the final
            // controller report even when no Pair was returned.
            for endpoint in opened { endpoint.requestNativeCleanup() }
            for endpoint in opened { await endpoint.waitUntilNativeCleanup() }
            throw error
        }
    }

    func drain(lifetimeDeadline: UInt64) async {
        for endpoint in endpoints where !endpoint.nativeCleanupObserved { endpoint.requestNativeCleanup() }
        for endpoint in endpoints { await endpoint.waitUntilNativeCleanup() }
        let until = min(lifetimeDeadline + 2_000_000_000, DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        while !endpoints.allSatisfy(\.ownerDeviceLeaseReleasedObserved), DispatchTime.now().uptimeNanoseconds < until {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        for timer in watchdogs { timer.cancel() }
    }
}
