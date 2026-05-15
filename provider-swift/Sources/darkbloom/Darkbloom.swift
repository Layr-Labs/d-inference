import Foundation
import ArgumentParser
import ProviderCore

@main
struct Darkbloom: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darkbloom",
        abstract: "Swift-native provider CLI for Darkbloom.",
        discussion: "Runs on Apple Silicon Macs. Connects to the coordinator, serves inference requests via mlx-swift.",
        version: ProviderCore.version,
        subcommands: [
            Start.self,
            Stop.self,
            Status.self,
            Doctor.self,
            Models.self,
            Login.self,
            Logout.self,
            Benchmark.self,
            Update.self,
            Verify.self,
            Enroll.self,
            Unenroll.self,
            Logs.self,
            AutoUpdate.self,
        ]
    )

    mutating func run() async throws {
        throw CleanExit.helpRequest(self)
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
    let coordinatorURL: String
    if let snapshot = try? loadRuntimeSnapshot(configOptions: ConfigOptions()) {
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
}

func loadRuntimeSnapshot(configOptions: ConfigOptions) throws -> RuntimeSnapshot {
    let configPath = try resolveConfigPath(configOptions.config)
    let configFileExists = FileManager.default.fileExists(atPath: configPath.path)

    let hardware: HardwareInfo?
    let hardwareError: Error?
    do {
        hardware = try HardwareDetector.detect()
        hardwareError = nil
    } catch {
        hardware = nil
        hardwareError = error
    }

    let config: ProviderConfig
    if configFileExists {
        config = try ConfigManager.load(from: configPath)
    } else if let hardware {
        config = ProviderConfig.defaultForHardware(hardware)
    } else {
        config = ConfigManager.loadDefault()
    }

    let models = hardware.map { ModelScanner.scanModels(hardwareInfo: $0) } ?? []

    return RuntimeSnapshot(
        configPath: configPath,
        configFileExists: configFileExists,
        config: config,
        hardware: hardware,
        hardwareError: hardwareError,
        models: models
    )
}

private func resolveConfigPath(_ rawPath: String?) throws -> URL {
    if let rawPath {
        return URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
    }
    return try ConfigManager.defaultConfigPath()
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

func attachWeightHashes(to models: [ModelInfo]) -> ([ModelInfo], [String: String]) {
    var hashes: [String: String] = [:]
    let withHashes = models.map { model -> ModelInfo in
        var updated = model
        if let hash = WeightHasher.computeHash(for: model.id) {
            updated.weightHash = hash
            hashes[model.id] = hash
        }
        return updated
    }
    return (withHashes, hashes)
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
