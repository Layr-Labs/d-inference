import Foundation
import Darwin
import DarkbloomClusterProtocol
import ProviderCoreFoundation

struct DistributedInstalledPreparation: Sendable {
    let plan: DistributedInstalledPlan
    let verifiedInputs: [DistributedInstalledFiles.Identity]
    let matrixURL: URL
    let manifest: ModelManifest
    let model: DistributedInstalledModel

    static func prepare(reference: ClusterConfigurationReference, paths: ClusterUserPaths,
                        deadline: UInt64) throws -> Self {
        let saved = try ClusterConfigurationStore(paths: paths).load(reference: reference)
        let plan = try DistributedInstalledPlan(saved: saved, paths: paths)
        let local = plan.localPeer
        var inputs = [DistributedInstalledFiles.Identity]()
        let executable = try DistributedInstalledFiles.verify(URL(fileURLWithPath: local.workerExecutable),
            expectedSHA256: plan.capability.runtimeBinarySHA256, maximumBytes: 256 * 1024 * 1024,
            executable: true, deadline: deadline)
        inputs.append(executable)
        inputs.append(try DistributedInstalledFiles.verify(plan.configurationURL,
            expectedSHA256: plan.capability.configurationSHA256, maximumBytes: 1_048_576, deadline: deadline))
        inputs.append(try DistributedInstalledFiles.verify(plan.manifestURL,
            expectedSHA256: plan.capability.manifestSHA256, maximumBytes: 65_536, deadline: deadline))
        let manifest = try DistributedInstalledManifest.validate(
            ClusterConfigurationFiles.read(plan.manifestURL, maximum: 65_536),
            configuration: plan.configuration, capability: plan.capability)
        let model = try DistributedInstalledModel.make(
            configurationData: ClusterConfigurationFiles.read(plan.configurationURL, maximum: 1_048_576),
            manifest: manifest, plan: plan)
        for file in plan.configuration.tokenizerFiles {
            inputs.append(try DistributedInstalledFiles.verify(URL(fileURLWithPath: local.modelDirectory).appendingPathComponent(file.path),
                expectedSHA256: file.sha256, maximumBytes: 64 * 1024 * 1024, deadline: deadline))
        }
        let trust = plan.configuration.trust
        try ClusterConfigurationFiles.credentialMetadata(URL(fileURLWithPath: trust.identityFile), privateMode: true)
        inputs.append(try DistributedInstalledFiles.verify(URL(fileURLWithPath: trust.knownHostsFile),
            expectedSHA256: trust.knownHostsSHA256, maximumBytes: 64 * 1024, deadline: deadline))
        // Recompute native profile/Plan/arithmetic metadata using the verified
        // installed worker. The command does not construct a model or request.
        try DistributedCapabilityProbe.verify(plan: plan, executable: executable, deadline: deadline)
        for input in inputs { try input.requireUnchanged() }

        let bytes = try plan.matrix(), hash = ClusterConfigurationCodec.sha256(bytes)
        let directoryURL = paths.deviceDirectory.appendingPathComponent("configuration", isDirectory: true)
        let directory = try ClusterConfigurationFiles.directory(directoryURL, create: true, privateMode: true)
        defer { Darwin.close(directory.descriptor) }
        let name = hash + ".matrix.json"
        try ClusterConfigurationFiles.publish(bytes, parent: directory, name: name, maximum: 4096)
        try DistributedInstalledFiles.check(deadline)
        let result = Self(plan: plan, verifiedInputs: inputs, matrixURL: directoryURL.appendingPathComponent(name), manifest: manifest, model: model)
        try result.requireUnchanged()
        return result
    }

    func requireUnchanged() throws {
        for input in verifiedInputs { try input.requireUnchanged() }
        let expected = try plan.matrix()
        guard try ClusterConfigurationFiles.read(matrixURL, maximum: 4096, privateMode: true) == expected else {
            throw ClusterConfigurationError.invalid("Installed matrix changed")
        }
        try ClusterConfigurationFiles.credentialMetadata(URL(fileURLWithPath: plan.configuration.trust.identityFile), privateMode: true)
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
}
