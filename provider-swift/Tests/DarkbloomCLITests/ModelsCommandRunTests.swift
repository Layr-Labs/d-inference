import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom models list|catalog|remove` against a temporary model cache
/// and a stub coordinator catalog. The commands set the process-wide model
/// cache, so every run is in its own child process (`CLICommandSandbox`).
@Suite("Models command run")
struct ModelsCommandRunTests {

    static let catalogJSON = """
        {"models":[
          {"id":"acme/Alpha-4bit","s3_name":"alpha","display_name":"Alpha","model_type":"text",
           "size_gb":1.5,"min_ram_gb":16},
          {"id":"acme/Remote-8bit","s3_name":"remote","display_name":"Remote","model_type":"text",
           "size_gb":4.0}
        ]}
        """

    @Test("list prints a table of local models, or the cache path when there are none")
    func listTable() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try await runMarked(["models", "list", "--config", sandbox.config.path], marker: "EMPTY")
            try sandbox.makeModel("acme/Alpha-4bit")
            try sandbox.makeModel("acme/Beta-4bit")
            try await runMarked(["models", "list", "--config", sandbox.config.path], marker: "TABLE")
            print("CACHE \(sandbox.cache.path)")
        }
        let output = decodedText(result.standardOutputContent)
        let cache = try #require(printedValue(output, label: "CACHE"))
        let empty = try #require(section(output, "EMPTY"))
        #expect(empty == ["No local MLX models found.", "Cache: \(cache)"])

        let table = try #require(section(output, "TABLE"))
        #expect(table.first == "Local MLX models")
        #expect(table.dropFirst().first?.hasPrefix("ID ") == true)
        #expect(table.dropFirst().first?.contains("EST MEM") == true)
        #expect(table.contains { $0.hasPrefix("acme/Alpha-4bit ") && $0.contains("llama") })
        #expect(table.contains { $0.hasPrefix("acme/Beta-4bit ") })
    }

    @Test("list --json reports the cache, the config filter and --all")
    func listJSON() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter(enabledModels: ["acme/Alpha-4bit"])
            defer { sandbox.remove() }
            try sandbox.makeModel("acme/Alpha-4bit")
            try sandbox.makeModel("acme/Beta-4bit")
            try await runMarked(["models", "list", "--config", sandbox.config.path, "--json"], marker: "FILTERED")
            try await runMarked(
                ["models", "list", "--config", sandbox.config.path, "--json", "--all"], marker: "ALL")
            print("CACHE \(sandbox.cache.path)")
        }
        let output = decodedText(result.standardOutputContent)
        let cache = try #require(printedValue(output, label: "CACHE"))

        let filtered = try jsonObject(try #require(section(output, "FILTERED")))
        #expect(filtered["cacheDirectory"] as? String == cache)
        #expect(filtered["filteredByConfig"] as? Bool == true)
        #expect(modelIDs(filtered) == ["acme/Alpha-4bit"])

        let all = try jsonObject(try #require(section(output, "ALL")))
        #expect(all["filteredByConfig"] as? Bool == false)
        #expect(modelIDs(all) == ["acme/Alpha-4bit", "acme/Beta-4bit"])
    }

    @Test("list --hash prints the weight hash as text or JSON, and rejects an unknown model")
    func listHash() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let model = try sandbox.makeModel("acme/Alpha-4bit")
            let expected = try #require(WeightHasher.computeHash(
                snapshotDir: model.appendingPathComponent("snapshots/local"), modelID: "acme/Alpha-4bit"))
            print("EXPECTED \(expected)")
            try await runMarked(
                ["models", "list", "--config", sandbox.config.path, "--hash", "acme/Alpha-4bit"], marker: "TEXT")
            try await runMarked(
                ["models", "list", "--config", sandbox.config.path, "--hash", "acme/Alpha-4bit", "--json"],
                marker: "JSON")
            let missing = try await runFailingCLICommand(
                Models.List.self,
                ["models", "list", "--config", sandbox.config.path, "--hash", "acme/Missing-4bit"])
            #expect(missing is ValidationError)
        }
        let output = decodedText(result.standardOutputContent)
        let expected = try #require(printedValue(output, label: "EXPECTED"))
        #expect(section(output, "TEXT") == ["acme/Alpha-4bit \(expected)"])
        let json = try jsonObject(try #require(section(output, "JSON")))
        #expect(json["model"] as? String == "acme/Alpha-4bit")
        #expect(json["weightHash"] as? String == expected)
    }

    @Test("catalog marks downloaded entries, shows RAM needs and lists local-only models")
    func catalogTable() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.makeModel("acme/Alpha-4bit")
            try sandbox.makeModel("acme/Orphan-4bit")
            CoordinatorStub.install([
                "/v1/models/catalog": .json(200, ModelsCommandRunTests.catalogJSON),
            ])
            try await runMarked(["models", "catalog", "--config", sandbox.config.path], marker: "CATALOG")
            #expect(CoordinatorStub.requests.map { $0.url?.host } == ["coordinator.invalid"])

            CoordinatorStub.install(["/v1/models/catalog": .json(200, #"{"models":[]}"#)])
            try await runMarked(
                ["models", "catalog", "--config", sandbox.config.path, "--type", "text"], marker: "EMPTY")
            let query = CoordinatorStub.requests.first?.url?.query
            #expect(query == "type=text")
        }
        let output = decodedText(result.standardOutputContent)
        let catalog = try #require(section(output, "CATALOG"))
        #expect(catalog.prefix(2) == ["Supported models", ""])
        #expect(catalog.contains("  ✓ Alpha  [acme/Alpha-4bit]  ~1.5 GB (≥ 16 GB RAM)"))
        #expect(catalog.contains("    Remote  [acme/Remote-8bit]  ~4.0 GB"))
        #expect(catalog.contains("Local only (not in current catalog)"))
        #expect(catalog.contains { $0.hasPrefix("  acme/Orphan-4bit  ") && $0.hasSuffix(" GB") })
        #expect(!catalog.contains { $0.hasPrefix("  acme/Alpha-4bit  ") })
        #expect(catalog.contains("  These models are no longer served by the network."))
        #expect(catalog.contains("  Remove with: darkbloom models remove <id>"))

        let empty = try #require(section(output, "EMPTY"))
        #expect(Array(empty.prefix(3)) == ["Supported models", "", "  (none)"])
    }

    @Test("catalog --json prints the coordinator entries; a coordinator error fails the command")
    func catalogJSONAndFailure() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            CoordinatorStub.install([
                "/v1/models/catalog": .json(200, ModelsCommandRunTests.catalogJSON),
            ])
            try await runMarked(
                ["models", "catalog", "--config", sandbox.config.path, "--json",
                 "--coordinator", "https://override.invalid"],
                marker: "JSON")
            #expect(CoordinatorStub.requests.map { $0.url?.host } == ["override.invalid"])

            CoordinatorStub.install(["/v1/models/catalog": .json(500, "catalog offline")])
            let error = try await runFailingCLICommand(
                Models.Catalog.self, ["models", "catalog", "--config", sandbox.config.path])
            #expect((error as? ExitCode) == .failure)
        }
        let output = decodedText(result.standardOutputContent)
        let lines = try #require(section(output, "JSON"))
        let entries = try #require(
            try JSONSerialization.jsonObject(with: Data(lines.joined(separator: "\n").utf8)) as? [[String: Any]])
        #expect(entries.compactMap { $0["id"] as? String } == ["acme/Alpha-4bit", "acme/Remote-8bit"])
        #expect(entries.first?["min_ram_gb"] as? Int == 16)
        #expect(!output.contains("Supported models"))
    }

    @Test("remove deletes a model with --force or after 'yes', and keeps it otherwise")
    func removeConfirmation() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let forced = try sandbox.makeModel("acme/Forced-4bit")
            try await runMarked(
                ["models", "remove", "acme/Forced-4bit", "--config", sandbox.config.path, "--force"],
                marker: "FORCED")
            #expect(!FileManager.default.fileExists(atPath: forced.path))

            let kept = try sandbox.makeModel("acme/Kept-4bit")
            try replaceStandardInput(with: "no\n")
            try await runMarked(
                ["models", "remove", "acme/Kept-4bit", "--config", sandbox.config.path], marker: "DECLINED")
            #expect(FileManager.default.fileExists(atPath: kept.path))

            try replaceStandardInput(with: "  YES \n")
            try await runMarked(
                ["models", "remove", "acme/Kept-4bit", "--config", sandbox.config.path], marker: "CONFIRMED")
            #expect(!FileManager.default.fileExists(atPath: kept.path))

            let error = try await runFailingCLICommand(
                Models.Remove.self, ["models", "remove", "acme/Absent-4bit", "--config", sandbox.config.path])
            #expect((error as? ExitCode) == .failure)
            print("KEPT \(kept.path)")
        }
        let output = decodedText(result.standardOutputContent)
        let kept = try #require(printedValue(output, label: "KEPT"))
        #expect(section(output, "FORCED") == ["Removed acme/Forced-4bit."])
        #expect(section(output, "DECLINED") == ["Will remove: \(kept)", "Type 'yes' to confirm:", "Skipped."])
        #expect(section(output, "CONFIRMED")
            == ["Will remove: \(kept)", "Type 'yes' to confirm:", "Removed acme/Kept-4bit."])
    }

    @Test("models defaults to the catalog and parses download and remove options")
    func parsing() throws {
        #expect(try Darkbloom.parseAsRoot(["models"]) is Models.Catalog)
        let download = try #require(try Darkbloom.parseAsRoot([
            "models", "download", "acme/Alpha-4bit", "--coordinator", "https://override.invalid",
        ]) as? Models.Download)
        #expect(download.modelID == "acme/Alpha-4bit")
        #expect(download.coordinator == "https://override.invalid")
        #expect(download.r2CDN == nil)
        let remove = try #require(try Darkbloom.parseAsRoot(["models", "remove", "acme/Alpha-4bit"]) as? Models.Remove)
        #expect(remove.modelID == "acme/Alpha-4bit")
        #expect(!remove.force)
        #expect(throws: (any Error).self) { try Darkbloom.parseAsRoot(["models", "remove"]) }
        let catalog = try #require(try Darkbloom.parseAsRoot(["models", "catalog", "--type", "text"]) as? Models.Catalog)
        #expect(catalog.type == "text")
        #expect(!catalog.json)
    }

    // MARK: - Output helpers

    /// The lines printed after the `== name` marker and before the next marker.
    private func section(_ output: String, _ name: String) -> [String]? {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "== \(name)") else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("== ") || $0.hasPrefix("CACHE ") || $0.hasPrefix("KEPT ") }
            ?? rest.endIndex
        var body = Array(rest[rest.startIndex..<end])
        while body.last == "" { body.removeLast() }
        return body
    }

    private func jsonObject(_ lines: [String]) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(lines.joined(separator: "\n").utf8)) as? [String: Any])
    }

    private func modelIDs(_ object: [String: Any]) -> [String] {
        ((object["models"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
    }
}

/// Prints `== marker`, then parses and runs one `models` subcommand.
private func runMarked(_ arguments: [String], marker: String) async throws {
    print("== \(marker)")
    guard var command = try Darkbloom.parseAsRoot(arguments) as? any AsyncParsableCommand else {
        throw CLICommandSandboxError.unexpectedCommand(arguments.joined(separator: " "))
    }
    try await command.run()
}
