import Foundation
import ArgumentParser
import Logging
import ProviderCore

// NOTE: entry point lives in main.swift (not @main here). The long-running serve
// modes are hosted under an NSApplication(.accessory) run loop so the process can
// receive APNs code-identity challenges (v0.6.0); see ProviderAppKitHost. All
// other commands run through the normal async dispatch.
//
// The availability annotation is required because we invoke `Darkbloom.main()`
// from main.swift instead of via `@main` (which would synthesize it): an async
// root ParsableCommand must be annotated to run asynchronously.
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Darkbloom: AsyncParsableCommand {

    // Bootstrap swift-log to write to stderr so launchd captures output
    // in provider.log. Without this, all Logger calls go to the no-op
    // handler and produce zero output.
    static let _bootstrapLogging: Void = {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
    }()

    static let configuration = CommandConfiguration(
        commandName: "darkbloom",
        abstract: "Swift-native provider CLI for Darkbloom.",
        discussion: "Runs on Apple Silicon Macs. Connects to the coordinator, serves inference requests via mlx-swift.",
        version: ProviderCore.version,
        subcommands: [
            Start.self,
            Stop.self,
            Restart.self,
            Status.self,
            Doctor.self,
            Models.self,
            Local.self,
            Login.self,
            Logout.self,
            Benchmark.self,
            Update.self,
            Verify.self,
            Enroll.self,
            Unenroll.self,
            Logs.self,
            Report.self,
            AutoUpdate.self,
            Beta.self,
            Watchdog.self,
        ]
    )

    mutating func run() async throws {
        _ = Self._bootstrapLogging
        throw CleanExit.helpRequest(self)
    }

    /// Call at the start of every subcommand's run() to ensure logging is initialized.
    static func ensureLogging() {
        _ = _bootstrapLogging
    }
}

// MARK: - Update banner (best-effort, non-blocking)

/// Run the update banner before any subcommand executes. Uses a hard
/// 2-second timeout; failures are silently swallowed. Skipped when the
/// `DARKBLOOM_NO_UPDATE_CHECK` env var is set (handy for tests + CI).
///
/// Subcommands invoke this via the top-level `Darkbloom` parsable type
/// being the entry point; we hook it in `main` of each subcommand
/// indirectly by calling at the start of any `run()` that wants it.
public func runUpdateBannerIfEnabled() async {
    if ProcessInfo.processInfo.environment["DARKBLOOM_NO_UPDATE_CHECK"] != nil {
        return
    }
    // Do NOT construct ConfigOptions() directly -- its @Option property
    // wrapper is uninitialized outside ArgumentParser's decoding lifecycle
    // and accessing it causes a fatal error. Pass nil to use defaults.
    let coordinatorURL: String
    do {
        let config = try loadProviderConfig(configPath: nil)
        coordinatorURL = config.coordinator.url
    } catch {
        coordinatorURL = "https://api.darkbloom.dev"
    }
    await UpdateBanner.run(coordinatorURL: coordinatorURL)
}

// MARK: - Shared Options

struct ConfigOptions: ParsableArguments {
    @Option(name: [.customShort("c"), .long], help: "Path to provider TOML config.")
    var config: String? = nil
}

// MARK: - Runtime Snapshot

struct RuntimeSnapshot {
    let configPath: URL
    let configFileExists: Bool
    let config: ProviderConfig
    let hardware: HardwareInfo?
    let hardwareError: Error?
    /// Local models that fit in currently-available memory (the provider's
    /// actual loadable set).
    let models: [ModelInfo]
    /// All locally-discovered models, including those too large for current
    /// available memory. Used by diagnostics so too-large supported models are
    /// still flagged rather than silently skipped.
    let allModels: [ModelInfo]
    /// Coordinator catalog fetched at load time. `nil` means the catalog could
    /// not be fetched and no cached catalog was available; callers should treat
    /// it as an empty catalog (fail closed) and warn the operator.
    let catalog: CatalogSnapshot?
}

func loadRuntimeSnapshot(configOptions: ConfigOptions, coordinatorURLOverride: String? = nil) async throws -> RuntimeSnapshot {
    Darkbloom.ensureLogging()
    return try await loadRuntimeSnapshot(configPath: configOptions.config, coordinatorURLOverride: coordinatorURLOverride)
}

