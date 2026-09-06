import Foundation
import ProviderCoreFoundation

/// App-side adapter for model catalog + downloads. The app never links
/// ProviderCore and never reimplements downloader logic: it shells out to
/// the `darkbloom` CLI — `models catalog --json --include-runtime-eligibility`
/// (coordinator catalog plus runtime eligibility; onboarding explicitly opts
/// into `--include-download-plans` for storage-aware model selection),
/// `models list --json` (local cache scan), `models download --json`
/// (NDJSON progress stream), `models remove --force` — and merges the
/// results with the daemon's `daemon-state.json` (warm/serving models).
///
/// Everything behind `ModelCatalogCLIRunning` so store tests substitute a
/// scripted stub — never a real subprocess.

// MARK: - Errors

enum ModelCatalogCLIError: Error, Equatable, LocalizedError, Sendable {
    /// No `darkbloom` binary found in any known install location.
    case cliNotFound
    /// The located CLI could not be launched.
    case launchFailed(command: String, message: String)
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
        case .launchFailed(let command, let message):
            "Could not start `darkbloom \(command)`: \(message)"
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

    /// Obtain a fresh downloader-backed storage plan and reserve app capacity.
    /// The returned one-shot preparation creates the reserve-constrained child
    /// only when its synchronous `start()` method is called.
    func prepareDownload(modelID: String) async throws -> PreparedModelDownload

    /// `darkbloom models remove <id> --force` (non-interactive; plain
    /// `remove` prompts on stdin, which the app can never answer).
    func removeModel(modelID: String) async throws
}

// MARK: - Subprocess implementation

struct ProcessModelCatalogCLIRunner: ModelCatalogCLIRunning {
    private let includeDownloadPlans: Bool
    private let locator: any DarkbloomCLILocating
    private let stateFileURL: URL
    private let physicalMemoryBytes: UInt64
    private let now: @Sendable () -> Date
    private let processIdentityReader: @Sendable (Int32) -> ProcessIdentity?
    private let downloadAdmission: AppModelDownloadAdmissionController

    init(
        includeDownloadPlans: Bool = false,
        locator: any DarkbloomCLILocating = SystemDarkbloomCLILocator(),
        stateFileURL: URL = DaemonStateFile.path(),
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        now: @escaping @Sendable () -> Date = Date.init,
        processIdentityReader: @escaping @Sendable (Int32) -> ProcessIdentity? =
            ProcessIdentity.read,
        downloadAdmission: AppModelDownloadAdmissionController = .shared
    ) {
        self.includeDownloadPlans = includeDownloadPlans
        self.locator = locator
        self.stateFileURL = stateFileURL
        self.physicalMemoryBytes = physicalMemoryBytes
        self.now = now
        self.processIdentityReader = processIdentityReader
        self.downloadAdmission = downloadAdmission
    }

