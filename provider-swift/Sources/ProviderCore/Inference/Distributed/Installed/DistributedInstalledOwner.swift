import Foundation
import Darwin
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// Blocking entry for the fixed authenticated `cluster worker-owner --stdio`
/// command. Both leader-local and follower owners load their own saved setup.
/// The parent does not hold this owner's native-device exclusion.
public enum DistributedInstalledOwner {
    /// Whether `cluster worker-owner --stdio` can honour a start the
    /// coordinator committed for one member (S10). It can: on a setup saved
    /// for coordinator pairing the owner admits the committed start that its
    /// installed approval covers (`memberAuthorizer`), runs the combined
    /// profile, and its worker publishes readiness. A member whose setup
    /// cannot reach its follower still declines preparation
    /// (`NativePairMemberInstallation`), so nothing is committed that this
    /// Mac could not start and later release.
    static let servesCommittedNativeStart = true

    /// The owner's own admission of a start the coordinator committed to this
    /// member: its own rank, and every digest, limit and generation of the
    /// approval this Mac installed (the same check the member's session made
    /// before it prepared). The epoch and the owner, lease and launch
    /// identifiers are the coordinator's.
    static func memberAuthorizer(plan: DistributedInstalledPlan, attachment: ClusterNativeMemberAttachment)
        throws -> @Sendable (ClusterNativeAuthorizationStart) throws -> Void {
        let policy = try NativePairMemberPolicy(attachment.policyBytes), rank = plan.configuration.localRank
        // A cluster approval fixes no plan: the start must name the one this
        // Mac's setup derives (and its member registered).
        let digits = Array(plan.partition.planSHA256.utf8).map { $0 < 58 ? $0 - 48 : $0 - 87 }
        let derived = Data(stride(from: 0, to: 64, by: 2).map { digits[$0] << 4 | digits[$0 + 1] })
        return { start in
            guard start.rank == rank else {
                throw ClusterConfigurationError.invalid("The committed native start names another rank")
            }
            do { try policy.require(start, plan: policy.cluster == nil ? nil : derived) }
            catch { throw ClusterConfigurationError.invalid("The committed native start differs from this Mac's installed approval") }
        }
    }

