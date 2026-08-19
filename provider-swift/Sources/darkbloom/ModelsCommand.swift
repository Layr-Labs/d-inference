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
          remove    Delete a downloaded model.

        With no subcommand, shows the full catalog.
        """,
        subcommands: [Catalog.self, List.self, Download.self, Remove.self],
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

            // UNFILTERED on-disk scan: a downloaded model that exceeds available
            // RAM is still on disk, so it must show the "downloaded" checkmark
            // (and appear under "Local only" when off-catalog) rather than reading
            // as not-downloaded on a marginal-RAM box. The memory filter only
            // governs loadability, not presence.
            let localModels: [ModelInfo]
            if let hardware = snapshot.hardware {
                localModels = ModelScanner.scanAllModels(hardwareInfo: hardware)
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
                    print("  \(mark) \(entry.displayName)  [\(entry.id)]  ~\(String(format: "%.1f", entry.sizeGb)) GB\(mem)")
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

        @Flag(help: "Emit newline-delimited JSON download events on stdout instead of human progress output.")
        var json = false

        mutating func run() async throws {
            let emitter = ModelsDownloadEventEmitter()
            let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
            let coordinatorURL = coordinator ?? snapshot.config.coordinator.url
            let client = ModelCatalogClient(coordinatorURL: coordinatorURL)

            let catalog: [CatalogModel]
            do {
                catalog = try await client.fetchCatalog(typeFilter: nil)
            } catch let error as ModelCatalogError {
                emitter.failIfJSON(enabled: json, message: "could not fetch catalog: \(error)")
                printError("could not fetch catalog: \(error)")
                throw ExitCode.failure
            }

            guard let entry = catalog.first(where: { $0.id == modelID || $0.s3Name == modelID }) else {
                emitter.failIfJSON(enabled: json, message: "model '\(modelID)' is not in the coordinator catalog")
                printError("model '\(modelID)' is not in the coordinator catalog")
                printError("hint: list available IDs with `darkbloom models catalog`")
                throw ExitCode.failure
            }

            if json {
                try await runJSON(entry: entry, client: client, emitter: emitter)
                return
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

        /// NDJSON mode: `ModelsDownloadEventEmitter` renders every downloader
        /// event (plus terminal done/error) as one compact JSON object per
        /// stdout line for machine consumers like the Darkbloom app. Human
        /// output stays on stderr-only paths (printError).
        private func runJSON(
            entry: CatalogModel,
            client: ModelCatalogClient,
            emitter: ModelsDownloadEventEmitter
        ) async throws {
            let downloader = ModelDownloader(r2CDNURL: r2CDN, catalogClient: client)
            do {
                try await downloader.download(model: entry, onEvent: { event in
                    emitter.emit(event, model: entry.id)
                })
            } catch is CancellationError {
                // Terminated mid-download (e.g. the app's parent process killed
                // us): the staged `.part` bytes stay on disk for a later resume.
                // No error line — the caller knows it cancelled.
                throw CancellationError()
            } catch let error as ModelCatalogError {
                emitter.failure(message: "\(error)")
                printError("\(error)")
                throw ExitCode.failure
            } catch {
                emitter.failure(message: error.localizedDescription)
                printError("\(error.localizedDescription)")
                throw ExitCode.failure
            }
            emitter.done(model: entry.id)
        }
    }
}

// MARK: - download --json NDJSON emitter

/// Machine-facing event stream for `darkbloom models download --json`: one
/// compact JSON object per stdout line.
///
/// Line shapes (keys sorted; nil fields omitted):
///   {"bytes":N,"event":"progress","file":F,"model":M,"total":N}
///   {"event":"verifying","model":M}
///   {"event":"done","model":M}
///   {"event":"error","message":M}
///
/// `progress.bytes` is CUMULATIVE bytes on disk for `file` — a resumed
/// `.part` prefix is included, so consumers never see the bar restart at 0
/// for a resumed download. `total` is present only when the manifest
/// declares the file's size (the legacy CDN path emits `total: null`-less
/// events). `verifying` fires once all bytes are staged, while the aggregate
/// hash is checked; `done` fires after the snapshot is published. Failures
/// also repeat on stderr and exit non-zero, so a consumer may rely on either
/// channel.
///
/// Progress lines are rate-limited per file (stdout is a pipe into a UI, not
/// a terminal): the first line per file, any completion line (bytes ≥
/// total), and at most one line per `minProgressInterval` per file escape
/// the throttle. Structured events (`verifying`/`done`/`error`) are never
/// throttled.
final class ModelsDownloadEventEmitter: @unchecked Sendable {

    /// One NDJSON line. Non-nil fields only; keys sort deterministically.
    struct Line: Encodable {
        let event: String
        let model: String?
        let file: String?
        let bytes: Int64?
        let total: Int64?
        let message: String?
    }

    private let minProgressInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let write: @Sendable (String) -> Void

    private let lock = NSLock()
    private var lastProgressEmission: [String: Date] = [:]

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Unescaped slashes: model IDs ("org/name") dominate the stream and
        // stay greppable that way; both forms are legal JSON anyway.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(
        minProgressInterval: TimeInterval = 0.2,
        now: @escaping @Sendable () -> Date = { Date() },
        write: @escaping @Sendable (String) -> Void = { line in
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    ) {
        self.minProgressInterval = minProgressInterval
        self.now = now
        self.write = write
    }

    /// Map a ProviderCore download event onto the wire schema.
    func emit(_ event: ModelDownloader.DownloadEvent, model: String) {
        switch event.phase {
        case .progress:
            progress(
                file: event.file,
                bytes: event.bytesDownloaded,
                total: event.bytesTotal,
                model: model
            )
        case .verifying:
            verifying(model: model)
        }
    }

    func progress(file: String, bytes: Int64, total: Int64?, model: String) {
        lock.lock()
        let isFirstForFile = lastProgressEmission[file] == nil
        let isComplete = total.map { bytes >= $0 } ?? false
        let isDue = now().timeIntervalSince(lastProgressEmission[file] ?? .distantPast) >= minProgressInterval
        guard isFirstForFile || isComplete || isDue else {
            lock.unlock()
            return
        }
        lastProgressEmission[file] = now()
        lock.unlock()
        writeLine(Line(event: "progress", model: model, file: file, bytes: bytes, total: total, message: nil))
    }

    func verifying(model: String) {
        writeLine(Line(event: "verifying", model: model, file: nil, bytes: nil, total: nil, message: nil))
    }

    func done(model: String) {
        writeLine(Line(event: "done", model: model, file: nil, bytes: nil, total: nil, message: nil))
    }

    func failure(message: String) {
        writeLine(Line(event: "error", model: nil, file: nil, bytes: nil, total: nil, message: message))
    }

    /// Emit an error line only in `--json` mode; shared by the pre-download
    /// failure paths so machine consumers see the same failure text stderr
    /// already carries.
    func failIfJSON(enabled: Bool, message: String) {
        guard enabled else { return }
        failure(message: message)
    }

    private func writeLine(_ line: Line) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? encoder.encode(line),
              let string = String(data: data, encoding: .utf8) else { return }
        write(string)
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