    func fetchSnapshot() async throws -> ModelLibrarySnapshot {
        try Task.checkCancellation()
        let executable = try requireCLI()

        // Inventory is required, independent of registry availability. Never
        // disguise a failed scan as an empty (and apparently fresh) inventory.
        let listOutput = try await runShortCommand(
            executable: executable,
            arguments: ["models", "list", "--json", "--all"],
            timeout: .seconds(30)
        )
        guard listOutput.status == 0 else {
            throw ModelCatalogCLIError.exited(listOutput.status, message: listOutput.stderrTail)
        }
        let local: [CLILocalModelEntry]
        do {
            local = try JSONDecoder().decode(CLIModelListOutput.self, from: listOutput.stdout).models
        } catch {
            throw ModelCatalogCLIError.unreadableOutput(command: "models list --json --all")
        }

        let catalogArguments = [
            "models", "catalog", "--json",
            includeDownloadPlans ? "--include-download-plans" : "--include-runtime-eligibility",
        ]
        var catalogPlan: CLICatalogPlanOutput?
        var catalogError: ModelCatalogCLIError?
        do {
            let catalogOutput = try await runShortCommand(
                executable: executable,
                arguments: catalogArguments,
                // Library browsing skips weight hashing. Onboarding's explicit
                // storage plans retain the allowance for large staged shards.
                timeout: .seconds(includeDownloadPlans ? 600 : 60)
            )
            guard catalogOutput.status == 0 else {
                throw ModelCatalogCLIError.exited(catalogOutput.status, message: catalogOutput.stderrTail)
            }
            do {
                catalogPlan = try JSONDecoder().decode(CLICatalogPlanOutput.self, from: catalogOutput.stdout)
            } catch {
                throw ModelCatalogCLIError.unreadableOutput(
                    command: catalogArguments.joined(separator: " ")
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ModelCatalogCLIError {
            catalogError = error
        }
        try Task.checkCancellation()

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
            catalog: catalogPlan?.models ?? [],
            catalogError: catalogError,
            local: local,
            downloadPlans: catalogPlan?.downloadPlans ?? [:],
            runtimeEligibility: catalogPlan?.runtimeEligibility ?? [:],
            warmModelIDs: stateIsFreshAndLive
                ? Set(daemonState?.warmModels ?? [])
                : [],
            servingModelID: serving,
            physicalMemoryGB: physicalMemoryBytes > 0
                ? Int(physicalMemoryBytes / 1_073_741_824)
                : nil,
            fetchedAt: now()
        )
    }

    func prepareDownload(modelID: String) async throws -> PreparedModelDownload {
        let executable = try requireCLI()
        let output = try await runShortCommand(
            executable: executable,
            arguments: [
                "models",
                "download-plan",
                modelID,
                "--json",
                "--reserve-bytes",
                String(ModelDownloadStorageContract.appReserveBytes),
            ],
            timeout: .seconds(600)
        )
        guard output.status == 0 else {
            throw ModelCatalogCLIError.exited(output.status, message: output.stderrTail)
        }

        let decoded: CLIModelDownloadPlanOutput
        do {
            decoded = try JSONDecoder().decode(
                CLIModelDownloadPlanOutput.self,
                from: output.stdout
            )
        } catch {
            throw ModelCatalogCLIError.unreadableOutput(
                command: "models download-plan \(modelID) --json"
            )
        }
        guard decoded.modelID == modelID else {
            throw ModelDownloadAdmissionError.malformedPlan(
                modelID: modelID,
                reason: "the plan belongs to a different model"
            )
        }

        let admission = try await downloadAdmission.admit(
            modelID: modelID,
            plan: decoded.downloadPlan
        )
        let admissionController = downloadAdmission
        do {
            try Task.checkCancellation()
            return PreparedModelDownload(
                modelID: modelID,
                plan: admission.plan,
                start: {
                    self.makeDownloadStream(
                        executable: executable,
                        modelID: modelID,
                        admission: admission
                    )
                },
                cancel: {
                    Task {
                        await admissionController.release(admission)
                    }
                }
            )
        } catch {
            await admissionController.release(admission)
            throw error
        }
    }

    private func makeDownloadStream(
        executable: URL,
        modelID: String,
        admission: AppModelDownloadAdmissionController.Admission
    ) -> AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
        let admissionController = downloadAdmission
        let stream = AsyncThrowingStream<ModelDownloadStreamEvent, Error> {
            (continuation: AsyncThrowingStream<
                ModelDownloadStreamEvent,
                Error
            >.Continuation) in
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "models",
                "download",
                modelID,
                "--json",
                "--reserve-bytes",
                String(admission.plan.reserveBytes),
            ]
            process.environment = Self.childEnvironment()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice

            let stderr = ShortCommandOutputCollector(limit: 4_096)
            stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

            let pump = Task {
                defer {
                    Task {
                        await admissionController.release(admission)
                    }
                }
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
                Task {
                    await admissionController.release(admission)
                }
            }
        }
        return stream
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
        try Task.checkCancellation()
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

        let output = try await withTaskCancellationHandler {
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
                        if cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else if timedOut {
                            continuation.resume(throwing: ModelCatalogCLIError.timedOut(command: command))
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
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    guardBox.resume {
                        if guardBox.cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: ModelCatalogCLIError.launchFailed(
                                command: command, message: error.localizedDescription
                            ))
                        }
                    }
                    return
                }
                // Cancellation can arrive before process.run() starts the child.
                if guardBox.cancelled, process.isRunning { process.terminate() }

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
        try Task.checkCancellation()
        return output
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
