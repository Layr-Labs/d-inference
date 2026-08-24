import Foundation
import ProviderCoreFoundation

/// App-side adapter for model catalog + downloads. The app never links
/// ProviderCore and never reimplements downloader logic: it shells out to
/// the `darkbloom` CLI — `models catalog --json` (coordinator catalog),
/// `models list --json` (local cache scan), `models download --json`
/// (NDJSON progress stream), `models remove --force` — and merges the
/// results with the daemon's `daemon-state.json` (warm/serving models).
///
/// Everything behind `ModelCatalogCLIRunning` so store tests substitute a
/// scripted stub — never a real subprocess.

// MARK: - Wire mirrors (decodable twins of ProviderCore's JSON output)

/// Mirror of `ProviderCore.CatalogModel` as emitted by
/// `darkbloom models catalog --json` (snake_case keys).
struct CLICatalogModel: Decodable, Equatable, Sendable {
    let id: String
    let s3Name: String
    let displayName: String
    let modelType: String
    let sizeGb: Double
    let description: String?
    let minRamGb: Int?
    let family: String?
    let quantization: String?
    let maxContextLength: Int?
    let capabilities: [String]?
    let totalSizeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case s3Name = "s3_name"
        case displayName = "display_name"
        case modelType = "model_type"
        case sizeGb = "size_gb"
        case description
        case minRamGb = "min_ram_gb"
        case family
        case quantization
        case maxContextLength = "max_context_length"
        case capabilities
        case totalSizeBytes = "total_size_bytes"
    }
}

/// Mirror of `ProviderCore.ModelInfo` as emitted inside
/// `darkbloom models list --json` (snake_case keys).
struct CLILocalModelEntry: Decodable, Equatable, Sendable {
    let id: String
    let modelType: String?
    let quantization: String?
    let sizeBytes: UInt64
    let estimatedMemoryGb: Double

    enum CodingKeys: String, CodingKey {
        case id
        case modelType = "model_type"
        case quantization
        case sizeBytes = "size_bytes"
        case estimatedMemoryGb = "estimated_memory_gb"
    }
}

/// Mirror of the CLI's `ModelsOutput` wrapper (camelCase keys: the CLI
/// declares no custom CodingKeys there).
struct CLIModelListOutput: Decodable, Equatable, Sendable {
    let cacheDirectory: String?
    let filteredByConfig: Bool
    let models: [CLILocalModelEntry]
}

/// Mirror of `ProviderCore.ModelDownloadStoragePlan` from
/// `models catalog --json --include-download-plans`.
struct CLIModelDownloadStoragePlan: Decodable, Equatable, Sendable {
    let remainingBytes: Int64
    let reserveBytes: Int64
    let requiredAvailableBytes: Int64
    let availableBytes: Int64?
    let hasSufficientCapacity: Bool

    enum CodingKeys: String, CodingKey {
        case remainingBytes = "remaining_bytes"
        case reserveBytes = "reserve_bytes"
        case requiredAvailableBytes = "required_available_bytes"
        case availableBytes = "available_bytes"
        case hasSufficientCapacity = "has_sufficient_capacity"
    }
}

private struct CLICatalogPlanOutput: Decodable {
    let models: [CLICatalogModel]
    let downloadPlans: [String: CLIModelDownloadStoragePlan]

    enum CodingKeys: String, CodingKey {
        case models
        case downloadPlans = "download_plans"
    }
}

/// Everything the library surface needs, sourced from one refresh pass:
/// coordinator catalog + local scan + daemon warmth + this Mac's memory.
struct ModelLibrarySnapshot: Equatable, Sendable {
    let catalog: [CLICatalogModel]
    let local: [CLILocalModelEntry]
    let downloadPlans: [String: CLIModelDownloadStoragePlan]
    let warmModelIDs: Set<String>
    let servingModelID: String?
    let physicalMemoryGB: Int?
    let fetchedAt: Date

