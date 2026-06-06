import Foundation
import ArgumentParser
import ProviderCore

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage MLX models.",
        discussion: """
        Subcommands:
          catalog   Show available models with download status (default).
          list      Show local models only.
          download  Download a catalog model into ~/.cache/huggingface/hub.
          update    Re-download installed models whose catalog revision changed.
          remove    Delete a downloaded model.

        With no subcommand, shows the full catalog.
        """,
        subcommands: [Catalog.self, List.self, Download.self, Update.self, Remove.self],
        defaultSubcommand: Catalog.self
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
            await runUpdateBannerIfEnabled()

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

            let localModels: [ModelInfo]
            if let hardware = snapshot.hardware {
                localModels = ModelScanner.scanModels(hardwareInfo: hardware)
            } else {
                localModels = []
            }
            let downloadedIDs = Set(localModels.map(\.id))
            let catalogIDs = Set(entries.map(\.id))

            // -- Supported models (from coordinator catalog) --
            print("Supported models")
            print()

            if entries.isEmpty {
                print("  (none)")
            } else {
                for entry in entries {
                    let mark = downloadedIDs.contains(entry.id) ? "✓" : " "
                    let mem = entry.minRamGb.map { " (≥ \($0) GB RAM)" } ?? ""
                    let update: String
                    if case .outdated = ModelDownloader.revisionStatus(for: entry) {
                        update = "  ⬆ update available (darkbloom models update \(entry.id))"
                    } else {
                        update = ""
                    }
                    print("  \(mark) \(entry.displayName)  [\(entry.id)]  ~\(String(format: "%.1f", entry.sizeGb)) GB\(mem)\(update)")
                }
            }

            // -- Local-only models (downloaded but not in current catalog) --
            let localOnly = localModels.filter { !catalogIDs.contains($0.id) }
            if !localOnly.isEmpty {
                print()
                print("Local only (not in current catalog)")
                print()
                for m in localOnly {
                    print("  \(m.id)  \(String(format: "%.1f", m.estimatedMemoryGb)) GB")
                }
                print()
                print("  These models are no longer served by the network.")
                print("  Remove with: darkbloom models remove <id>")
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
            let downloader = ModelDownloader(r2CDNURL: r2CDN, catalogClient: client)
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

// MARK: - update

extension Models {
    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Re-download installed models whose catalog revision changed.",
            discussion: """
            Compares the recorded revision of each locally installed model
            against the coordinator catalog. When a model's revision has
            changed, the new revision is downloaded into a staging directory
            and atomically swapped in, replacing the old copy.

            Models that are not installed are skipped -- this updates existing
            copies only; use `darkbloom models download <id>` to install.

            With no <model-id>, every installed catalog model is checked.
            With --background, the update runs in a detached process and logs
            to ~/.darkbloom/model-update.log so it survives the shell exiting.
            """
        )

        @OptionGroup var configOptions: ConfigOptions

        @Argument(help: "Model ID to update. Omit to check all installed models.")
        var modelID: String?

        @Option(help: "Override coordinator URL.")
        var coordinator: String?

        @Option(help: "Override the R2 CDN base URL.")
        var r2CDN: String?

        @Flag(help: "Also re-download installed models that have no recorded revision (predating revision tracking).")
        var includeUntracked = false

        @Flag(help: "Run the update in a detached background process.")
        var background = false

        /// Log file for `--background` runs.
        static func backgroundLogURL() -> URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".darkbloom/model-update.log")
        }

        mutating func run() async throws {
            if background {
                try launchInBackground()
                return
            }

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

            // Resolve the set of catalog entries to check.
            let targets: [CatalogModel]
            if let modelID {
                guard let entry = catalog.first(where: { $0.id == modelID || $0.s3Name == modelID }) else {
                    printError("model '\(modelID)' is not in the coordinator catalog")
                    printError("hint: list available IDs with `darkbloom models catalog`")
                    throw ExitCode.failure
                }
                targets = [entry]
            } else {
                // All installed catalog models (skip not-installed silently).
                targets = catalog.filter {
                    ModelDownloader.revisionStatus(for: $0) != .notInstalled
                }
            }

            if targets.isEmpty {
                print("No installed models to check.")
                return
            }

            let downloader = ModelDownloader(r2CDNURL: r2CDN, catalogClient: client)
            var replaced = 0
            var failures = 0

            for entry in targets {
                let status = ModelDownloader.revisionStatus(for: entry)
                switch status {
                case .notInstalled:
                    // Only reachable for an explicit <model-id>.
                    print("\(entry.id): not installed — skipping (use `models download`).")
                case .upToDate:
                    print("\(entry.id): up to date.")
                case .unknown where !includeUntracked:
                    print("\(entry.id): no recorded revision — skipping (pass --include-untracked to re-download).")
                case .unknown, .outdated:
                    switch status {
                    case .outdated(let local, let remote):
                        print("\(entry.id): outdated (\(local ?? "?") → \(remote ?? "?")) — downloading…")
                    default:
                        print("\(entry.id): no recorded revision — re-downloading current revision…")
                    }
                    do {
                        let outcome = try await downloader.downloadIfOutdated(
                            model: entry,
                            replaceUntracked: includeUntracked
                        ) { progress in
                            let mb = Double(progress.bytesDownloaded) / 1_048_576
                            print("  ✓ \(progress.file)  \(String(format: "%.1f MB", mb))")
                        }
                        if case .replaced(let from, let to) = outcome {
                            print("\(entry.id): replaced \(from ?? "?") → \(to ?? "?").")
                            replaced += 1
                        }
                    } catch let error as ModelCatalogError {
                        printError("\(entry.id): \(error)")
                        failures += 1
                    }
                }
            }

            print("Done. \(replaced) replaced, \(failures) failed, \(targets.count) checked.")
            if failures > 0 { throw ExitCode.failure }
        }

        /// Re-exec this command (minus --background) as a detached child whose
        /// output is appended to `model-update.log`, then return immediately.
        private func launchInBackground() throws {
            guard let executable = Bundle.main.executablePath else {
                printError("could not determine the darkbloom executable path")
                throw ExitCode.failure
            }

            var childArgs = ["models", "update"]
            if let modelID { childArgs.append(modelID) }
            if let coordinator { childArgs += ["--coordinator", coordinator] }
            if let r2CDN { childArgs += ["--r2-cdn", r2CDN] }
            if includeUntracked { childArgs.append("--include-untracked") }
            if let config = configOptions.config { childArgs += ["--config", config] }

            let logURL = Self.backgroundLogURL()
            let fm = FileManager.default
            try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: logURL.path) {
                fm.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = childArgs
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = handle
            // Suppress the child's startup update banner so logs stay focused.
            var env = ProcessInfo.processInfo.environment
            env["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
            process.environment = env

            do {
                try process.run()
            } catch {
                printError("could not start background update: \(error.localizedDescription)")
                throw ExitCode.failure
            }

            // Detach: do not wait. The child is reparented to launchd when we
            // exit and keeps running.
            print("Model update running in background (pid \(process.processIdentifier)).")
            print("Logs: \(logURL.path)")
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
