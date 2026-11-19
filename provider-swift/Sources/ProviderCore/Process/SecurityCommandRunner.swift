import Foundation

// MARK: - Command Running

public struct SecurityCommandResult: Sendable, Equatable {
    public let terminationStatus: Int32
    public let stdout: String
    public let stderr: String
    /// Whether the command wrote anything to stderr, even bytes that don't decode (then `stderr` is empty).
    public let wroteToStderr: Bool

    public init(terminationStatus: Int32, stdout: String = "", stderr: String = "", wroteToStderr: Bool? = nil) {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
        self.wroteToStderr = wroteToStderr ?? !stderr.isEmpty
    }
}

public struct SecurityCommandRunner: @unchecked Sendable {
    public var run: (_ executablePath: String, _ arguments: [String]) throws -> SecurityCommandResult

    public init(
        run: @escaping (_ executablePath: String, _ arguments: [String]) throws -> SecurityCommandResult
    ) {
        self.run = run
    }

    public static let live = make(timeout: nil)

    /// Diagnostic commands must not hold up an App Attest ready reply.
    public static func bounded(timeout: TimeInterval) -> SecurityCommandRunner {
        make(timeout: max(0, timeout))
    }

    public enum CommandError: Error {
        case timedOut
        /// A stream passed its `outputLimit` (`bounded(timeout:outputLimit:)`).
        case outputTooLarge
        /// A stream couldn't be read to its end (`bounded(timeout:outputLimit:)`).
        case outputUnreadable
        /// The command's exit couldn't be seen (`bounded(timeout:outputLimit:)`).
        case exitUnobserved
    }

    /// Like `bounded(timeout:)`, and each stream keeps at most `outputLimit`
    /// bytes: more stops the command (`CommandError.outputTooLarge`). The
    /// command's process is owned for its whole life (`BoundedCommand`): a
    /// stop never signals a process that has been reaped, both streams are read
    /// as data arrives, and nothing waits on them after the call returns.
    public static func bounded(timeout: TimeInterval, outputLimit: Int) -> SecurityCommandRunner {
        SecurityCommandRunner { executablePath, arguments in
            try BoundedCommand.run(executablePath, arguments, timeout: timeout, outputLimit: outputLimit)
        }
    }

    private static func make(timeout: TimeInterval?) -> SecurityCommandRunner {
        SecurityCommandRunner { executablePath, arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stdout = CommandOutputPipe()
            let stderr = CommandOutputPipe()
            process.standardOutput = stdout.pipe
            process.standardError = stderr.pipe

            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
            try process.run()
            // Drain both streams while the child runs. Waiting first, or reading
            // the pipes serially, deadlocks when an unread pipe fills. Each reader
            // has its own serial queue, because a serial queue gets a thread even
            // when every cooperative thread waits here. A global queue does not.
            let readers = DispatchGroup()
            for output in [stdout, stderr] {
                DispatchQueue(label: "dev.darkbloom.command-output", qos: .utility)
                    .async(group: readers) { output.drain() }
            }
            guard exited.wait(timeout: deadline) == .success else {
                // A hung tool may ignore SIGTERM. Process reaps asynchronously;
                // never wait for termination or pipe EOF on the caller's deadline.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw CommandError.timedOut
            }
            guard readers.wait(timeout: deadline) == .success else {
                throw CommandError.timedOut
            }

            return SecurityCommandResult(
                terminationStatus: process.terminationStatus,
                stdout: stdout.text,
                stderr: stderr.text,
                wroteToStderr: !stderr.isEmpty
            )
        }
    }
}

/// One reader owns each pipe; the lock publishes its result to the caller.
private final class CommandOutputPipe: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()

    func drain() {
        let captured = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.withLock { data = captured }
    }

    var text: String {
        lock.withLock { String(data: data, encoding: .utf8) ?? "" }
    }

    var isEmpty: Bool {
        lock.withLock { data.isEmpty }
    }
}
