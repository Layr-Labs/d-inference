import Foundation

// MARK: - Command Running

public struct SecurityCommandResult: Sendable, Equatable {
    public let terminationStatus: Int32
    public let stdout: String
    public let stderr: String

    public init(terminationStatus: Int32, stdout: String = "", stderr: String = "") {
        self.terminationStatus = terminationStatus
        self.stdout = stdout
        self.stderr = stderr
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

    public enum CommandError: Error { case timedOut }

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
            // the pipes serially, deadlocks when an unread pipe fills.
            let readers = DispatchGroup()
            for output in [stdout, stderr] {
                DispatchQueue.global(qos: .utility).async(group: readers) { output.drain() }
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
                stderr: stderr.text
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
}
