import Foundation

/// Bridge from the app to `darkbloom config get|set schedule`: the app's
/// availability READ path decodes the CLI's JSON payload, the WRITE path
/// shells out with policy-derived arguments. The CLI owns the TOML
/// read-modify-write (including its config-path resolution and locking); the
/// app never edits provider.toml itself.
///
/// Wire contract (kept in step with the CLI's `ScheduleAvailabilityOutput`):
/// `darkbloom config get schedule --json` prints
/// `{"enabled": Bool, "windows": [{"days": [...], "start": "HH:MM",
/// "end": "HH:MM"}], "idle_timeout_minutes": n}` — the `[schedule]` section
/// plus the one availability knob outside it, `[backend] idle_timeout_mins`.
struct AvailabilityCLISchedule: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        var days: [String]
        var start: String
        var end: String
    }

    var enabled: Bool
    var windows: [Window]
    /// `[backend] idle_timeout_mins`. Optional on decode for forward-tolerance
    /// when the installed CLI predates the field.
    var idleTimeoutMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case enabled
        case windows
        case idleTimeoutMinutes = "idle_timeout_minutes"
    }
}

protocol AvailabilityCLIRunning: Sendable {
    /// `darkbloom config get schedule --json`, decoded.
    func fetchSchedule() async throws -> AvailabilityCLISchedule
    /// `darkbloom config set schedule ...` with prebuilt arguments; throws on
    /// non-zero exit (stderr tail preserved for user display).
    func apply(arguments: [String]) async throws
}

enum AvailabilityCLIError: Error, Equatable, LocalizedError, Sendable {
    /// No `darkbloom` binary found in any known install location.
    case cliNotFound
    /// The CLI exited non-zero; carries the stderr-derived message.
    case exited(Int32, message: String)
    /// The CLI did not finish within the bounded wait and was terminated.
    case timedOut(command: String)
    /// `get --json` stdout could not be decoded into the schedule payload.
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The Darkbloom provider CLI is not installed, so the saved schedule cannot be read or changed."
        case .exited(let status, let message):
            message.isEmpty ? "The config command failed (exit \(status))." : message
        case .timedOut(let command):
            "The command `darkbloom \(command)` did not finish in time."
        case .invalidOutput(let detail):
            "The provider CLI returned an unreadable schedule (\(detail))."
        }
    }
}

/// Maps an availability policy draft onto `config set schedule` arguments.
/// Pure and file-free so store tests pin the exact grammar.
enum AvailabilityScheduleCLIArguments {
    /// Schedule-shape arguments for the policy's mode + windows (the idle
    /// knob travels separately via `idleUnloadArguments(for:)`).
    static func scheduleArguments(for policy: AvailabilityPolicy) -> [String] {
        switch policy.mode {
        case .wheneverRunning:
            return ["config", "set", "schedule", "always"]
        case .scheduled:
            var arguments = ["config", "set", "schedule"]
            for window in policy.windows {
                let days = window.days
                    .sorted { $0.sortIndex < $1.sortIndex }
                    .map(\.rawValue)
                    .joined(separator: ",")
                arguments.append(days)
                arguments.append("\(window.start.configurationValue)-\(window.end.configurationValue)")
            }
            return arguments
        }
    }

    /// `config set schedule idle-timeout-minutes <n>`.
    static func idleUnloadArguments(for policy: AvailabilityPolicy) -> [String] {
        ["config", "set", "schedule", "idle-timeout-minutes", "\(policy.idleUnloadMinutes)"]
    }
}

private struct AvailabilityCLIResult: Sendable, Equatable {
    var exitStatus: Int32
    var stdout: String
    var stderrTail: String
}

/// Locates and invokes the installed `darkbloom` binary. Self-contained
/// (own micro-runner capturing stdout) rather than reusing
/// `ProcessProviderCLIRunner`, which discards stdout by design for
/// lifecycle actions; kept under ~30 duplication lines per slice guidance.
struct ProcessAvailabilityCLI: AvailabilityCLIRunning {
    private let locator: any DarkbloomCLILocating
    private let timeout: Duration

    init(
        locator: any DarkbloomCLILocating = SystemDarkbloomCLILocator(),
        timeout: Duration = .seconds(30)
    ) {
        self.locator = locator
        self.timeout = timeout
    }

    func fetchSchedule() async throws -> AvailabilityCLISchedule {
        let result = try await invoke(arguments: ["config", "get", "schedule", "--json"])
        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = result.stdout.data(using: .utf8)
        else {
            throw AvailabilityCLIError.invalidOutput("empty stdout")
        }
        do {
            return try JSONDecoder().decode(AvailabilityCLISchedule.self, from: data)
        } catch {
            throw AvailabilityCLIError.invalidOutput("\(error)")
        }
    }

    func apply(arguments: [String]) async throws {
        _ = try await invoke(arguments: arguments)
    }

    private func invoke(arguments: [String]) async throws -> AvailabilityCLIResult {
        guard let executable = locator.locate() else {
            throw AvailabilityCLIError.cliNotFound
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdout = AvailabilityPipeCollector()
        let stderr = AvailabilityPipeCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<AvailabilityCLIResult, any Error>) in
            let timedOut = AvailabilityTimeoutFlag()
            process.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // Drain both pipes post-termination: final bytes race the
                // readability callbacks and would otherwise be lost
                // (empty stdout parse on success, empty stderr message on failure).
                stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                let command = arguments.joined(separator: " ")
                if timedOut.value {
                    continuation.resume(throwing: AvailabilityCLIError.timedOut(command: command))
                    return
                }
                let status = process.terminationStatus
                if status == 0 {
                    continuation.resume(returning: AvailabilityCLIResult(
                        exitStatus: status, stdout: stdout.text, stderrTail: stderr.lastLine))
                } else {
                    continuation.resume(throwing: AvailabilityCLIError.exited(status, message: stderr.lastLine))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                timedOut.set()
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// Bounded stdout/stderr accumulator shared across readability callbacks.
private final class AvailabilityPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Last non-empty line, retained for user-facing failure messages
    /// (mirrors `ProviderCLIResult.failureMessage`).
    var lastLine: String {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last ?? ""
    }
}

private final class AvailabilityTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
