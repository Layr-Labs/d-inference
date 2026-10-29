import Darwin
import Foundation
import DarkbloomClusterBootstrap
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

func memberFixtureOwner(executable: URL) throws {
    let configuration = try MemberFixtureConfiguration.read(beside: executable)
    let expected = try configuration.start
    let bootstrapProfile: ClusterOwnerBootstrapProfile = configuration.combinedMesh ? .nativeKeyPreludeMesh2 : .nativeKeyPrelude
    try ClusterWorkerOwnerService.serveConfigured(input: STDIN_FILENO, output: STDOUT_FILENO,
        clusterID: configuration.clusterID, leaseDirectory: URL(fileURLWithPath: configuration.leaseDirectory),
        maximumLifetimeNanoseconds: 20_000_000_000, bootstrapProfile: bootstrapProfile,
        authorizeNativeStart: { observed in
            guard observed.canonicalBytes == expected.canonicalBytes else { throw MemberFixtureError.invalid }
        }, binding: { epoch, lease, incarnation in
            try .init(clusterID: configuration.clusterID, ownerIncarnation: incarnation, leaseID: lease,
                identity: configuration.identity(epoch: epoch), profile: MemberFixtureConfiguration.profile,
                rank: expected.rank, executionPlanSHA256: expected.common.planSHA256.hex)
        }, native: { binding, deadline, attachment in
            guard let attachment, attachment.profile == bootstrapProfile,
                  attachment.nativeStart?.canonicalBytes == expected.canonicalBytes else { throw MemberFixtureError.invalid }
            return try ClusterWorkerProcess(launch: .init(executable: executable,
                arguments: ["--native-fixture"] + attachment.workerArguments,
                environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]),
                expectedIdentity: binding.identity, rank: binding.rank, profile: binding.profile,
                executionPlanSHA256: binding.executionPlanSHA256,
                startupDeadline: min(deadline, DispatchTime.now().uptimeNanoseconds + 10_000_000_000),
                lifetimeDeadline: deadline)
        })
}
