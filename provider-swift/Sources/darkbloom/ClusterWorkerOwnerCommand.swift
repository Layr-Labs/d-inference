import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    struct WorkerOwner: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "worker-owner",
            abstract: "Serve one configured authenticated worker-owner connection.")
        @Flag(help: "Use the authenticated supervisor's standard input and output.")
        var stdio = false

        func validate() throws {
            guard stdio else { throw ValidationError("Expected cluster worker-owner --stdio.") }
        }

        mutating func run() throws {
            // The fixed installed command takes no model, environment, ready
            // template, lease path, config override or capacity from its caller.
            let reference = try ClusterConfigurationStore.installedReference(
                providerConfiguration: ConfigManager.defaultConfigPath())
            // The rank's prefix-cache SSD key, from the product's key hierarchy
            // when this build holds it (records then survive every restart).
            ClusterPrefixSSDKeyMaterial.installAsOwnerKeySource()
            try DistributedInstalledOwner.serve(reference: reference)
        }
    }
}
