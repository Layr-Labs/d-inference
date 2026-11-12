import Foundation
import Darwin
import DarkbloomClusterProcess
import DarkbloomClusterRemote

/// Blocking entry for the fixed authenticated `cluster worker-owner --stdio`
/// command. Both leader-local and follower owners load their own saved setup.
/// The parent does not hold this owner's native-device exclusion.
public enum DistributedInstalledOwner {
    public static func serve(reference: ClusterConfigurationReference) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        let prepared = try DistributedInstalledPreparation.prepare(reference: reference,
            paths: ClusterUserPaths(), deadline: deadline)
        let native = try DistributedInstalledNativeAttachment.prepare(validation: prepared.validation, deadline: deadline)
        try serve(prepared: prepared, input: STDIN_FILENO, output: STDOUT_FILENO, native: native)
    }

    static func serve(prepared: DistributedInstalledPreparation, input: Int32, output: Int32,
                      native: DistributedInstalledNativeAttachment? = nil) throws {
        let plan = prepared.plan
        if plan.configuration.nativeMember != nil {
            guard let native, native.attachment == plan.configuration.nativeMember else {
                throw ClusterConfigurationError.invalid("Protected owner requires the exact verified native description")
            }
            return try serveNative(prepared: prepared, native: native, input: input, output: output)
        }
        guard native == nil else { throw ClusterConfigurationError.invalid("Unexpected protected owner attachment") }
        try prepared.requireUnchanged()
        try ClusterWorkerOwnerService.serveConfigured(input: input, output: output,
            clusterID: plan.configuration.clusterID, leaseDirectory: plan.paths.deviceDirectory,
            maximumLifetimeNanoseconds: plan.maximumLifetimeNanoseconds, bootstrapProfile: .mesh2,
            binding: { epoch, lease, incarnation in
                try plan.binding(epoch: epoch, lease: lease, incarnation: incarnation)
            }, native: { binding, deadline, attachment in
                // No native path accepts a nil attachment, injected environment,
                // wire-supplied executable or claimed memory allowance.
                guard let attachment, attachment.profile == .mesh2 else {
                    throw ClusterConfigurationError.invalid("Authenticated installed bootstrap is required")
                }
                try prepared.requireUnchanged()
                try DistributedInstalledFiles.check(deadline)
                return try ClusterWorkerProcess(launch: .init(
                    executable: URL(fileURLWithPath: plan.localPeer.workerExecutable),
                    arguments: plan.nativeArguments(binding: binding, deadline: deadline, attachment: attachment),
                    environment: plan.nativeEnvironment(matrix: prepared.matrixURL)),
                    expectedIdentity: binding.identity, rank: binding.rank, profile: binding.profile,
                    executionPlanSHA256: binding.executionPlanSHA256,
                    startupDeadline: min(deadline, DispatchTime.now().uptimeNanoseconds + 90_000_000_000),
                    lifetimeDeadline: deadline)
            })
    }
}