func loadRuntimeSnapshot(configPath rawPath: String?, coordinatorURLOverride: String? = nil) async throws -> RuntimeSnapshot {
    let configPath = try resolveConfigPath(rawPath)
    let configFileExists = FileManager.default.fileExists(atPath: configPath.path)

    let config = try loadProviderConfig(configPath: configPath, configFileExists: configFileExists)

    let hardware: HardwareInfo?
    let hardwareError: Error?
    do {
        hardware = try HardwareDetector.detect()
        hardwareError = nil
    } catch {
        hardware = nil
        hardwareError = error
    }

    // Scan both the loadable subset and the full unfiltered local set.
    // Diagnostics need the unfiltered list so too-large supported models are
    // still diagnosed rather than silently skipped.
    let allModels = hardware.map { ModelScanner.scanAllModels(hardwareInfo: $0) } ?? []
    let models: [ModelInfo]
    if let hardware {
        models = allModels.filter { $0.estimatedMemoryGb <= Double(hardware.memoryAvailableGb) }
    } else {
        models = []
    }

    // Fetch the coordinator catalog. Use the CLI-provided override if present
    // so `--coordinator-url` changes the catalog source as well as the connect
    // target. A cached snapshot is used as a fallback so offline commands can
    // still distinguish supported models.
    let catalogURL = coordinatorURLOverride ?? config.coordinator.url
    let catalog = await fetchCatalogSnapshot(coordinatorURL: catalogURL)

    return RuntimeSnapshot(
        configPath: configPath,
        configFileExists: configFileExists,
        config: config,
        hardware: hardware,
        hardwareError: hardwareError,
        models: models,
        allModels: allModels,
        catalog: catalog
    )
}

/// Load just the provider config, without scanning models or fetching the
/// coordinator catalog. Useful for commands that only need the coordinator URL.
func loadProviderConfig(configPath rawPath: String?) throws -> ProviderConfig {
    let configPath = try resolveConfigPath(rawPath)
    let configFileExists = FileManager.default.fileExists(atPath: configPath.path)
    return try loadProviderConfig(configPath: configPath, configFileExists: configFileExists)
}

private func loadProviderConfig(configPath: URL, configFileExists: Bool) throws -> ProviderConfig {
    let hardware: HardwareInfo?
    do {
        hardware = try HardwareDetector.detect()
    } catch {
        hardware = nil
    }

    var config: ProviderConfig
    if configFileExists {
        config = try ConfigManager.load(from: configPath)
    } else if let hardware {
        config = ProviderConfig.defaultForHardware(hardware)
    } else {
        config = ConfigManager.loadDefault()
    }

    // Auto-migrate stale config values (idempotent, best-effort).
    config = migrateConfigIfNeeded(configPath: configPath, config: config)
    return config
}

private func fetchCatalogSnapshot(coordinatorURL: String) async -> CatalogSnapshot? {
    let client = ModelCatalogClient(coordinatorURL: coordinatorURL)
    let cachePath = CatalogCache.path(for: coordinatorURL)
    do {
        let snapshot = try await client.fetchCatalogSnapshot(includeAliases: true)
        CatalogCache.write(snapshot, to: cachePath)
        return snapshot
    } catch {
        // Fall back to the on-disk cache scoped to this coordinator so
        // switching between prod/staging/self-hosted coordinators does not
        // cross-pollute offline fallback state.
        return CatalogCache.read(from: cachePath)
    }
}

private func resolveConfigPath(_ rawPath: String?) throws -> URL {
    if let rawPath {
        return URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
    }
    return try ConfigManager.defaultConfigPath()
}

// MARK: - Config Migration

/// Production coordinator WebSocket URL.
private let productionCoordinatorURL = "wss://api.darkbloom.dev/ws/provider"

/// Stale coordinator URLs to rewrite, ordered longest-first so a
/// `/ws/provider`-suffixed variant is replaced before its bare host form.
private let staleCoordinatorURLs: [(pattern: String, label: String)] = [
    ("ws://localhost:8080/ws/provider", "localhost"),
    ("http://localhost:8080/ws/provider", "localhost"),
    ("wss://api.dev.darkbloom.xyz/ws/provider", "api.dev.darkbloom.xyz"),
    ("ws://localhost:8080", "localhost"),
    ("http://localhost:8080", "localhost"),
    ("wss://api.dev.darkbloom.xyz", "api.dev.darkbloom.xyz"),
]

