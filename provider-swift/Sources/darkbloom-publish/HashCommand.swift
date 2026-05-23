import ArgumentParser
import Foundation
import ProviderCoreFoundation

struct HashCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hash",
        abstract: "Hash a model directory and emit manifest.json."
    )

    @Argument(help: "Path to the model directory (a HuggingFace snapshot dir).")
    var directory: String

    @Option(name: .long, help: "Model ID, e.g. mlx-community/openai-gpt-oss-20b.")
    var id: String

    @Option(name: .long, help: "Version tag, e.g. 2026-05-23-r1.")
    var version: String

    @Option(name: [.short, .long], help: "Output path for manifest.json. Defaults to stdout.")
    var output: String?

    mutating func validate() throws {
        // Defense-in-depth: reject obviously unsafe inputs at the CLI surface
        // so they never reach the library layer. `ManifestBuilder.build` also
        // validates internally.
        do {
            try ManifestBuilder.validateModelID(id)
        } catch let ManifestBuilder.Error.invalidModelID(_, reason) {
            throw ValidationError("--id: \(reason)")
        }
        do {
            try ManifestBuilder.validateVersion(version)
        } catch let ManifestBuilder.Error.invalidVersion(_, reason) {
            throw ValidationError("--version: \(reason)")
        }
    }

    mutating func run() async throws {
        let dirURL = URL(fileURLWithPath: directory)
        let manifest = try await ManifestBuilder.build(
            modelDirectory: dirURL,
            modelID: id,
            version: version
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)

        if let output {
            try data.write(to: URL(fileURLWithPath: output))
            FileHandle.standardError.write(
                "Wrote manifest with \(manifest.fileCount) files (aggregate \(manifest.aggregateSHA256.prefix(12))) to \(output)\n"
                .data(using: .utf8)!
            )
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        }
    }
}
