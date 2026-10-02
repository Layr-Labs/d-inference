import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// Explicit local development installation. Pins are observations to compare
/// with B's coordinator approval, never authority to start on their own.
/// This key-only increment cannot publish model readiness or serving capacity.
public struct NativePairMemberInstallation: Sendable {
    private(set) var protectedRuntime: DistributedInstalledNativeAttachment?
    let policy: NativePairMemberPolicy
    let rank: Int
    let clusterID: String
    let identity: ClusterWorkerIdentity
    let profile: ClusterWorkerProfile
    let localOwner: ClusterLocalOwnerConfiguration
    let ownerSHA256: String
    let artifacts: [URL]
    let chip: String
    let leaseDirectory: URL
    let bootstrapProfile: ClusterOwnerBootstrapProfile

    public init(expectedCoordinatorPolicy: Data, rank: Int, clusterID: String,
                identity: ClusterWorkerIdentity, profile: ClusterWorkerProfile,
                installedOwner: URL, ownerSHA256: String, nativeExecutable: URL,
                metallib: URL, resourceLibrary: URL, chip: String,
                bootstrapProfile: ClusterOwnerBootstrapProfile = .nativeKeyPrelude) throws {
        try self.init(expectedCoordinatorPolicy: expectedCoordinatorPolicy, rank: rank, clusterID: clusterID,
            identity: identity, profile: profile, installedOwner: installedOwner, ownerSHA256: ownerSHA256,
            nativeExecutable: nativeExecutable, metallib: metallib, resourceLibrary: resourceLibrary,
            chip: chip, leaseDirectory: ClusterUserPaths().deviceDirectory, bootstrapProfile: bootstrapProfile)
    }
    // Same existing canonical-style private directory checks; only fixtures
    // select a temporary scope. Production uses ClusterUserPaths above.
    init(expectedCoordinatorPolicy: Data, rank: Int, clusterID: String,
         identity: ClusterWorkerIdentity, profile: ClusterWorkerProfile,
         installedOwner: URL, ownerSHA256: String, nativeExecutable: URL,
         metallib: URL, resourceLibrary: URL, chip: String, leaseDirectory: URL,
         bootstrapProfile: ClusterOwnerBootstrapProfile = .nativeKeyPrelude) throws {
        let policy = try NativePairMemberPolicy(expectedCoordinatorPolicy)
        guard bootstrapProfile.requiresNativeAuthorization, (0...1).contains(rank), identity.peers.count == 2,
              ClusterConfigurationSyntax.hash(ownerSHA256), policy.chips.contains(chip),
              identity.artifactSHA256 == Self.hex(policy.hashes[1]),
              identity.peers[rank].buildSHA256 == Self.hex(policy.hashes[2]) else { throw NativePairMemberError.binding }
        _ = try ClusterOwnerBinding(clusterID: clusterID, ownerIncarnation: UUID(), leaseID: UUID(),
            identity: identity, profile: profile, rank: rank, executionPlanSHA256: Self.hex(policy.hashes[0]))
        self.bootstrapProfile = bootstrapProfile; self.policy = policy; self.rank = rank; self.clusterID = clusterID
        self.identity = identity; self.profile = profile
        localOwner = try .init(installedDarkbloom: installedOwner); self.ownerSHA256 = ownerSHA256
        artifacts = [nativeExecutable, metallib, resourceLibrary]; self.chip = chip; self.leaseDirectory = leaseDirectory
    }
    func withProtectedRuntime(_ observation: DistributedInstalledNativeAttachment) throws -> Self {
        guard bootstrapProfile == .nativeKeyPreludeMesh2,
              try observation.attachment.policyBytes == policy.bytes,
              observation.attachment.ownerSHA256 == ownerSHA256 else { throw NativePairMemberError.binding }
        var value = self; value.protectedRuntime = observation; return value
    }
    func prepare(start: ClusterNativeAuthorizationStart, deadline: UInt64) throws -> [DistributedInstalledFiles.Identity] {
        try policy.require(start)
        try protectedRuntime?.requireUnchanged()
        guard start.rank == rank else { throw NativePairMemberError.binding }
        let gate = try ClusterDeviceExclusion(directoryURL: leaseDirectory)
        return try withExtendedLifetime(gate) {
            var files = [try DistributedInstalledFiles.verify(localOwner.installedDarkbloom,
                expectedSHA256: ownerSHA256, maximumBytes: 256 * 1024 * 1024, executable: true, deadline: deadline)]
            for i in 0..<3 {
                files.append(try DistributedInstalledFiles.verify(artifacts[i], expectedSHA256: Self.hex(policy.hashes[i + 2]),
                    maximumBytes: 256 * 1024 * 1024, executable: i == 0, deadline: deadline))
            }
            for file in files { try file.requireUnchanged() }
            return files
        }
    }
    func launch(start: ClusterNativeAuthorizationStart, until: UInt64, relay: ClusterOwnerNativeKeyRelay) throws -> ClusterRemoteWorkerEndpoint {
        let fresh = ClusterWorkerIdentity(membershipEpoch: start.common.epoch, modelID: identity.modelID,
            artifactSHA256: identity.artifactSHA256, configurationSHA256: identity.configurationSHA256, peers: identity.peers)
        return try ClusterRemoteWorkerEndpoint(localOwner: localOwner, clusterID: clusterID,
            expectedIdentity: fresh, profile: profile, rank: rank,
            executionPlanSHA256: Self.hex(policy.hashes[0]), lifetimeDeadlineUptimeNanoseconds: until, nativeKeyRelay: relay,
            protectedReady: protectedRuntime?.readyPolicy(start: start, identity: fresh, profile: profile))
    }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