    init(
        catalog: [CLICatalogModel],
        local: [CLILocalModelEntry],
        downloadPlans: [String: CLIModelDownloadStoragePlan] = [:],
        warmModelIDs: Set<String>,
        servingModelID: String?,
        physicalMemoryGB: Int?,
        fetchedAt: Date
    ) {
        self.catalog = catalog
        self.local = local
        self.downloadPlans = downloadPlans
        self.warmModelIDs = warmModelIDs
        self.servingModelID = servingModelID
        self.physicalMemoryGB = physicalMemoryGB
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Download events

/// App-facing download event, parsed from the CLI's
/// `darkbloom models download --json` NDJSON stream.
enum ModelDownloadStreamEvent: Equatable, Sendable {
    /// Cumulative bytes on disk for one file (a resumed `.part` prefix is
    /// included, so values never restart at zero for a resumed download).
    /// `total` is nil when the size is unknown (legacy CDN path).
    case progress(file: String, bytes: Int64, total: Int64?)
    case verifying
    case done
    /// The CLI's terminal `{"event":"error",…}` line. The stream also ends
    /// non-zero, so this arrives at most once and always as the last event.
    case error(String)
}

// MARK: - NDJSON parsing

enum ModelDownloadNDJSON {
    private struct EventLine: Decodable {
        let event: String
        let file: String?
        let bytes: Int64?
        let total: Int64?
        let message: String?
    }

    /// Parse one stdout line. Returns nil for blank, malformed, or
    /// unknown-event lines: the stream tolerates noise (stderr bleed on a
    /// shared fd, forward-compatible future events) instead of dying.
    static func parse(_ line: String) -> ModelDownloadStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(EventLine.self, from: data)
        else { return nil }

        switch decoded.event {
        case "progress":
            guard let file = decoded.file, let bytes = decoded.bytes else { return nil }
            return .progress(file: file, bytes: bytes, total: decoded.total)
        case "verifying":
            return .verifying
        case "done":
            return .done
        case "error":
            return .error(decoded.message ?? "The download failed.")
        default:
            return nil
        }
    }
}

// MARK: - Errors

enum ModelCatalogCLIError: Error, Equatable, LocalizedError, Sendable {
    /// No `darkbloom` binary found in any known install location.
    case cliNotFound
    /// The CLI exited non-zero; carries the stderr-derived message.
    case exited(Int32, message: String)
    /// A short command did not exit within its allotted time.
    case timedOut(command: String)
    /// The CLI exited zero but stdout did not decode as the expected schema.
    case unreadableOutput(command: String)
    /// The CLI emitted a terminal `{"event":"error"}` download line.
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The Darkbloom provider CLI is not installed. Install it from darkbloom.dev, then try again."
        case .exited(let status, let message):
            message.isEmpty ? "The provider command failed (exit \(status))." : message
        case .timedOut(let command):
            "The provider command `darkbloom \(command)` did not finish in time."
        case .unreadableOutput(let command):
            "Could not read `darkbloom \(command)` output."
        case .downloadFailed(let message):
            message
        }
    }
}

// MARK: - Protocol

protocol ModelCatalogCLIRunning: Sendable {
    /// Catalog + local scan + daemon warmth, bundled for one store refresh.
    func fetchSnapshot() async throws -> ModelLibrarySnapshot

    /// Live NDJSON event stream for one download. Cancelling the consuming
    /// task terminates the child process; the CLI's staged `.part` bytes
    /// stay on disk so a later call resumes the same download.
    func downloadEvents(modelID: String) -> AsyncThrowingStream<ModelDownloadStreamEvent, Error>

    /// `darkbloom models remove <id> --force` (non-interactive; plain
    /// `remove` prompts on stdin, which the app can never answer).
    func removeModel(modelID: String) async throws
}

// MARK: - Subprocess implementation

struct ProcessModelCatalogCLIRunner: ModelCatalogCLIRunning {
    private let locator: any DarkbloomCLILocating
    private let stateFileURL: URL
    private let physicalMemoryBytes: UInt64
    private let now: @Sendable () -> Date
    private let processIdentityReader: @Sendable (Int32) -> ProcessIdentity?

    init(
        locator: any DarkbloomCLILocating = SystemDarkbloomCLILocator(),
        stateFileURL: URL = DaemonStateFile.path(),
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        now: @escaping @Sendable () -> Date = Date.init,
        processIdentityReader: @escaping @Sendable (Int32) -> ProcessIdentity? =
            ProcessIdentity.read
    ) {
        self.locator = locator
        self.stateFileURL = stateFileURL
        self.physicalMemoryBytes = physicalMemoryBytes
        self.now = now
        self.processIdentityReader = processIdentityReader
    }

