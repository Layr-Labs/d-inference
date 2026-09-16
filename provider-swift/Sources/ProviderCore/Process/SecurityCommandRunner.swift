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

    public static let live = SecurityCommandRunner { executablePath, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = CommandOutputPipe()
        let stderr = CommandOutputPipe()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe

        try process.run()
        // Drain both streams while the child runs. Waiting first, or reading
        // the pipes serially, deadlocks when an unread pipe fills.
        let readers = DispatchGroup()
        for output in [stdout, stderr] {
            DispatchQueue.global(qos: .utility).async(group: readers) { output.drain() }
        }
        process.waitUntilExit()
        readers.wait()

        return SecurityCommandResult(
            terminationStatus: process.terminationStatus,
            stdout: stdout.text,
            stderr: stderr.text
        )
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
