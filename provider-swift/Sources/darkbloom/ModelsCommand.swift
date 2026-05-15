import Foundation
import ArgumentParser
import ProviderCore

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage local MLX models.",
        discussion: """
        Subcommands:
          list      Show local models (default).
          catalog   Show the coordinator's supported-model catalog.
          download  Download a catalog model into ~/.cache/huggingface/hub.
          remove    Delete a downloaded model.

        With no subcommand, prints the local models table.
        """,
        subcommands: [List.self, Catalog.self, Download.self, Remove.self],
        defaultSubcommand: List.self
    )
}

// MARK: - list

extension Models {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List locally cached MLX models."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Flag(help: "Emit JSON instead of a table.")
        var json = false

        @Flag(help: "Show every discovered local model, ignoring the config enabled_models filter.")
        var all = false

        @Option(help: "Compute an on-demand integrity hash for one model ID.")
        var hash: String?

        mutating func run() async throws {
            if let hash {
                let digest = WeightHasher.computeHash(for: hash)
                guard let digest else {
                    throw ValidationError("could not compute weight hash for '\(hash)'")
                }
                if json {
                    try printJSON(HashOutput(model: hash, weightHash: digest))
                } else {
                    print("\(hash) \(digest)")
                }
                return
            }

            let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
            let models = advertisedModels(
                from: snapshot.models,
                config: snapshot.config,
                includeDisabled: all
            )

            if json {
                let payload = ModelsOutput(
                    cacheDirectory: ModelScanner.defaultCacheDirectory()?.path,
                    filteredByConfig: !all && !snapshot.config.backend.enabledModels.isEmpty,
                    models: models
                )
                try printJSON(payload)
                return
            }

            guard !models.isEmpty else {
                print("No local MLX models found.")
                if let cache = ModelScanner.defaultCacheDirectory() {
                    print("Cache: \(cache.path)")
                }
                return
            }

            print("Local MLX models")
            printModelTable(models)
        }
    }
}

// MARK: - catalog

extension Models {
    struct Catalog: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the coordinator's supported-model catalog."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Option(help: "Override coordinator URL.")
        var coordinator: String?

        @Flag(help: "Emit JSON instead of a table.")
        var json = false

        @Option(help: "Filter by model_type (e.g. text).")
        var type: String?

        mutating func run() async throws {
            let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
            let coordinatorURL = coordinator ?? snapshot.config.coordinator.url
            let client = ModelCatalogClient(coordinatorURL: coordinatorURL)

            let entries: [CatalogModel]
            do {
                entries = try await client.fetchCatalog(typeFilter: type)
            } catch let error as ModelCatalogError {
                printError("\(error)")
                throw ExitCode.failure
            }

            if json {
                try printJSON(entries)
                return
            }

            print("Coordinator catalog (\(coordinatorHTTPBase(coordinatorURL)))")
            print("Models: \(entries.count)")
            print()

            let downloadedIDs: Set<String>
            if let hardware = snapshot.hardware {
                downloadedIDs = Set(ModelScanner.scanModels(hardwareInfo: hardware).map(\.id))
            } else {
                downloadedIDs = []
            }

            for entry in entries {
                let mark = downloadedIDs.contains(entry.id) ? "✓" : "·"
                let mem = entry.minRamGb.map { " (≥ \($0) GB RAM)" } ?? ""
                print("  \(mark) \(entry.displayName)  [\(entry.id)]  ~\(String(format: "%.1f", entry.sizeGb)) GB\(mem)")
            }
        }
    }
}

// MARK: - download

extension Models {
    struct Download: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download a model from the coordinator catalog."
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Model ID (or s3 name) to download.")
        var modelID: String

        @Option(help: "Override coordinator URL.")
        var coordinator: String?

        @Option(help: "Override the R2 CDN base URL.")
        var r2CDN: String?

        mutating func run() async throws {
            let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
            let coordinatorURL = coordinator ?? snapshot.config.coordinator.url
            let client = ModelCatalogClient(coordinatorURL: coordinatorURL)

            let catalog: [CatalogModel]
            do {
                catalog = try await client.fetchCatalog(typeFilter: nil)
            } catch let error as ModelCatalogError {
                printError("could not fetch catalog: \(error)")
                throw ExitCode.failure
            }

            guard let entry = catalog.first(where: { $0.id == modelID || $0.s3Name == modelID }) else {
                printError("model '\(modelID)' is not in the coordinator catalog")
                printError("hint: list available IDs with `darkbloom models catalog`")
                throw ExitCode.failure
            }

            print("Downloading \(entry.displayName) (\(entry.id))…")
            let downloader = ModelDownloader(r2CDNURL: r2CDN)
            do {
                try await downloader.download(model: entry) { progress in
                    let mb = Double(progress.bytesDownloaded) / 1_048_576
                    print("  ✓ \(progress.file)  \(String(format: "%.1f MB", mb))")
                }
            } catch let error as ModelCatalogError {
                printError("\(error)")
                throw ExitCode.failure
            }

            print("Done. Cached at \(ModelDownloader.cacheModelDirectory(for: entry.id).path)")
        }
    }
}

// MARK: - remove

extension Models {
    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a downloaded model from the local cache."
        )

        @Argument(help: "Model ID to remove.")
        var modelID: String

        @Flag(help: "Skip the confirmation prompt.")
        var force = false

        mutating func run() async throws {
            let dir = ModelDownloader.cacheModelDirectory(for: modelID)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                printError("no local copy of '\(modelID)' (looked at \(dir.path))")
                throw ExitCode.failure
            }

            if !force {
                print("Will remove: \(dir.path)")
                print("Type 'yes' to confirm:")
                let line = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                if line.lowercased() != "yes" {
                    print("Skipped.")
                    return
                }
            }

            do {
                try ModelDownloader.remove(modelID: modelID)
                print("Removed \(modelID).")
            } catch {
                printError("failed to remove: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }
    }
}
