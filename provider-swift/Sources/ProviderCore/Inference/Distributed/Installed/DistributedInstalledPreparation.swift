import Foundation
import Darwin
import DarkbloomClusterProtocol
import ProviderCoreFoundation

struct DistributedInstalledPreparation: Sendable {
    let validation: DistributedInstalledValidation
    let matrixURL: URL
    var plan: DistributedInstalledPlan { validation.plan }
    var manifest: ModelManifest { validation.manifest }
    var model: DistributedInstalledModel { validation.model }

    static func prepare(reference: ClusterConfigurationReference, paths: ClusterUserPaths,
                        deadline: UInt64) throws -> Self {
        let validation = try DistributedInstalledValidation.validate(reference: reference, paths: paths, deadline: deadline)
        let plan = validation.plan
        let bytes = try plan.matrix(), hash = ClusterConfigurationCodec.sha256(bytes)
        let directoryURL = paths.deviceDirectory.appendingPathComponent("configuration", isDirectory: true)
        let directory = try ClusterConfigurationFiles.directory(directoryURL, create: true, privateMode: true)
        defer { Darwin.close(directory.descriptor) }
        let name = hash + ".matrix.json"
        try ClusterConfigurationFiles.publish(bytes, parent: directory, name: name, maximum: 4096)
        try DistributedInstalledFiles.check(deadline)
        let result = Self(validation: validation, matrixURL: directoryURL.appendingPathComponent(name))
        try result.requireUnchanged()
        return result
    }

    func requireUnchanged() throws {
        try validation.requireUnchanged()
        let expected = try plan.matrix()
        guard try ClusterConfigurationFiles.read(matrixURL, maximum: 4096, privateMode: true) == expected else {
            throw ClusterConfigurationError.invalid("Installed matrix changed")
        }
    }
}
