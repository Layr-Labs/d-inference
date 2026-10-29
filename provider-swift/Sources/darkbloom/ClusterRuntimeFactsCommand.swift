import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// The cluster runtime facts of an app bundle (`ClusterRuntimeApprovalFacts`),
    /// printed in their canonical form: the digests the guided setup registers
    /// with the coordinator for a model. It reads metadata only: no model
    /// weights, no GPU, no configuration, no network and no secret.
    struct RuntimeFacts: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "runtime-facts",
            abstract: "Print the cluster runtime facts of an app bundle's cluster helpers and models.", shouldDisplay: false)
        @Option(help: "The app bundle whose Contents/Helpers are described.")
        var app: String
        @Option(name: .customLong("model"), help: "ID=DIRECTORY or ID=CONFIG,MANIFEST of one model (repeatable).")
        var models: [String] = []

        func validate() throws {
            guard !models.isEmpty else { throw ValidationError("Give at least one --model") }
        }

        func run() throws {
            let installation = ClusterRuntimeApprovalFacts.Installation(app: URL(fileURLWithPath: app, isDirectory: true))
            let given = try models.map(ClusterRuntimeApprovalFacts.modelArgument)
            let facts = try ClusterRuntimeApprovalFacts.compute(installation: installation, models: given.map { $0.files })
            let named = Set(facts.models.map(\.model)), expected = Set(given.map { $0.model })
            guard named == expected, given.count == facts.models.count else {
                throw ValidationError("The manifests name \(named.sorted().joined(separator: ", ")), not \(given.map { $0.model }.joined(separator: ", "))")
            }
            FileHandle.standardOutput.write(try facts.canonicalBytes())
        }
    }
}