    /// `providerInstanceLock` is the ordinary provider's instance lock file.
    /// `linkReady` runs immediately before the native launch with this Mac's
    /// RDMA device; it returns once the link is usable or throws.
    /// `localChipClass` is this Mac's own class; the rank this owner runs
    /// must be granted on it before anything is served.
    static func serve(reference: ClusterConfigurationReference, providerInstanceLock: URL,
                      localChipClass: ClusterChipClass?,
                      linkReady: @escaping @Sendable (String) throws -> Void = { _ in }) throws {
        // An ordinary provider on this Mac uses the same GPU and memory and
        // does not take the cluster's device scope. Refuse before anything is
        // prepared, and again immediately before the native launch.
        try DistributedInstalledProviderExclusion.requireNoOrdinaryProvider(lockFile: providerInstanceLock)
        // Memory a dead rank left wired is not this Mac's to plan with: refuse
        // before anything is prepared, naming the measured value and the idle
        // baseline. Skipped while another Darkbloom process runs here.
        try ClusterOrphanWiredGuard.check(role: "owner")
        let prepared = try DistributedInstalledPreparation.prepare(reference: reference,
            paths: ClusterUserPaths(), deadline: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
        // The follower's owner is the only part of this provider on that Mac
        // in a session the leader launches: its rank is checked here, on the
        // Mac that runs it, with that Mac's class.
        try prepared.plan.requireLocalRankGranted(chipClass: localChipClass)
        // Sharded deployments only by default: a setup saved with a hand-off mode is served only under the opt-in.
        try ClusterHandOffModes.requireServable(prepared.plan.configuration.selectedGenerationMode,
            environment: ProcessInfo.processInfo.environment)
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
        try features.requireMiMoImageCandidate(required:plan.capability.media != nil)
        try features.requireGLMImageCandidate(required: plan.capability.glmImages != nil)
        // The prefix-SSD tier's key goes to the rank only on its input; a
        // worker that cannot take it there is refused before anything starts.
        let prefixSSDKey = plan.nativePrefixSSDKey()
        try features.requirePrefixSSDKeyInput(tierOn: prefixSSDKey != nil)
        try ClusterWorkerOwnerService.serveKeyed(input: input, output: output,
            clusterID: plan.configuration.clusterID, leaseDirectory: plan.paths.deviceDirectory,
            bootstrapProfile: plan.bootstrap.ownerProfile,
            // The committed native start of the combined profile is admitted
            // only when it is the one this Mac derives from its own setup, or,
            // on a setup saved for coordinator pairing, when its installed
            // approval covers the start the coordinator committed.
            authorizeNativeStart: plan.bootstrap.ownerProfile?.carriesNativeStart == true
                ? try plan.configuration.nativeMember.map { try memberAuthorizer(plan: plan, attachment: $0) }
                    ?? DistributedInstalledNativeStart.authorizer(plan: plan) : nil,
            // The worker's batch lanes, from the same plan its environment carries.
            lanes: plan.batchLanes() ?? 1,
            binding: { epoch, lease, incarnation in
                try plan.binding(epoch: epoch, lease: lease, incarnation: incarnation)
            }, native: { binding, deadline, attachment, dataPlaneTrust in
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
                // S16: a credential is honoured only by a worker that keys its data plane.
                guard dataPlaneTrust == nil || features.acceptsDataPlane else {
                    throw ClusterConfigurationError.invalid("The installed worker does not key its data plane; install a worker built with it")
                }
                try features.requirePrefixSSDKeyInput(tierOn: prefixSSDKey != nil)
                try beforeNativeLaunch()
                // The worker has no fixed lifetime: `deadline` is its first
                // rank-lease grant, which its supervisor renews while this
                // owner holds the leader's lease. Loading is bounded by the
                // startup allowance, which may outlast the first grant.
                let startup = DispatchTime.now().uptimeNanoseconds + plan.budgets.startupAllowanceNanoseconds
                return try ClusterWorkerProcess(launch: nativeLaunch(prepared: prepared, binding: binding,
                        deadline: deadline, startupDeadline: features.acceptsStartupDeadline ? startup : nil,
                        attachment: attachment, dataPlaneTrust: dataPlaneTrust, prefixSSDKey: prefixSSDKey),
                    expectedIdentity: binding.identity, rank: binding.rank, profile: binding.profile,
                    executionPlanSHA256: binding.executionPlanSHA256,
                    startupDeadline: startup, initialLeaseDeadline: deadline,
                    // A worker that was told its startup deadline ends itself
                    // there; only then may this owner treat it as final. Its
                    // SIGTERM-to-SIGKILL margin is sized to the artifact's
                    // bytes, an upper bound for any stage of it.
                    retirement: .sized(plannedBytes: UInt64(max(0, prepared.manifest.totalSizeBytes)),
                        childEndsItselfAtStartupDeadline: features.acceptsStartupDeadline))
            })
    }

    /// The native rank's launch: arguments, the fixed environment (never a
    /// secret) and its input's first lines, the data-plane credential (S16)
    /// and then the prefix-SSD key bound to this epoch and rank.
    static func nativeLaunch(prepared: DistributedInstalledPreparation, binding: ClusterOwnerBinding, deadline: UInt64,
                             startupDeadline: UInt64?, attachment: ClusterOwnerBootstrapAttachment?, dataPlaneTrust: Data?,
                             prefixSSDKey: Data?, ownerEnvironment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> ClusterWorkerLaunch {
        let plan = prepared.plan
        var input = dataPlaneTrust ?? Data()
        if let prefixSSDKey {
            input.append(try ClusterWorkerCodec.encode(ClusterWorkerPrefixSSDKey(
                membershipEpoch: binding.identity.membershipEpoch, rank: binding.rank, key: prefixSSDKey)))
        }
        return .init(executable: URL(fileURLWithPath: plan.localPeer.workerExecutable),
            arguments: try plan.nativeArguments(binding: binding, deadline: deadline, startupDeadline: startupDeadline,
                attachment: attachment, dataPlane: dataPlaneTrust != nil, prefixSSDKey: prefixSSDKey != nil),
            environment: plan.nativeEnvironment(matrix: prepared.matrixURL, ownerEnvironment: ownerEnvironment),
            initialInput: input.isEmpty ? nil : input)
    }
}
