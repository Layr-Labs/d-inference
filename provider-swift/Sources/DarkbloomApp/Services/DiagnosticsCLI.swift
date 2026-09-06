import Foundation

/// Boundary to the provider CLI's `doctor --json` — the app's only read
/// channel for the REAL hardware/diagnostics truth (the app deliberately has
/// no ProviderCore/MLX dependency, so it shells out instead of probing).
///
/// Two pieces:
///  - `DiagnosticsCLIRunning` + `ProcessDiagnosticsCLIRunner`: locate +
///    invoke the CLI with the same idiom as `DarkbloomCLILocator` /
///    `ProviderCLIRunning` (a compact copy is kept here rather than
///    widening those files' APIs — `ProviderCLIRunning` drops stdout, and
///    doctor's whole payload IS stdout).
///  - `DoctorJSONReport`: the decode-side mirror of ProviderCore's
///    `DoctorReport` (schema 1). Field parity is pinned by the CLI's golden
///    test and this target's mapping tests.

// MARK: - Wire mirror (schema 1)

/// Mirrors `Sources/ProviderCore/Diagnostics/DoctorReport.swift`. Status and
/// priority stay raw strings so a NEWER CLI's states decode and map to
/// `.warning` instead of failing the whole report; structural breakage, a
/// forward `schema`, or missing required fields still fail loudly.
struct DoctorJSONReport: Decodable, Sendable, Equatable {
    struct Check: Decodable, Sendable, Equatable {
        let id: String
        let section: String
        let title: String
        let status: String
        let detail: String
        let advice: String?
    }

    struct Fix: Decodable, Sendable, Equatable {
        let id: String
        let check: String
        let title: String
        let detail: String
        let priority: String
    }

    struct Verdict: Decodable, Sendable, Equatable {
        let status: String
        let failures: Int
        let warnings: Int
    }

    let schema: Int
    let version: String
    let checks: [Check]
    let fixes: [Fix]?
    let verdict: Verdict

    static let supportedSchema = 1
}

// MARK: - Errors

enum DiagnosticsCLIError: Error, Equatable, LocalizedError, Sendable {
    /// No `darkbloom` binary found in any known install location.
    case cliNotFound
    /// The installed CLI's argument parser rejected the required JSON mode.
    case incompatibleCLI
    /// macOS could not launch the installed provider; retains technical detail.
    case launchFailed(String)
    /// The CLI exited non-zero without emitting a decodable report; carries
    /// the stderr-derived message.
    case exited(Int32, message: String)
    /// The CLI did not exit within the allotted time and was terminated.
    case timedOut
    /// stdout was not a decodable doctor report (e.g. a CLI that predates
    /// `doctor --json`).
    case undecodable
    /// The report decoded but declares a schema this app predates.
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The Darkbloom provider is not installed. Install the latest Darkbloom app from darkbloom.dev, then run the system check again."
        case .incompatibleCLI:
            "The installed Darkbloom provider does not support this app's system check. Update the provider, then run the check again."
        case .launchFailed:
            "The installed Darkbloom provider could not be opened. Update or reinstall the provider, then run the system check again."
        case .exited:
            "The Darkbloom provider could not complete the system check. Try again; if it still fails, update the provider and retry."
        case .timedOut:
            "The system check did not finish in time. Try running it again."
        case .undecodable:
            "The installed Darkbloom provider did not return a system-check report this app can read. Update the provider, then run the check again."
        case .unsupportedSchema(let schema):
            "The provider's system-check report (schema \(schema)) is newer than this app understands. Update the Darkbloom app, then try again."
        }
    }
}

// MARK: - Runner

protocol DiagnosticsCLIRunning: Sendable {
    /// Runs `darkbloom doctor --json` and returns the decoded report.
    /// Note: doctor exits non-zero when any check FAILS — the report on
    /// stdout is still the truth, and is decoded and returned regardless.
    func runDoctorJSON() async throws -> DoctorJSONReport
}

struct ProcessDiagnosticsCLIRunner: DiagnosticsCLIRunning {
    /// doctor's own network probes time out in well under a minute; anything
    /// past 60 s total means something is wedged, and the UI can retry.
    private static let timeout: Duration = .seconds(60)
    /// The report is ~10 KB; the bound exists so a wedged writer can't grow
    /// memory unboundedly.
    private static let stdoutLimit = 1_048_576
    private static let stderrTailLimit = 4_096

