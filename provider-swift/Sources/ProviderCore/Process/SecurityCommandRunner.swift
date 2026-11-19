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
    }

    /// Like `bounded(timeout:)`, and each stream keeps at most `outputLimit`
    /// bytes: more stops the command (`CommandError.outputTooLarge`). Both
    /// streams are read as data arrives, and are closed when the call returns,
    /// so no reader outlives it, even when another process keeps a pipe open.
    public static func bounded(timeout: TimeInterval, outputLimit: Int) -> SecurityCommandRunner {
        SecurityCommandRunner { executablePath, arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let changed = DispatchSemaphore(value: 0)
            let stdout = LimitedCommandOutput(limit: outputLimit) { changed.signal() }
            let stderr = LimitedCommandOutput(limit: outputLimit) { changed.signal() }
            let exit = CommandExit()
            process.standardOutput = stdout.pipe
            process.standardError = stderr.pipe
            process.terminationHandler = { _ in
                exit.mark()
                changed.signal()
            }
            let deadline = DispatchTime.now() + max(0, timeout)
            defer {
                stdout.close()
                stderr.close()
            }
            try process.run()
            stdout.start()
            stderr.start()
            // Each change signals after it is recorded, so a change between a
            // check and the wait still wakes the wait.
            while true {
                if stdout.overflowed || stderr.overflowed {
                    if !exit.happened { kill(process.processIdentifier, SIGKILL) }
                    throw CommandError.outputTooLarge
                }
                if exit.happened, stdout.finished, stderr.finished { break }
                guard changed.wait(timeout: deadline) == .success else {
                    if !exit.happened { kill(process.processIdentifier, SIGKILL) }
                    throw CommandError.timedOut
                }
            }
            return SecurityCommandResult(
                terminationStatus: process.terminationStatus,
                stdout: stdout.text,
                stderr: stderr.text,
                wroteToStderr: stderr.wrote
            )
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

/// Whether a command of `bounded(timeout:outputLimit:)` has exited.
private final class CommandExit: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    func mark() { lock.withLock { exited = true } }
    var happened: Bool { lock.withLock { exited } }
}

/// One stream of `bounded(timeout:outputLimit:)`: read as data arrives (no
/// thread waits on it), kept up to `limit` bytes, and closed by the caller.
/// Each read runs under the lock and only while the stream is open, so
/// closing never races a read. `changed` wakes the caller.
private final class LimitedCommandOutput: @unchecked Sendable {
    let pipe = Pipe()
    private let limit: Int
    private let changed: @Sendable () -> Void
    private let lock = NSLock()
    private var data = Data()
    private var reachedEnd = false
    private var tooLarge = false
    private var closed = false

    init(limit: Int, changed: @escaping @Sendable () -> Void) {
        self.limit = max(0, limit)
        self.changed = changed
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let stop: Bool = self.lock.withLock {
                guard !self.closed else { return true }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                let count = read(handle.fileDescriptor, &buffer, buffer.count)
                if count < 0, errno == EAGAIN || errno == EINTR { return false }
                if count <= 0 {
                    self.reachedEnd = true
                } else if self.data.count + count > self.limit {
                    self.tooLarge = true
                } else {
                    self.data.append(contentsOf: buffer[0..<count])
                }
                return self.reachedEnd || self.tooLarge
            }
            if stop { handle.readabilityHandler = nil }
            self.changed()
        }
    }

    /// No read starts after this; one in progress finishes before the close.
    func close() {
        lock.withLock { closed = true }
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.withLock { try? pipe.fileHandleForReading.close() }
    }

    var finished: Bool { lock.withLock { reachedEnd } }
    var overflowed: Bool { lock.withLock { tooLarge } }
    var wrote: Bool { lock.withLock { !data.isEmpty } }
    var text: String { lock.withLock { String(data: data, encoding: .utf8) ?? "" } }
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