/// Migrate stale config values in-place. Runs on every startup; idempotent.
///
/// 1. **Legacy path**: if the resolved config lives at a non-canonical path
///    and `~/.config/darkbloom/provider.toml` does not exist yet, copy the
///    file there (keeping the old one for backward compat).
/// 2. **Coordinator URL**: if the TOML text contains a known stale
///    coordinator URL (localhost, dev), rewrite it to production in-place.
func migrateConfigIfNeeded(configPath: URL, config: ProviderConfig) -> ProviderConfig {
    let fm = FileManager.default
    guard fm.fileExists(atPath: configPath.path) else { return config }

    let home = fm.homeDirectoryForCurrentUser
    let canonicalPath = home
        .appendingPathComponent(".config")
        .appendingPathComponent("darkbloom")
        .appendingPathComponent("provider.toml")

    // --- 1. Legacy path → canonical path copy ---
    var copiedToCanonical = false
    if configPath.standardizedFileURL != canonicalPath.standardizedFileURL
        && !fm.fileExists(atPath: canonicalPath.path) {
        do {
            let dir = canonicalPath.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: configPath, to: canonicalPath)
            copiedToCanonical = true
            printError("  Migrated config to \(canonicalPath.path)")
        } catch {
            // best-effort; don't block startup
        }
    }

    // --- 2. Coordinator URL migration ---
    var didMigrateURL = false
    var migratedLabel: String?

    // Migrate the file we loaded from.
    if let label = rewriteStaleURLs(in: configPath) {
        didMigrateURL = true
        migratedLabel = label
    }

    // If we just copied to canonical, fix URLs there too so the next
    // startup (which will resolve to canonical first) is already clean.
    if copiedToCanonical {
        if let label = rewriteStaleURLs(in: canonicalPath) {
            didMigrateURL = true
            migratedLabel = migratedLabel ?? label
        }
    }

    if didMigrateURL {
        let source = migratedLabel ?? "stale URL"
        printError("  Migrated coordinator URL from \(source) to api.darkbloom.dev")
        var updated = config
        updated.coordinator.url = productionCoordinatorURL
        return updated
    }

    return config
}

/// Replace stale coordinator URLs in a TOML file via string replacement.
/// Returns the human-readable label of the matched pattern, or `nil` if
/// the file was already clean.
private func rewriteStaleURLs(in path: URL) -> String? {
    guard var content = try? String(contentsOf: path, encoding: .utf8) else {
        return nil
    }

    var matched: String?
    for (old, label) in staleCoordinatorURLs {
        if content.contains(old) {
            content = content.replacingOccurrences(of: old, with: productionCoordinatorURL)
            matched = label
        }
    }

    guard let matched else { return nil }

    do {
        try content.write(to: path, atomically: true, encoding: .utf8)
        return matched
    } catch {
        return nil
    }
}

func describeConfigPath(_ snapshot: RuntimeSnapshot) -> String {
    if snapshot.configFileExists {
        return snapshot.configPath.path
    }
    return "\(snapshot.configPath.path) (missing, using defaults)"
}

/// Filter local models to those present in the coordinator catalog.
/// Non-catalog weights are invisible to the network and should not be
/// advertised, served, or diagnosed. If the catalog is unavailable, fail
/// closed and return an empty list.
func catalogFilteredModels(
    _ models: [ModelInfo],
    catalog: CatalogSnapshot?
) -> [ModelInfo] {
    guard let catalog else { return [] }
    let allowed = Set(catalog.models.map(\.id))
    return models.filter { allowed.contains($0.id) }
}

func advertisedModels(
    from models: [ModelInfo],
    config: ProviderConfig,
    catalog: CatalogSnapshot?,
    modelOverrides: [String] = [],
    includeDisabled: Bool = false
) -> [ModelInfo] {
    let supported = catalogFilteredModels(models, catalog: catalog)
    if !modelOverrides.isEmpty {
        let byID = Dictionary(uniqueKeysWithValues: supported.map { ($0.id, $0) })
        return modelOverrides.compactMap { byID[$0] }
    }
    guard !includeDisabled, !config.backend.enabledModels.isEmpty else {
        return supported
    }
    let enabled = Set(config.backend.enabledModels)
    return supported.filter { enabled.contains($0.id) }
}