    let locator: any DarkbloomCLILocating

    init(locator: any DarkbloomCLILocating = SystemDarkbloomCLILocator()) {
        self.locator = locator
    }

    func runDoctorJSON() async throws -> DoctorJSONReport {
        guard let executable = locator.locate() else {
            throw DiagnosticsCLIError.cliNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["doctor", "--json"]
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Bounded accumulation via readability handlers: deferring all reads
        // to process exit can deadlock the child on a full pipe.
        let stdoutBox = BoundedOutput(limit: Self.stdoutLimit)
        let stderrBox = BoundedOutput(limit: Self.stderrTailLimit)
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdoutBox.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderrBox.append($0.availableData) }

        let outcome = try await Self.wait(
            for: process,
            timeout: Self.timeout,
            cleanup: {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // A launch failure leaves the parent write ends open; close
                // them before draining so cleanup also reaches EOF in that case.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                // Drain whatever the handler queue hasn't flushed yet — the
                // child's end is closed at exit, so this returns promptly,
                // and the JSON must not be truncated by a racy tail.
                stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            }
        )

        switch outcome {
        case .timedOut:
            throw DiagnosticsCLIError.timedOut
        case .exited(let status):
            return try Self.decodeReport(
                exitStatus: status, stdout: stdoutBox.bytes, stderr: stderrBox.bytes)
        }
    }

    /// A valid report remains authoritative even when checks exit nonzero.
    /// Parser/process failures describe the installed software, not the Mac's
    /// hardware. Inspect the full bounded stderr, not its trailing help line.
    static func decodeReport(
        exitStatus: Int32,
        stdout: Data,
        stderr: Data
    ) throws -> DoctorJSONReport {
        if let report = try? JSONDecoder().decode(DoctorJSONReport.self, from: stdout) {
            guard report.schema == DoctorJSONReport.supportedSchema else {
                throw DiagnosticsCLIError.unsupportedSchema(report.schema)
            }
            return report
        }
        if exitStatus != 0 {
            let stderrText = String(decoding: stderr, as: UTF8.self)
            let output = stderrText + "\n" + String(decoding: stdout, as: UTF8.self)
            let parserErrors = [
                "unknown option", "unrecognized option", "unexpected argument",
                "unknown argument", "unrecognized argument", "unknown flag", "unrecognized flag",
            ]
            let rejectsJSON = output.lowercased().split(separator: "\n").contains { line in
                line.contains("--json") && parserErrors.contains { line.contains($0) }
            }
            if rejectsJSON { throw DiagnosticsCLIError.incompatibleCLI }
            throw DiagnosticsCLIError.exited(exitStatus, message: stderrText)
        }
        throw DiagnosticsCLIError.undecodable
    }

    /// Run the child to termination, timeout, or cancellation — exactly one
    /// outcome. On timeout/cancel the child is terminated rather than left
    /// running headless.
    private static func wait(
        for process: Process,
        timeout: Duration,
        cleanup: @escaping @Sendable () -> Void
    ) async throws -> ProcessOutcome {
        let guardBox = OutcomeGuard()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutcome, any Error>) in
                process.terminationHandler = { process in
                    cleanup()
                    let status = process.terminationStatus
                    let timedOut = guardBox.timedOut
                    let cancelled = guardBox.cancelled
                    guardBox.resume {
                        if timedOut {
                            continuation.resume(returning: .timedOut)
                        } else if cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: .exited(status: status))
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    cleanup()
                    guardBox.resume {
                        continuation.resume(throwing: DiagnosticsCLIError.launchFailed(error.localizedDescription))
                    }
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
}

private enum ProcessOutcome {
    case exited(status: Int32)
    case timedOut
}

/// Exactly-once resume across child exit, launch failure, timeout, and
/// cancel (compact copy of `ProviderCLIRunning`'s guard pattern).
private final class OutcomeGuard: @unchecked Sendable {
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
        get { lock.withLock { flagsStorage.cancelled} }
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

/// Bounded byte accumulator shared across readability callbacks (same shape
/// as `ProviderCLIRunning`'s stderr collector, kept private here too).
private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit {
            data = data.suffix(limit)
        }
    }

    var bytes: Data {
        lock.withLock { data }
    }
}
