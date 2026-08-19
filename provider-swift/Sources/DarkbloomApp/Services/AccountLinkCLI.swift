import Foundation

/// One event from the `darkbloom login --json` NDJSON stream.
///
/// Wire schema (one JSON object per stdout line, exactly these keys):
///   {"event":"code","user_code":"…","verification_uri":"…","expires_in":900}
///   {"event":"linked"}
///   {"event":"error","message":"…"}
///
/// This mirrors the CLI's `DeviceLoginEvent` one case per kind; the encoder
/// lives in `Sources/darkbloom/LoginCommand.swift` (`LoginEventNDJSON`).
/// Keep both sides in sync when changing the shape.
enum AccountLinkEvent: Equatable, Sendable {
    case code(userCode: String, verificationURI: String, expiresIn: Int)
    case linked
    case error(message: String)

    /// Whether this event ends one link attempt's stream.
    var isTerminal: Bool {
        switch self {
        case .code: return false
        case .linked, .error: return true
        }
    }
}

/// A stream line was not one of the three known events. Surfaces as an
/// `.unreachable`-class failure in onboarding: the installed CLI predates
/// `--json` or writes something we don't understand — retrying after an
/// update is the recovery.
struct AccountLinkEventDecodeError: Error, Equatable, LocalizedError {
    let line: String

    var errorDescription: String? {
        "Unrecognized output from `darkbloom login --json`: \(line)"
    }
}

/// Pure line → event decoding, tested directly. JSONSerialization (not
/// Codable) so a numeric `expires_in` of any JSON integer width decodes.
enum AccountLinkEventDecoding {
    static func decode(line rawLine: String) throws -> AccountLinkEvent {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let kind = fields["event"] as? String
        else {
            throw AccountLinkEventDecodeError(line: rawLine)
        }
        switch kind {
        case "code":
            guard let userCode = fields["user_code"] as? String, !userCode.isEmpty,
                  let verificationURI = fields["verification_uri"] as? String, !verificationURI.isEmpty,
                  let expiresIn = (fields["expires_in"] as? NSNumber)?.intValue
            else {
                throw AccountLinkEventDecodeError(line: rawLine)
            }
            return .code(userCode: userCode, verificationURI: verificationURI, expiresIn: expiresIn)
        case "linked":
            return .linked
        case "error":
            guard let message = fields["message"] as? String, !message.isEmpty else {
                throw AccountLinkEventDecodeError(line: rawLine)
            }
            return .error(message: message)
        default:
            throw AccountLinkEventDecodeError(line: rawLine)
        }
    }
}

/// Streams one live account-link attempt. Behind a protocol so flow-model
/// tests substitute scripted streams — never a real subprocess.
///
/// The stream yields every event the CLI emits and then finishes. Exactly one
/// terminal event (`.linked` or `.error`) ends a healthy stream; a stream
/// that ends WITHOUT a terminal event (or fails to start, exits non-zero, or
/// emits garbage) throws instead. Cancelling iteration terminates the child
/// process: a dismissed onboarding step must not leave a polling `login`
/// behind.
protocol AccountLinkRunning: Sendable {
    func linkEvents() -> AsyncThrowingStream<AccountLinkEvent, Error>
}

/// Runs `darkbloom login --json` as a child process, pumping its stdout
/// NDJSON into an `AsyncThrowingStream` line by line.
///
/// Locator/runner idiom mirrors `DaemonRuntimeService` + `ProviderCLIRunning`
/// (bounded stderr tail for the failure message, `Process` +
/// readabilityHandler, termination via continuation `onTermination`). The
/// small `StderrTail` duplication is deliberate: the slice boundary says not
/// to refactor the shared runner for a divergent (streaming, line-oriented)
/// use case.
struct ProcessAccountLinkCLI: AccountLinkRunning {
    private static let stderrTailLimit = 4_096

    let locator: any DarkbloomCLILocating

    init(locator: any DarkbloomCLILocating = SystemDarkbloomCLILocator()) {
        self.locator = locator
    }