/// Returns the set of model IDs that are allowed by the coordinator catalog,
/// including active catalog models and any previous/retired members of active
/// aliases. Providers offline through an alias rollout may only have those
/// lineage builds locally; keeping them in the allowed set lets the foreground
/// filter preserve stale plist `--model` flags and lets the coordinator push a
/// `desired_models` update after registration.
func catalogAllowedIDs(catalog: CatalogSnapshot?) -> Set<String> {
    guard let catalog else { return [] }
    var ids = Set(catalog.models.map(\.id))
    for alias in catalog.aliases {
        if let previous = alias.previousBuild {
            ids.insert(previous)
        }
        for retired in alias.retiredBuilds ?? [] {
            ids.insert(retired)
        }
    }
    return ids
}

/// Local/direct-mode variant of `advertisedModels` that bypasses the
/// coordinator catalog. Used when `--local` is requested and the catalog is
/// unavailable (offline/airgapped), so the user can still serve downloaded
/// weights. `enabledModels` and explicit `--model` / `--all` flags are still
/// honored.
func localAdvertisedModels(
    from models: [ModelInfo],
    config: ProviderConfig,
    modelOverrides: [String] = [],
    includeDisabled: Bool = false
) -> [ModelInfo] {
    if !modelOverrides.isEmpty {
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        return modelOverrides.compactMap { byID[$0] }
    }
    guard !includeDisabled, !config.backend.enabledModels.isEmpty else {
        return models
    }
    let enabled = Set(config.backend.enabledModels)
    return models.filter { enabled.contains($0.id) }
}

func attachWeightHashes(to models: [ModelInfo]) -> (
    [ModelInfo], hashes: [String: String], fingerprints: [String: String]
) {
    var hashes: [String: String] = [:]
    var fingerprints: [String: String] = [:]
    let withHashes = models.map { model -> ModelInfo in
        var updated = model
        guard let snapshotDir = ModelScanner.resolveLocalPath(modelID: model.id) else {
            return updated
        }
        // Fingerprint BEFORE hashing: if files change in between, the stale
        // fingerprint forces a re-hash at first model load (safe direction).
        // The reverse order could pair a fingerprint of newer bytes with a
        // hash of older ones and silently skip that re-hash.
        let fingerprint = WeightHasher.snapshotFingerprint(snapshotDir: snapshotDir)
        if let hash = WeightHasher.computeHash(snapshotDir: snapshotDir, modelID: model.id) {
            updated.weightHash = hash
            hashes[model.id] = hash
            if let fingerprint {
                fingerprints[model.id] = fingerprint
            }
        }
        return updated
    }
    return (withHashes, hashes, fingerprints)
}

// MARK: - Output Helpers

struct ModelsOutput: Encodable {
    let cacheDirectory: String?
    let filteredByConfig: Bool
    let models: [ModelInfo]
}

struct HashOutput: Encodable {
    let model: String
    let weightHash: String
}

func printModelTable(_ models: [ModelInfo]) {
    let rows = models.map { model in
        [
            model.id,
            model.modelType ?? "-",
            model.quantization ?? "-",
            formatParameters(model.parameters),
            formatBytes(model.sizeBytes),
            String(format: "%.1f GB", model.estimatedMemoryGb),
        ]
    }

    printTable(
        headers: ["ID", "TYPE", "QUANT", "PARAMS", "SIZE", "EST MEM"],
        rows: rows
    )
}

private func printTable(headers: [String], rows: [[String]]) {
    let widths = headers.enumerated().map { index, header in
        rows.reduce(header.count) { max($0, $1[index].count) }
    }

    func line(_ columns: [String]) -> String {
        columns.enumerated().map { index, value in
            value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }

    print(line(headers))
    print(line(widths.map { String(repeating: "-", count: $0) }))
    for row in rows {
        print(line(row))
    }
}

private func formatParameters(_ value: UInt64?) -> String {
    guard let value else { return "-" }
    if value >= 1_000_000_000 {
        return String(format: "%.1fB", Double(value) / 1_000_000_000.0)
    }
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000.0)
    }
    return "\(value)"
}

private func formatBytes(_ bytes: UInt64) -> String {
    let gib = Double(bytes) / 1_073_741_824.0
    if gib >= 1 {
        return String(format: "%.1f GB", gib)
    }
    let mib = Double(bytes) / 1_048_576.0
    return String(format: "%.1f MB", mib)
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
        throw ValidationError("failed to encode JSON output")
    }
    print(string)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func failNotImplemented(_ message: String) throws {
    printError(message)
    throw ExitCode.failure
}
