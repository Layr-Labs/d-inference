import CryptoKit
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// One Mac's saved expectations for a coordinator-formed pair. Pins are
/// observations to compare with the coordinator's approval, never authority to
/// start on their own. Nothing here publishes model readiness or capacity.
public struct NativePairMemberInstallation: Sendable {
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
    /// Whether the installed owner can honour a start the coordinator
    /// committed. When it cannot, the member declines preparation, so nothing
    /// is ever committed that this Mac could not start and later release.
    let ownerServesCommittedStart: Bool
    /// How the committed owner's native ranks meet. The prelude alone proves
    /// the key exchange and publishes no readiness (fixtures); a setup whose
    /// follower is reached over the link control channel runs the combined
    /// profile: the prelude through the coordinator, then the mesh rounds
    /// through the serving host (S10).
    let bootstrap: Bootstrap
    public enum Bootstrap: Sendable, Equatable { case nativeKeyPrelude, preludeThenMesh }
    /// The roster registration (v3) of a setup saved with a cluster approval:
    /// what this member registers instead of the pair claim, the plan a
    /// committed start must name, and the peer key its data plane pins.
    let roster: NativePairMemberRoster?

    /// `meshOverLink`: the saved setup reaches the follower over the link
    /// control channel, the only way a committed start can serve in this
    /// build. Without it the member declines preparation.
    public init(expectedCoordinatorPolicy: Data, rank: Int, clusterID: String,
                identity: ClusterWorkerIdentity, profile: ClusterWorkerProfile,
                installedOwner: URL, ownerSHA256: String, nativeExecutable: URL,
                metallib: URL, resourceLibrary: URL, chip: String, meshOverLink: Bool = false,
                roster: NativePairMemberRoster? = nil) throws {
        try self.init(expectedCoordinatorPolicy: expectedCoordinatorPolicy, rank: rank, clusterID: clusterID,
            identity: identity, profile: profile, installedOwner: installedOwner, ownerSHA256: ownerSHA256,
            nativeExecutable: nativeExecutable, metallib: metallib, resourceLibrary: resourceLibrary,
            chip: chip, leaseDirectory: ClusterUserPaths().deviceDirectory,
            ownerServesCommittedStart: DistributedInstalledOwner.servesCommittedNativeStart && meshOverLink,
            bootstrap: meshOverLink ? .preludeThenMesh : .nativeKeyPrelude, roster: roster)
    }
    // Same existing canonical-style private directory checks; only fixtures
    // select a temporary scope and their own owner. Production uses
    // ClusterUserPaths and the installed owner above.
    init(expectedCoordinatorPolicy: Data, rank: Int, clusterID: String,
         identity: ClusterWorkerIdentity, profile: ClusterWorkerProfile,
         installedOwner: URL, ownerSHA256: String, nativeExecutable: URL,
         metallib: URL, resourceLibrary: URL, chip: String, leaseDirectory: URL,
         ownerServesCommittedStart: Bool = true, bootstrap: Bootstrap = .nativeKeyPrelude,
         roster: NativePairMemberRoster? = nil) throws {
        let policy = try NativePairMemberPolicy(expectedCoordinatorPolicy)
        // A pair approval lists the chips it covers; a cluster approval the
        // numerics classes (none listed: any class) and the usable memory a
        // member must have, and only a roster registration is offered under it.
        let covered: Bool
        if let terms = policy.cluster {
            let device = roster?.membership.deviceProfile
            covered = roster != nil && device?.chipName == chip
                && terms.admits(numericsClass: device?.numericsClass ?? "")
                && (device?.usableWiredBytes ?? 0) >= terms.minimumMemberUsableBytes
                && roster?.plan.policySHA256 == Self.hex(Data(SHA256.hash(data: expectedCoordinatorPolicy)))
                && roster?.plan.model == policy.model
                && roster?.membership.artifact(for: policy.model) == Self.hex(policy.hashes[1])
        } else { covered = roster == nil && policy.chips.contains(chip) }
        guard (0...1).contains(rank), identity.peers.count == 2,
              ClusterConfigurationSyntax.hash(ownerSHA256), covered,
              identity.artifactSHA256 == Self.hex(policy.hashes[1]),
              identity.peers[rank].buildSHA256 == Self.hex(policy.hashes[2]) else { throw NativePairMemberError.binding }
        _ = try ClusterOwnerBinding(clusterID: clusterID, ownerIncarnation: UUID(), leaseID: UUID(),
            identity: identity, profile: profile, rank: rank,
            executionPlanSHA256: roster?.plan.planSHA256 ?? Self.hex(policy.hashes[0]))
        self.policy = policy; self.rank = rank; self.clusterID = clusterID
        self.identity = identity; self.profile = profile
        localOwner = try .init(installedDarkbloom: installedOwner); self.ownerSHA256 = ownerSHA256
        artifacts = [nativeExecutable, metallib, resourceLibrary]; self.chip = chip; self.leaseDirectory = leaseDirectory
        self.ownerServesCommittedStart = ownerServesCommittedStart; self.bootstrap = bootstrap
        self.roster = roster
    }
    /// The claim this member registers. Its `policySHA256` is the digest of
    /// exactly the policy bytes a prepare frame must carry.
    var membership: ClusterMembership {
        get throws {
            if let roster { return roster.membership }
            return try ClusterMembership(clusterID: clusterID, rank: rank,
                policySHA256: ClusterConfigurationCodec.sha256(policy.bytes))
        }
    }
    /// A committed start under this member's approval: for a cluster
    /// approval, it must name the plan this member derived and registered.
    func requireStart(_ start: ClusterNativeAuthorizationStart) throws {
        try policy.require(start, plan: roster?.planDigest)
        if roster != nil, policy.cluster == nil { throw NativePairMemberError.binding }
    }
    func prepare(start: ClusterNativeAuthorizationStart, deadline: UInt64) throws -> [DistributedInstalledFiles.Identity] {
        try requireStart(start)
        guard start.rank == rank else { throw NativePairMemberError.binding }
        let gate = try ClusterDeviceExclusion(directoryURL: leaseDirectory)
        return try withExtendedLifetime(gate) { try verifyInstalledFiles(deadline: deadline) }
    }
    /// Hashes the owner against its saved pin, and the native executable,
    /// metallib and resource library against the policy's own digests.
    func verifyInstalledFiles(deadline: UInt64) throws -> [DistributedInstalledFiles.Identity] {
        var files = [try DistributedInstalledFiles.verify(localOwner.installedDarkbloom,
            expectedSHA256: ownerSHA256, maximumBytes: 256 * 1024 * 1024, executable: true, deadline: deadline)]
        for i in 0..<3 {
            files.append(try DistributedInstalledFiles.verify(artifacts[i], expectedSHA256: Self.hex(policy.hashes[i + 2]),
                maximumBytes: 256 * 1024 * 1024, executable: i == 0, deadline: deadline))
        }
        for file in files { try file.requireUnchanged() }
        return files
    }
    func launch(start: ClusterNativeAuthorizationStart, until: UInt64, relay: ClusterOwnerNativeKeyRelay) throws -> ClusterRemoteWorkerEndpoint {
        try ClusterRemoteWorkerEndpoint(localOwner: localOwner, clusterID: clusterID,
            expectedIdentity: sessionIdentity(start), profile: profile, rank: rank,
            executionPlanSHA256: executionPlanSHA256, lifetimeDeadlineUptimeNanoseconds: until, nativeKeyRelay: relay)
    }
    /// The combined profile: the owner's open carries the committed start,
    /// its prelude goes through the session and its mesh rounds wherever the
    /// serving host attaches them.
    func launch(start: ClusterNativeAuthorizationStart, until: UInt64,
                bootstrap: ClusterOwnerCommittedBootstrap, dataPlaneTrust: Data? = nil) throws -> ClusterRemoteWorkerEndpoint {
        try ClusterRemoteWorkerEndpoint(localOwner: localOwner, clusterID: clusterID,
            expectedIdentity: sessionIdentity(start), profile: profile, rank: rank,
            executionPlanSHA256: executionPlanSHA256, lifetimeDeadlineUptimeNanoseconds: until, bootstrapRelay: bootstrap,
            dataPlaneTrust: dataPlaneTrust)
    }
    /// The installed worker identity under the start's membership epoch.
    func sessionIdentity(_ start: ClusterNativeAuthorizationStart) -> ClusterWorkerIdentity {
        ClusterWorkerIdentity(membershipEpoch: start.common.epoch, modelID: identity.modelID,
            artifactSHA256: identity.artifactSHA256, configurationSHA256: identity.configurationSHA256, peers: identity.peers)
    }
    var executionPlanSHA256: String { roster?.plan.planSHA256 ?? Self.hex(policy.hashes[0]) }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
