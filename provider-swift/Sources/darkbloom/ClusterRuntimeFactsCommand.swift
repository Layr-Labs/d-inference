import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// The cluster runtime facts of an app bundle (`ClusterRuntimeApprovalFacts`),
    /// printed in their canonical form: the digests a cluster approval of that
    /// build pins, each model's pair-serving grant, and the parity
    /// qualifications of the models this build declares public
    /// (`ClusterPublicModels`). A declared family left without a qualification
    /// is named on standard error. The release lane runs the final signed app's
    /// own CLI, so the declaration and the records are that build's. It reads
    /// metadata only: no model weights, no GPU, no configuration, no network
    /// and no secret.
    struct RuntimeFacts: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "runtime-facts",
            abstract: "Print the cluster runtime facts of an app bundle's cluster helpers and models.", shouldDisplay: false)
        @Option(help: "The app bundle whose Contents/Helpers are described.")
        var app: String?
        @Option(name: .customLong("model"), help: "ID=DIRECTORY or ID=CONFIG,MANIFEST of one model (repeatable).")
        var models: [String] = []
        @Option(name: .customLong("release-candidates"),
                help: "A folder of candidate model folders: describe every model this build qualifies on a cluster.")
        var releaseCandidates: String?
        @Flag(name: .customLong("list-release-models"), help: "Print the models this build qualifies on a cluster as JSON.")
        var listReleaseModels = false

        func validate() throws {
            if listReleaseModels {
                guard app == nil, models.isEmpty, releaseCandidates == nil else {
                    throw ValidationError("--list-release-models takes no other option")
                }
                return
            }
            guard app != nil, models.isEmpty != (releaseCandidates == nil) else {
                throw ValidationError("Give --app and either --model or --release-candidates")
            }
        }

        func run() throws {
            if listReleaseModels {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                FileHandle.standardOutput.write(try encoder.encode(ClusterRuntimeApprovalFacts.releaseModels))
                return
            }
            guard let app else { throw ValidationError("Give --app") }
            let installation = ClusterRuntimeApprovalFacts.Installation(app: URL(fileURLWithPath: app, isDirectory: true))
            if let releaseCandidates {
                let facts = try ClusterRuntimeApprovalFacts.release(installation: installation,
                    candidates: try ClusterRuntimeApprovalFacts.candidates(in: URL(fileURLWithPath: releaseCandidates, isDirectory: true)),
                    note: { FileHandle.standardError.write(Data("note: \($0)\n".utf8)) })
                // The release registers these bytes: they must read back under the strict decoder, and every ID a
                // coordinator derives for this build's version must fit.
                let bytes = try facts.canonicalBytes()
                _ = try ClusterRuntimeApprovalFacts(canonical: bytes)
                Self.note(facts)
                FileHandle.standardOutput.write(bytes)
                return
            }
            let given = try models.map(ClusterRuntimeApprovalFacts.modelArgument)
            let facts = try ClusterRuntimeApprovalFacts.compute(installation: installation, models: given.map { $0.files })
            let named = Set(facts.models.map(\.model)), expected = Set(given.map { $0.model })
            guard named == expected, given.count == facts.models.count else {
                throw ValidationError("The manifests name \(named.sorted().joined(separator: ", ")), not \(given.map { $0.model }.joined(separator: ", "))")
            }
            Self.note(facts)
            FileHandle.standardOutput.write(try facts.canonicalBytes())
        }

        static func note(_ facts: ClusterRuntimeApprovalFacts) {
            for line in facts.unqualifiedDeclaredFamilies() { FileHandle.standardError.write(Data("note: \(line)\n".utf8)) }
        }
    }
}