    func fetchSnapshot() async throws -> ModelLibrarySnapshot {
        let executable = try requireCLI()

        let catalogOutput = try await runShortCommand(
            executable: executable,
            arguments: ["models", "catalog", "--json", "--include-download-plans"],
            timeout: .seconds(45)
        )
        guard catalogOutput.status == 0 else {
            throw ModelCatalogCLIError.exited(catalogOutput.status, message: catalogOutput.stderrTail)
        }
        let catalogPlan: CLICatalogPlanOutput
        do {
            catalogPlan = try JSONDecoder().decode(
                CLICatalogPlanOutput.self,
                from: catalogOutput.stdout
            )
        } catch {
            throw ModelCatalogCLIError.unreadableOutput(
                command: "models catalog --json --include-download-plans"
            )
        }

        let listOutput = try await runShortCommand(
            executable: executable,
            arguments: ["models", "list", "--json"],
            timeout: .seconds(30)
        )
        guard listOutput.status == 0 else {
            throw ModelCatalogCLIError.exited(listOutput.status, message: listOutput.stderrTail)
        }
        let local: [CLILocalModelEntry]
        do {
            local = try JSONDecoder().decode(CLIModelListOutput.self, from: listOutput.stdout).models
        } catch {
            throw ModelCatalogCLIError.unreadableOutput(command: "models list --json")
        }

        let daemonState = DaemonStateFile.read(from: stateFileURL)
        let stateIsFreshAndLive = daemonState.map {
            DaemonStateRuntimeTruth.isFreshAndLive(
                $0,
                now: now().timeIntervalSince1970,
                readIdentity: processIdentityReader
            )
        } ?? false
        let serving = stateIsFreshAndLive && daemonState?.inferenceActive == true
            ? daemonState?.currentModel
            : nil
        return ModelLibrarySnapshot(
            catalog: catalogPlan.models,
            local: local,
            downloadPlans: catalogPlan.downloadPlans,
            warmModelIDs: stateIsFreshAndLive
                ? Set(daemonState?.warmModels ?? [])
                : [],
            servingModelID: serving,
            physicalMemoryGB: physicalMemoryBytes > 0
                ? Int(physicalMemoryBytes / 1_073_741_824)
                : nil,
            fetchedAt: Date()
        )
    }

    func downloadEvents(modelID: String) -> AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let executable = locator.locate() else {
                continuation.finish(throwing: ModelCatalogCLIError.cliNotFound)
                return
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = ["models", "download", modelID, "--json"]
            process.environment = Self.childEnvironment()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            let stderr = ShortCommandOutputCollector(limit: 4_096)
            stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

            let pump = Task {
                do {
                    try process.run()
                } catch {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.finish(throwing: error)
                    return
                }

                // Parse NDJSON lines as they arrive. The pipe EOFs when the
                // child exits; `onTermination` → terminate() forces that EOF
                // on cancel, so this loop always ends.
                do {
                    for try await rawLine in stdoutPipe.fileHandleForReading.bytes.lines {
                        if Task.isCancelled { break }
                        // Malformed / unknown lines are skipped, never fatal.
                        guard let event = ModelDownloadNDJSON.parse(rawLine) else { continue }
                        if case .error(let message) = event {
                            stderrPipe.fileHandleForReading.readabilityHandler = nil
                            if process.isRunning { process.terminate() }
                            continuation.finish(throwing: ModelCatalogCLIError.downloadFailed(message))
                            return
                        }
                        continuation.yield(event)
                    }
                } catch {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    if process.isRunning { process.terminate() }
                    continuation.finish(throwing: error)
                    return
                }

                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }

                // The pipe is at EOF so the exit is imminent; reap the status.
                while process.isRunning {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                let status = process.terminationStatus
                if status == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(
                        throwing: ModelCatalogCLIError.exited(status, message: stderr.lastLine))
                }
            }

