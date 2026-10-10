import Foundation
import Darwin
import DarkbloomClusterProcess
import DarkbloomClusterRemote

/// Blocking entry for the fixed authenticated `cluster worker-owner --stdio`
/// command. Both leader-local and follower owners load their own saved setup.
/// The parent does not hold this owner's native-device exclusion.
public enum DistributedInstalledOwner {
    /// Whether `cluster worker-owner --stdio` can honour a start the
    /// coordinator committed for one member. Not in this build: the entry
    /// below serves only the mesh profile of a session the leader launches,
    /// and the installed worker refuses every owner bootstrap attachment. A
    /// member therefore declines preparation rather than commit to a start
    /// whose owner would be refused, which would hold both devices until the
    /// members disconnect.
    static let servesCommittedNativeStart = false

    /// `providerInstanceLock` is the ordinary provider's instance lock file.
    /// `linkReady` runs immediately before the native launch with this Mac's
    /// RDMA device; it returns once the link is usable or throws.
    static func serve(reference: ClusterConfigurationReference, providerInstanceLock: URL,
                      linkReady: @escaping @Sendable (String) throws -> Void = { _ in }) throws {
        // An ordinary provider on this Mac uses the same GPU and memory and
        // does not take the cluster's device scope. Refuse before anything is
        // prepared, and again immediately before the native launch.
        try DistributedInstalledProviderExclusion.requireNoOrdinaryProvider(lockFile: providerInstanceLock)
        let prepared = try DistributedInstalledPreparation.prepare(reference: reference,
            paths: ClusterUserPaths(), deadline: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
        let device = prepared.plan.localPeer.jacclDevice
        try serve(prepared: prepared, input: STDIN_FILENO, output: STDOUT_FILENO,
            beforeNativeLaunch: {
                try DistributedInstalledProviderExclusion.requireNoOrdinaryProvider(lockFile: providerInstanceLock)
                try linkReady(device)
            })
    }

    static func serve(prepared: DistributedInstalledPreparation, input: Int32, output: Int32,
                      beforeNativeLaunch: @escaping @Sendable () throws -> Void = {}) throws {
        let plan = prepared.plan, features = prepared.validation.workerFeatures
        try prepared.requireUnchanged()
        try features.requireProgressGuard()
        try ClusterWorkerOwnerService.serveConfigured(input: input, output: output,
            clusterID: plan.configuration.clusterID, leaseDirectory: plan.paths.deviceDirectory,
            maximumLifetimeNanoseconds: plan.maximumLifetimeNanoseconds, bootstrapProfile: plan.bootstrap.ownerProfile,
            binding: { epoch, lease, incarnation in
                try plan.binding(epoch: epoch, lease: lease, incarnation: incarnation)
            }, native: { binding, deadline, attachment in
                // The bootstrap is this build's one selection, never a fallback:
                // an attachment is required exactly when that selection is the
                // owner-authenticated exchange. No native path accepts an
                // injected environment, a wire-supplied executable or a claimed
                // memory allowance.
                guard attachment?.profile == plan.bootstrap.ownerProfile else {
                    throw ClusterConfigurationError.invalid("Bootstrap attachment differs from the installed selection")
                }
                try prepared.requireUnchanged()
                try DistributedInstalledFiles.check(deadline)
                try beforeNativeLaunch()
                let startup = min(deadline, DispatchTime.now().uptimeNanoseconds + plan.budgets.startupAllowanceNanoseconds)
                return try ClusterWorkerProcess(launch: .init(
                    executable: URL(fileURLWithPath: plan.localPeer.workerExecutable),
                    arguments: plan.nativeArguments(binding: binding, deadline: deadline,
                        startupDeadline: features.acceptsStartupDeadline ? startup : nil, attachment: attachment),
                    environment: plan.nativeEnvironment(matrix: prepared.matrixURL)),
                    expectedIdentity: binding.identity, rank: binding.rank, profile: binding.profile,
                    executionPlanSHA256: binding.executionPlanSHA256,
                    startupDeadline: startup, lifetimeDeadline: deadline,
                    // A worker that was told its startup deadline ends itself
                    // there; only then may this owner treat it as final.
                    retirement: .init(childEndsItselfAtStartupDeadline: features.acceptsStartupDeadline))
            })
    }
}
