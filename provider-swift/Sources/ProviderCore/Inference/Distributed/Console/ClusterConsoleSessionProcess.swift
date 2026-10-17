import Foundation
import Darwin

/// The session the console starts: one child process, its output and its end.
///
/// The child runs in a session of its own, with default signal handling and
/// none of the console's descriptors. Closing the console's terminal window
/// therefore does not reach it: the console hears of that itself and asks the
/// child to stop, so the child always ends by its own cooperative stop. Its
/// output goes to a pseudo-terminal of its own, which keeps lines arriving as
/// they are printed, where a pipe would hold them back until the process ends.
/// The only signal this type ever sends is the interrupt.
public final class ClusterConsoleSessionProcess: ClusterConsoleSessionHandle, @unchecked Sendable {
    public struct Launch: Sendable {
        public let executable: URL
        public let arguments: [String]

        public init(executable: URL, arguments: [String]) {
            self.executable = executable; self.arguments = arguments
        }
    }

    public struct CannotStart: Error, CustomStringConvertible {
        let code: Int32
        public var description: String {
            "The session process could not be started: \(String(cString: strerror(code))) (errno \(code))."
        }
    }

    /// A longer line is reported in pieces of this size; nothing a session prints comes close.
    static let maximumLineBytes = 2048
    private static let readIntervalMilliseconds: Int32 = 150

    public let processIdentifier: Int32
    private let lock = NSLock()
    /// The process has exited. From then on nothing is signalled: its
    /// identifier may come to name another process.
    private var exited = false
    /// The wait status, once the process has been collected.
    private var status: Int32?

    private init(processIdentifier: Int32) { self.processIdentifier = processIdentifier }

    public static func start(_ launch: Launch,
                             events: @escaping @Sendable (ClusterConsoleSessionEvent) -> Void) throws -> ClusterConsoleSessionProcess {
        var primary: Int32 = -1, secondary: Int32 = -1
        guard openpty(&primary, &secondary, nil, nil, nil) == 0 else { throw CannotStart(code: errno) }
        let reader = primary, writer = secondary
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        // The child reads nothing, writes to the terminal made for it, and
        // inherits no other descriptor of the console's.
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO)
        // The console ignores the signals it takes as events, and an ignored
        // signal stays ignored across a start: the child gets every default back.
        var every = sigset_t(), none = sigset_t()
        sigfillset(&every)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &every)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes,
            Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // A terminal that is not a screen: the child is asked for plain text.
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        let argumentStrings = ([launch.executable.path] + launch.arguments).map { strdup($0) }
        let environmentStrings = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (argumentStrings + environmentStrings).forEach { free($0) } }

        var identifier: pid_t = 0
        let result = posix_spawn(&identifier, launch.executable.path, &actions, &attributes,
            argumentStrings + [nil], environmentStrings + [nil])
        Darwin.close(writer)
        guard result == 0 else {
            Darwin.close(reader)
            throw CannotStart(code: result)
        }
        let session = ClusterConsoleSessionProcess(processIdentifier: identifier)
        Thread.detachNewThread { session.awaitExit() }
        Thread.detachNewThread { session.follow(reader: reader, events: events) }
        return session
    }

    /// Learns of the exit before collecting the process, so that no signal
    /// can be sent once its identifier is free to be used again.
    private func awaitExit() {
        var information = siginfo_t()
        while waitid(P_PID, id_t(processIdentifier), &information, WEXITED | WNOWAIT) != 0 && errno == EINTR {}
        lock.withLock { exited = true }
        var collected: Int32 = 0
        while waitpid(processIdentifier, &collected, 0) < 0 && errno == EINTR {}
        lock.withLock { status = collected }
    }

    public func interrupt() {
        // Only this object's own child, and only while it has not exited.
        lock.withLock {
            guard !exited else { return }
            _ = kill(processIdentifier, SIGINT)
        }
    }

    /// Reports each line the child writes, then, after the last of them, how it ended.
    private func follow(reader: Int32, events: @Sendable (ClusterConsoleSessionEvent) -> Void) {
        defer { Darwin.close(reader) }
        let lineFeed = UInt8(ascii: "\n"), carriageReturn = UInt8(ascii: "\r")
        // The stream starts at the start of a line.
        var partial = [UInt8](), buffer = [UInt8](repeating: 0, count: 4096), previous = lineFeed, splitAtLimit = false
        func emit() {
            events(.output(String(decoding: partial, as: UTF8.self)))
            partial.removeAll(keepingCapacity: true)
        }
        /// Everything readable now. False once the terminal has no writer left.
        /// A line ends at a line feed, at a carriage return and line feed
        /// together, and at a carriage return alone, so progress rewritten in
        /// place arrives as lines. A line that reaches its limit is reported
        /// as it is and continues as the next.
        func drain() -> Bool {
            while true {
                let count = Darwin.read(reader, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && errno == EAGAIN { return true }
                guard count > 0 else { return false }
                for byte in buffer.prefix(count) {
                    defer { previous = byte }
                    guard byte == lineFeed || byte == carriageReturn else {
                        splitAtLimit = false
                        partial.append(byte)
                        if partial.count == Self.maximumLineBytes {
                            emit()
                            splitAtLimit = true
                        }
                        continue
                    }
                    // The ending of a line that was just split at its limit adds no empty line.
                    let endsSplit = splitAtLimit
                    splitAtLimit = false
                    // The line feed of a pair: its carriage return ended the line.
                    if byte == lineFeed, previous == carriageReturn { continue }
                    if endsSplit { continue }
                    // A carriage return with nothing before it on the line is
                    // a line only where a line had just ended: an empty one.
                    if byte == lineFeed || !partial.isEmpty || previous == lineFeed { emit() }
                }
            }
        }
        func collected() -> Int32? { lock.withLock { status } }
        var open = true
        while open, collected() == nil {
            var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
            _ = Darwin.poll(&descriptor, 1, Self.readIntervalMilliseconds)
            open = drain()
        }
        // A grandchild may still hold the terminal; the session's end is the
        // process's own, so what it wrote is read once more and that is all.
        var ended = collected()
        while ended == nil {
            usleep(UInt32(Self.readIntervalMilliseconds) * 1000)
            ended = collected()
        }
        if open { _ = drain() }
        if !partial.isEmpty { emit() }
        // The low seven bits name a signal that ended the process; with none, the next eight are its exit status.
        let waitStatus = ended ?? 0, signal = waitStatus & 0x7F
        if signal == 0 {
            let code = (waitStatus >> 8) & 0xFF
            events(.ended(description: "exited with status \(code)", clean: code == 0))
        } else {
            events(.ended(description: "was ended by signal \(signal)", clean: false))
        }
    }
}
