import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    struct WorkerOwner: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "worker-owner",
            abstract: "Serve one configured authenticated worker-owner connection.", shouldDisplay: false)
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
            // when this build holds it (records then survive every restart),
            // and the product's cache settings (the same saved settings and
            // switches the single-Mac tier reads) for the rank's root and budgets.
            DistributedInstalledOwner.installWorkerDiagnosticsLog()
            ClusterPrefixSSDKeyMaterial.installAsOwnerKeySource()
            ClusterPrefixCacheSettings.installProduct(
                providerConfiguration: try ConfigManager.defaultConfigPath())
            try DistributedInstalledOwner.serve(reference: reference)
        }
    }
}