            continuation.onTermination = { _ in
                pump.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    func removeModel(modelID: String) async throws {
        let executable = try requireCLI()
        let output = try await runShortCommand(
            executable: executable,
            arguments: ["models", "remove", modelID, "--force"],
            timeout: .seconds(60)
        )
        guard output.status == 0 else {
            throw ModelCatalogCLIError.exited(output.status, message: output.stderrTail)
        }
    }

    // MARK: - Short commands

    private struct ShortCommandOutput {
        let stdout: Data
        let status: Int32
        let stderrTail: String
    }

    private func requireCLI() throws -> URL {
        guard let executable = locator.locate() else {
            throw ModelCatalogCLIError.cliNotFound
        }
        return executable
    }

    /// Run a one-shot CLI invocation to completion, capturing stdout
    /// (bounded) and a stderr tail. Mirrors the `ProviderCLIRunning` idiom —
    /// exactly-once resume, cancel/timeout → terminate — but keeps stdout
    /// where that runner discards it. Duplicated rather than shared because
    /// the two capture contracts diverge (ProviderCLIRunning keeps only a
    /// stderr tail for lifecycle actions).
    private func runShortCommand(
        executable: URL,
        arguments: [String],
        timeout: Duration
    ) async throws -> ShortCommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.childEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdout = ShortCommandOutputCollector(limit: 64 << 20)
        let stderr = ShortCommandOutputCollector(limit: 4_096)
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        let guardBox = ShortCommandResumeGuard()
        let command = arguments.joined(separator: " ")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShortCommandOutput, any Error>) in
                process.terminationHandler = { process in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    // Drain whatever the pipes still hold; the child is dead
                    // so these return at EOF instead of blocking. stderr
                    // needs the same treatment: its final bytes race the
                    // readability callback and failure messages otherwise
                    // intermittently come back empty.
                    stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    let status = process.terminationStatus
                    let cancelled = guardBox.cancelled
                    let timedOut = guardBox.timedOut
                    guardBox.resume {
                        if timedOut {
                            continuation.resume(throwing: ModelCatalogCLIError.timedOut(command: command))
                        } else if cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: ShortCommandOutput(
                                stdout: stdout.data,
                                status: status,
                                stderrTail: stderr.lastLine
                            ))
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    guardBox.resume { continuation.resume(throwing: error) }
                    return
                }

                guardBox.watchdog = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    guardBox.timedOut = true
                    if process.isRunning { process.terminate() }
                }
                // Close the race where a fast-exiting child resumed before
                // the watchdog was stored (its cancel arrived at nil).
                if guardBox.isResumed {
                    guardBox.watchdog?.cancel()
                }
            }
        } onCancel: {
            guardBox.cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    /// Skip the best-effort update banner so JSON-mode invocations stay
    /// deterministic (the banner writes to stderr, but skipping the network
    /// check also keeps `list`/`catalog` latency honest).
    private static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DARKBLOOM_NO_UPDATE_CHECK"] = "1"
        return environment
    }
}

/// Bounded stdout/stderr accumulator shared across readability callbacks.
private final class ShortCommandOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        storage.append(chunk)
        if storage.count > limit {
            storage = storage.suffix(limit)
        }
    }

    var data: Data {
        lock.withLock { storage }
    }

    /// Last non-empty line, retained for user-facing failure messages.
    var lastLine: String {
        lock.withLock {
            String(decoding: storage, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty }) ?? ""
        }
    }
}

/// Exactly-once resume across child exit, launch failure, timeout, and
/// cancel. Twin of the guard inside `ProviderCLIRunning.swift`.
private final class ShortCommandResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var flagsStorage = Flags()

    private struct Flags {
        var timedOut = false
        var cancelled = false
    }

    var timedOut: Bool {
        get { lock.withLock { flagsStorage.timedOut } }
        set { lock.withLock { flagsStorage.timedOut = newValue } }
    }

    var cancelled: Bool {
        get { lock.withLock { flagsStorage.cancelled } }
        set { lock.withLock { flagsStorage.cancelled = newValue } }
    }

    var watchdog: Task<Void, Never>?

    var isResumed: Bool {
        lock.withLock { resumed }
    }

    func resume(_ body: () -> Void) {
        lock.lock()
        let already = resumed
        resumed = true
        let watchdog = self.watchdog
        lock.unlock()
        guard !already else { return }
        watchdog?.cancel()
        body()
    }
}
