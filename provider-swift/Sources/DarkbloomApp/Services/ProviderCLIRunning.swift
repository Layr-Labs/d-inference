import Foundation

struct ProviderCLIResult: Sendable, Equatable {
    var exitStatus: Int32

    init(exitStatus: Int32, stderrTail: String) {
        self.exitStatus = exitStatus
        failureMessage = stderrTail
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last ?? ""
    }

    /// Last non-empty stderr line, retained for user-facing failure messages.
    var failureMessage: String
}

enum ProviderCLIError: Error, Equatable, LocalizedError, Sendable {
    /// No `darkbloom` binary found in any known install location.
    case cliNotFound
    /// The CLI exited non-zero; carries the stderr-derived message.
    case exited(Int32, message: String)
    /// The CLI did not exit within the allotted time and was terminated.
    case timedOut(command: String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The Darkbloom provider CLI is not installed. Install it from darkbloom.dev, then try again."
        case .exited(let status, let message):
            message.isEmpty
                ? "The provider command failed (exit \(status))."
                : message
        case .timedOut(let command):
            "The provider command `darkbloom \(command)` did not finish in time."
        }
    }
}

/// Invokes the `darkbloom` CLI on behalf of the app. Behind a protocol so
/// service tests substitute recording stubs — never a real subprocess.
protocol ProviderCLIRunning: Sendable {
    func run(arguments: [String], timeout: Duration) async throws -> ProviderCLIResult
}

/// Runs the CLI via `Process`, capturing stderr (bounded) and enforcing a
/// timeout. Task cancellation and timeout both terminate the child: a
/// dismissed confirmation must not leave a half-applied launchd state behind.
struct ProcessProviderCLIRunner: ProviderCLIRunning {
    private static let stderrTailLimit = 4_096

    let locator: any DarkbloomCLILocating

    init(locator: any DarkbloomCLILocating = SystemDarkbloomCLILocator()) {
        self.locator = locator
    }

    func run(arguments: [String], timeout: Duration) async throws -> ProviderCLIResult {
        guard let executable = locator.locate() else {
            throw ProviderCLIError.cliNotFound
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        // Empty stdin: `start --all` never prompts, but if a future flag does,
        // EOF is a deterministic cancel instead of a wedged readLine().
        process.standardInput = FileHandle.nullDevice

        let stderr = StderrCollector(limit: Self.stderrTailLimit)
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderr.append(handle.availableData)
        }

        let command = arguments.joined(separator: " ")
        let guardBox = ResumeGuard()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProviderCLIResult, any Error>) in
                process.terminationHandler = { process in
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    let status = process.terminationStatus
                    let cancelled = guardBox.cancelled
                    let timedOut = guardBox.timedOut
                    guardBox.resume {
                        if timedOut {
                            continuation.resume(throwing: ProviderCLIError.timedOut(command: command))
                        } else if cancelled {
                            continuation.resume(throwing: CancellationError())
                        } else if status == 0 {
                            continuation.resume(returning: ProviderCLIResult(exitStatus: status, stderrTail: stderr.text))
                        } else {
                            continuation.resume(throwing: ProviderCLIError.exited(status, message: ProviderCLIResult(exitStatus: status, stderrTail: stderr.text).failureMessage))
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
                // Close the race where a fast-exiting child resumed before the
                // watchdog was stored (its cancel arrived at nil).
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

/// Exactly-once resume across child exit, launch failure, timeout, and cancel.
private final class ResumeGuard: @unchecked Sendable {
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

/// Bounded stderr accumulator shared across readability callbacks.
private final class StderrCollector: @unchecked Sendable {
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

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
