import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

extension DistributedInstalledOwner {
    /// Fixed local owner entry. Public start packets carry no secret and are
    /// accepted only against this owner's saved, independently verified runtime.
    /// The member's retained B session remains the authority for Commit/release.
    static func serveNative(prepared: DistributedInstalledPreparation,
                            native: DistributedInstalledNativeAttachment,
                            input: Int32, output: Int32) throws {
        let plan = prepared.plan, attachment = native.attachment
        let policy = try NativePairMemberPolicy(attachment.policyBytes)
        try prepared.requireUnchanged(); try native.requireUnchanged()
        try ClusterWorkerOwnerService.serveConfigured(input: input, output: output,
            clusterID: plan.configuration.clusterID, leaseDirectory: plan.paths.deviceDirectory,
            maximumLifetimeNanoseconds: plan.maximumLifetimeNanoseconds, bootstrapProfile: .nativeKeyPreludeMesh2,
            authorizeNativeStart: { start in
                try prepared.requireUnchanged(); try native.requireUnchanged(); try policy.require(start)
                guard start.rank == plan.configuration.localRank,
                      Date().timeIntervalSince1970 * 1_000_000_000 < Double(policy.notAfter) else {
                    throw ClusterConfigurationError.invalid("Protected owner start rank or original policy lifetime differs")
                }
            }, binding: { epoch, lease, incarnation in
                try plan.binding(epoch: epoch, lease: lease, incarnation: incarnation)
            }, native: { binding, deadline, bootstrap in
                guard let bootstrap, bootstrap.profile == .nativeKeyPreludeMesh2,
                      let start = bootstrap.nativeStart else {
                    throw ClusterConfigurationError.invalid("Protected installed bootstrap is required")
                }
                try policy.require(start); try prepared.requireUnchanged(); try native.requireUnchanged()
                try DistributedInstalledFiles.check(deadline)
                let arguments = try plan.nativeArguments(binding: binding, deadline: deadline, attachment: bootstrap)
                    + ["--protected-record-profile", attachment.workerProfile]
                return try ClusterWorkerProcess(launch: .init(
                    executable: URL(fileURLWithPath: plan.localPeer.workerExecutable), arguments: arguments,
                    environment: plan.nativeEnvironment(matrix: prepared.matrixURL)),
                    expectedIdentity: binding.identity, rank: binding.rank, profile: binding.profile,
                    executionPlanSHA256: binding.executionPlanSHA256,
                    startupDeadline: min(deadline, DispatchTime.now().uptimeNanoseconds + 90_000_000_000),
                    lifetimeDeadline: deadline)
            })
    }
}
