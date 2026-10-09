import Foundation
import Darwin

/// The session the console starts: one child process, its output and its end.
///
/// The child's output goes to a pseudo-terminal of its own. That keeps its
/// lines arriving as they are printed, where a pipe or a file would hold them
/// back until the process ends, and it means a child that is still stopping
/// when the console closes is not ended by a broken pipe. The only signal this
/// type ever sends is the interrupt.
public final class ClusterConsoleSessionProcess: ClusterConsoleSessionHandle, @unchecked Sendable {
    public struct Launch: Sendable {
        public let executable: URL
        public let arguments: [String]

        public init(executable: URL, arguments: [String]) {
            self.executable = executable; self.arguments = arguments
        }
    }

    /// A line longer than this is cut; nothing a session prints comes close.
    static let maximumLineBytes = 2048
    private static let readIntervalMilliseconds: Int32 = 150

    private let process = Process()
    private let lock = NSLock()
    private var ended = false

    public var processIdentifier: Int32 { process.processIdentifier }

    public static func start(_ launch: Launch,
                             events: @escaping @Sendable (ClusterConsoleSessionEvent) -> Void) throws -> ClusterConsoleSessionProcess {
        var primary: Int32 = -1, secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else {
            throw ClusterConfigurationError.invalid("Cannot open a terminal for the session's output (errno \(errno))")
        }
        let reader = primary, writer = secondary
        // The child gets the writing end as its output and nothing else of ours.
        _ = fcntl(reader, F_SETFD, FD_CLOEXEC)
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)
        let output = FileHandle(fileDescriptor: writer, closeOnDealloc: true)

        let session = ClusterConsoleSessionProcess()
        session.process.executableURL = launch.executable
        session.process.arguments = launch.arguments
        session.process.standardInput = FileHandle.nullDevice
        session.process.standardOutput = output
        session.process.standardError = output
        session.process.terminationHandler = { [weak session] _ in session?.markEnded() }
        do { try session.process.run() } catch {
            Darwin.close(reader)
            throw error
        }
        Thread.detachNewThread { session.follow(reader: reader, events: events) }
        return session
    }

    private func markEnded() { lock.withLock { ended = true } }

    public func interrupt() {
        // Never a process identifier that may have been reused: only this
        // object's own child, and only while it runs.
        guard process.isRunning else { return }
        process.interrupt()
    }

    /// Reports each line the child writes, then, after the last of them, how it ended.
    private func follow(reader: Int32, events: @Sendable (ClusterConsoleSessionEvent) -> Void) {
        defer { Darwin.close(reader) }
        var partial = [UInt8](), buffer = [UInt8](repeating: 0, count: 4096)
        func emit() {
            events(.output(String(decoding: partial.prefix(Self.maximumLineBytes), as: UTF8.self)))
            partial.removeAll(keepingCapacity: true)
        }
        /// Everything readable now. False once the terminal has no writer left.
        func drain() -> Bool {
            while true {
                let count = Darwin.read(reader, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && errno == EAGAIN { return true }
                guard count > 0 else { return false }
                for byte in buffer.prefix(count) {
                    if byte == UInt8(ascii: "\n") { emit() } else if byte != UInt8(ascii: "\r") { partial.append(byte) }
                }
            }
        }
        var open = true
        while open, !lock.withLock({ ended }) {
            var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            _ = Darwin.poll(&descriptor, 1, Self.readIntervalMilliseconds)
            open = drain()
        }
        // A grandchild may still hold the terminal; the session's end is the
        // process's own, so what it wrote is read once more and that is all.
        while !lock.withLock({ ended }) { usleep(UInt32(Self.readIntervalMilliseconds) * 1000) }
        if open { _ = drain() }
        if !partial.isEmpty { emit() }
        switch process.terminationReason {
        case .exit:
            events(.ended(description: "exited with status \(process.terminationStatus)", clean: process.terminationStatus == 0))
        default:
            events(.ended(description: "was ended by signal \(process.terminationStatus)", clean: false))
        }
    }
}
