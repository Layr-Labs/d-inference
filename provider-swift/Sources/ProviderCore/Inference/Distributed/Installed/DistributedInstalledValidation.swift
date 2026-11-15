import Foundation
import Darwin
import DarkbloomClusterProtocol
import ProviderCoreFoundation

/// Shared read-only installed metadata checks. This does not publish the JACCL
/// matrix, acquire a device lease, start an owner, or construct a model.
struct DistributedInstalledValidation: Sendable {
    let plan: DistributedInstalledPlan
    let verifiedInputs: [DistributedInstalledFiles.Identity]
    /// The pinned worker among `verifiedInputs`, whose launch is checked against it.
    let workerExecutable: DistributedInstalledFiles.Identity
    let manifest: ModelManifest
    let model: DistributedInstalledModel
    let workerFeatures: DistributedInstalledWorkerFeatures

    static func validate(reference: ClusterConfigurationReference, paths: ClusterUserPaths,
                         deadline: UInt64) throws -> Self {
        let saved = try ClusterConfigurationStore(paths: paths).load(reference: reference)
        var plan = try DistributedInstalledPlan(saved: saved, paths: paths)
        let local = plan.localPeer
        var inputs = [DistributedInstalledFiles.Identity]()
        let executable = try DistributedInstalledFiles.verify(URL(fileURLWithPath: local.workerExecutable),
            expectedSHA256: plan.capability.runtimeBinarySHA256, maximumBytes: 256 * 1024 * 1024,
            executable: true, deadline: deadline)
        inputs.append(executable)
        // The pinned worker must carry the collective progress guard. A pin
        // alone does not say so: it names whatever binary was installed.
        let features = try DistributedInstalledWorkerFeatures.inspect(executable, deadline: deadline)
        try features.requireProgressGuard()
        try features.requireMiMoImageCandidate(required:plan.capability.media != nil)
        try features.requireGLMImageCandidate(required: plan.capability.glmImages != nil)
        inputs.append(try DistributedInstalledFiles.verify(plan.configurationURL,
            expectedSHA256: plan.capability.configurationSHA256,
            maximumBytes: ClusterConfigurationFiles.maximumModelConfigurationBytes, deadline: deadline))
        inputs.append(try DistributedInstalledFiles.verify(plan.manifestURL,
            expectedSHA256: plan.capability.manifestSHA256, maximumBytes: 65_536, deadline: deadline))
        let manifest = try DistributedInstalledManifest.validate(
            ClusterConfigurationFiles.read(plan.manifestURL, maximum: 65_536),
            configuration: plan.configuration, capability: plan.capability)
        // The time budgets follow the verified artifact's size.
        plan = plan.withArtifactBytes(manifest.totalSizeBytes)
        let model = try DistributedInstalledModel.make(
            configurationData: ClusterConfigurationFiles.read(plan.configurationURL,
                maximum: ClusterConfigurationFiles.maximumModelConfigurationBytes),
            manifest: manifest, plan: plan)
        for file in plan.configuration.tokenizerFiles {
            inputs.append(try DistributedInstalledFiles.verify(URL(fileURLWithPath: local.modelDirectory).appendingPathComponent(file.path),
                expectedSHA256: file.sha256, maximumBytes: 64 * 1024 * 1024, deadline: deadline))
        }
        // SSH trust exists only on a setup that reaches its follower over SSH;
        // a link control setup has its edge secret instead.
        if let trust = plan.configuration.trust {
            try ClusterConfigurationFiles.credentialMetadata(URL(fileURLWithPath: trust.identityFile), privateMode: true)
            inputs.append(try DistributedInstalledFiles.verify(URL(fileURLWithPath: trust.knownHostsFile),
                expectedSHA256: trust.knownHostsSHA256, maximumBytes: 64 * 1024, deadline: deadline))
        }
        if let link = plan.configuration.linkControl {
            try Self.linkSecretMetadata(link.secretFile, pairingDirectory: paths.pairingDirectory)
        }
        // Recompute native profile/Plan/arithmetic metadata using the verified
        // installed worker. The command does not construct a model or request.
        try DistributedCapabilityProbe.verify(plan: plan, executable: executable, deadline: deadline)
        for input in inputs { try input.requireUnchanged() }

        let result = Self(plan: plan, verifiedInputs: inputs, workerExecutable: executable, manifest: manifest, model: model,
            workerFeatures: features)
        try result.requireUnchanged()
        try DistributedInstalledFiles.check(deadline)
        return result
    }

    func requireUnchanged() throws {
        for input in verifiedInputs { try input.requireUnchanged() }
        if let trust = plan.configuration.trust {
            try ClusterConfigurationFiles.credentialMetadata(URL(fileURLWithPath: trust.identityFile), privateMode: true)
        }
        if let link = plan.configuration.linkControl {
            try Self.linkSecretMetadata(link.secretFile, pairingDirectory: plan.paths.pairingDirectory)
        }
        // These are the exact file candidates opened by the existing local
        // tokenizer loader. An unpinned fallback must not become active.
        let allowed = Set(plan.configuration.tokenizerFiles.map(\.path))
        for name in ["chat_template.jinja", "chat_template.json"] where !allowed.contains(name) {
            var value = stat()
            let path = model.directory.appendingPathComponent(name).path
            guard lstat(path, &value) != 0, errno == ENOENT else {
                throw ClusterConfigurationError.invalid("Unpinned local tokenizer template exists")
            }
        }
    }

    /// A link key made by the pairing ceremony (S17) is named by its pairing's
    /// `edge-<pin>.secret` in this install's pairing store (production's
    /// `~/.darkbloom/cluster-pairing`) and kept in this Mac's Keychain
    /// (`DistributedInstalledLinkSecret`). When the pairing or its key is gone
    /// the Macs were unpaired (`darkbloom cluster pair --forget`), so say that
    /// instead of a missing credential; a locked Keychain says to log in. Any
    /// other secret is a private file. Either way the start fails.
    static func linkSecretMetadata(_ path: String,
                                   pairingDirectory: URL = DistributedInstalledLinkSecret.installPairingDirectory,
                                   vaults: DistributedInstalledLinkSecret.Vaults = DistributedInstalledLinkSecret.installVaults) throws {
        if try DistributedInstalledLinkSecret.requirePresent(path, pairingDirectory: pairingDirectory, vaults: vaults) { return }
        do { try ClusterConfigurationFiles.credentialMetadata(URL(fileURLWithPath: path), privateMode: true) } catch {
            let url = URL(fileURLWithPath: path)
            var value = stat()
            if url.deletingLastPathComponent().lastPathComponent == "cluster-pairing", url.lastPathComponent.hasPrefix("edge-"),
               lstat(path, &value) != 0, errno == ENOENT {
                throw ClusterConfigurationError.invalid(DistributedInstalledLinkSecret.unpaired)
            }
            throw error
        }
    }
}
