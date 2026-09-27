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
            Switch.self,
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
            Idle.self,
            Fan.self,
            Watchdog.self,
            RuntimeSmoke.self,
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
    if let snapshot = try? loadRuntimeSnapshot(configPath: nil) {
        coordinatorURL = snapshot.config.coordinator.url
    } else {
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
    let models: [ModelInfo]
    var configuredModelCacheDirectory: String? = nil
}

func loadRuntimeSnapshot(configOptions: ConfigOptions) throws -> RuntimeSnapshot {
    Darkbloom.ensureLogging()
    let snapshot = try loadRuntimeSnapshot(configPath: configOptions.config)
    ModelScanner.configureCacheDirectory(snapshot.configuredModelCacheDirectory)
    return snapshot
}

func loadRuntimeSnapshot(configPath rawPath: String?) throws -> RuntimeSnapshot {
    let loaded = try loadRuntimeConfiguration(configPath: rawPath)
    let configuredDirectory = try ConfigManager.modelCacheDirectory(
        in: loaded.config, relativeTo: loaded.configPath)
    let cacheDirectory = ModelScanner.resolveCache(configuredDirectory: configuredDirectory).url
    let models = loaded.hardware.map {
        ModelScanner.scanModels(in: cacheDirectory, availableMemoryGB: $0.memoryAvailableGb)
    } ?? []
    return RuntimeSnapshot(
        configPath: loaded.configPath,
        configFileExists: loaded.configFileExists,
        config: loaded.config,
        hardware: loaded.hardware,
        hardwareError: loaded.hardwareError,
        models: models,
        configuredModelCacheDirectory: configuredDirectory)
}


func describeConfigPath(_ snapshot: RuntimeSnapshot) -> String {
    if snapshot.configFileExists {
        return snapshot.configPath.path
    }
    return "\(snapshot.configPath.path) (missing, using defaults)"
}

func advertisedModels(
    from models: [ModelInfo],
    config: ProviderConfig,
    modelOverrides: [String] = [],
    includeDisabled: Bool = false,
    runtimeCapabilities: Set<ProviderRuntimeCapability>? = nil
) -> [ModelInfo] {
    let selected: [ModelInfo]
    if !modelOverrides.isEmpty {
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        selected = modelOverrides.compactMap { byID[$0] }
    } else if includeDisabled || config.backend.enabledModels.isEmpty {
        selected = models
    } else {
        let enabled = Set(config.backend.enabledModels)
        selected = models.filter { enabled.contains($0.id) }
    }
    guard let runtimeCapabilities else { return selected }
    return selected.filter {
        ModelRuntimeRequirements.isEligible(
            modelID: $0.id, available: runtimeCapabilities)
    }
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