    func linkEvents() -> AsyncThrowingStream<AccountLinkEvent, Error> {
        guard let executable = locator.locate() else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ProviderCLIError.cliNotFound)
            }
        }

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["login", "--json"]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            // EOF on stdin: the login flow never prompts, but a future flag
            // that did would deterministically fail instead of wedging.
            process.standardInput = FileHandle.nullDevice

            let stderr = StderrTail(limit: Self.stderrTailLimit)
            let terminalEventSeen = TerminalEventFlag()
            // FileHandle callbacks and Process.terminationHandler run on
            // unrelated queues. Serialize EVERY read + parse with final EOF
            // draining so termination cannot finish the stream after a
            // callback consumed a line but before it delivered that line to
            // the NDJSON pump.
            let pipeQueue = DispatchQueue(
                label: "dev.darkbloom.app.account-link-pipes"
            )

            let pump = NDJSONLinePump(
                onLine: { line in
                    guard !terminalEventSeen.value else { return }
                    let event: AccountLinkEvent
                    do {
                        event = try AccountLinkEventDecoding.decode(line: line)
                    } catch {
                        terminalEventSeen.value = true
                        if process.isRunning { process.terminate() }
                        continuation.finish(throwing: error)
                        return
                    }
                    if event.isTerminal { terminalEventSeen.value = true }
                    continuation.yield(event)
                },
                onStderr: { data in
                    stderr.append(data)
                }
            )

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                pipeQueue.sync {
                    pump.append(stdout: handle.availableData)
                }
            }
            // Drain stderr so a chatty child never blocks on a full pipe.
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                pipeQueue.sync {
                    pump.append(stderr: handle.availableData)
                }
            }

            process.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                pipeQueue.sync {
                    // Drain whatever bytes are still buffered: the child is
                    // dead so both reads reach EOF. A callback that entered
                    // first completes before this block; one that enters
                    // later sees empty data.
                    pump.append(stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    pump.append(stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    pump.flushPendingLine()
                    guard !terminalEventSeen.value else {
                        // `.linked` or `.error` was already delivered as data;
                        // the non-zero exit that follows an error event is part
                        // of the CLI's contract, not a transport failure.
                        continuation.finish()
                        return
                    }
                    let status = process.terminationStatus
                    if status == 0 {
                        continuation.finish()
                    } else {
                        let tail = stderr.text
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                            .last ?? ""
                        continuation.finish(throwing: ProviderCLIError.exited(status, message: tail))
                    }
                }
            }

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Shared mutable "did we see a terminal event" across the readability and
/// termination handlers.
private final class TerminalEventFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false

    var value: Bool {
        get { lock.withLock { seen } }
        set { lock.withLock { seen = newValue } }
    }
}

/// Splits a byte stream into NDJSON lines. Stdout bytes arrive in arbitrary
/// chunk sizes, and the final line may lack a trailing newline if the child
/// exits abruptly — `flushPendingLine` delivers that remainder at EOF.
private final class NDJSONLinePump: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: (String) -> Void
    private let onStderr: (Data) -> Void

    init(onLine: @escaping (String) -> Void, onStderr: @escaping (Data) -> Void) {
        self.onLine = onLine
        self.onStderr = onStderr
    }

    func append(stdout data: Data) {
        let lines: [String] = lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending = pending.subdata(in: pending.index(after: newline)..<pending.endIndex)
                if !line.isEmpty {
                    lines.append(String(decoding: line, as: UTF8.self))
                }
            }
            return lines
        }
        for line in lines { onLine(line) }
    }

    func append(stderr data: Data) {
        onStderr(data)
    }

    func flushPendingLine() {
        let line: String? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            let rest = pending
            pending = Data()
            return String(decoding: rest, as: UTF8.self)
        }
        if let line { onLine(line) }
    }
}

/// Bounded stderr accumulator shared across readability callbacks.
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit {
                data = data.suffix(limit)
            }
        }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}
