import Foundation
import ArgumentParser
import ProviderCore

struct Cluster: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cluster",
        abstract: "Manage saved distributed-cluster setup.", subcommands: [Configure.self, WorkerOwner.self])

    struct Configure: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "configure",
            abstract: "Validate and save cluster setup without enabling or starting it.")
        @OptionGroup var configOptions: ConfigOptions
        @Option(help: "Absolute path to the bounded cluster configuration JSON.")
        var input: String
        @Option(help: "Absolute path to a canonical installed-runtime capability JSON.")
        var capability: String
        @Option(name: .customLong("capability-sha256"), help: "Expected SHA-256 of the exact capability bytes.")
        var capabilitySHA256: String
        @Flag(help: "Print the saved configuration references and verification scope as JSON.")
        var json = false

        func validate() throws {
            _ = try absolute(input); _ = try absolute(capability)
            if let path = configOptions.config { _ = try absolute(path) }
            guard capabilitySHA256.utf8.count == 64 && capabilitySHA256.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else { throw ValidationError("Expected a lowercase SHA-256 capability pin.") }
        }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            // This command deliberately does not load a RuntimeSnapshot: no
            // hardware/model discovery, update banner, enrollment or connection.
            let paths = try ClusterUserPaths()
            let providerPath = try configOptions.config ?? ConfigManager.defaultConfigPath().path
            let result = try ClusterConfigurationStore(paths: paths).configure(
                configurationInput: absolute(input), capabilityInput: absolute(capability),
                capabilitySHA256: capabilitySHA256, providerConfiguration: absolute(providerPath))
            if json { try printJSON(result) }
            else {
                print("Saved cluster setup: \(result.configuration)")
                print("Distributed startup remains disabled. Installation, remote trust, model files and readiness still require checks.")
            }
        }

        private func absolute(_ path: String) throws -> URL {
            guard path.hasPrefix("/"), !path.contains("\0") else {
                throw ValidationError("Cluster configuration inputs require absolute local paths.")
            }
            return URL(fileURLWithPath: path)
        }
    }
}
