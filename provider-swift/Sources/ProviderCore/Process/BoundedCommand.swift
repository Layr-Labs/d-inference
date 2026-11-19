import Darwin
import Foundation

/// One command of `SecurityCommandRunner.bounded(timeout:outputLimit:)`, run without Foundation's `Process` so that
/// this file owns the child's whole life. It spawns the child, waits for its exit without reaping it, sends a kill
/// only before that exit is seen (until then the child can't have been reaped, so its process ID names no other
/// process), and then reaps it. Each output stream is read without blocking as data arrives, and kept up to the
/// limit. The caller returns at its deadline; the reaping of a killed child finishes on its waiting thread.
enum BoundedCommand {
    static func run(
        _ executablePath: String, _ arguments: [String], timeout: TimeInterval, outputLimit: Int
    ) throws -> SecurityCommandResult {
        let deadline = DispatchTime.now() + max(0, timeout)
        let changed = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "dev.darkbloom.bounded-command.output")
        let stdout = try BoundedOutput(limit: outputLimit, queue: queue) { changed.signal() }
        defer { stdout.close() }
        let stderr = try BoundedOutput(limit: outputLimit, queue: queue) { changed.signal() }
        defer { stderr.close() }
        let child = try OwnedChild(executablePath, arguments, stdout: stdout.writeEnd, stderr: stderr.writeEnd)
        stdout.closeWriteEnd()
        stderr.closeWriteEnd()
        child.watch { changed.signal() }
        stdout.start()
        stderr.start()
        // Every change is recorded before it signals, so the checks below see it after any wake. The deadline is
        // checked on its own: wakes queued past it don't extend it.
        while true {
            if stdout.unreadable || stderr.unreadable {
                child.kill()
                throw SecurityCommandRunner.CommandError.outputUnreadable
            }
            if stdout.overflowed || stderr.overflowed {
                child.kill()
                throw SecurityCommandRunner.CommandError.outputTooLarge
            }
            if let status = child.exitStatus, stdout.finished, stderr.finished {
                return SecurityCommandResult(terminationStatus: status, stdout: stdout.text, stderr: stderr.text,
                                             wroteToStderr: stderr.wrote)
            }
            guard DispatchTime.now() < deadline, changed.wait(timeout: deadline) == .success else {
                child.kill()
                throw SecurityCommandRunner.CommandError.timedOut
            }
        }
    }
}

/// A child process this file spawned and alone reaps.
private final class OwnedChild: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var exited = false
    private var status: Int32?

    /// Standard input reads `/dev/null`; standard output and error go to the given descriptors; no other descriptor
    /// reaches the child. Signals start at their defaults with none blocked, as with `Process`.
    init(_ executablePath: String, _ arguments: [String], stdout: Int32, stderr: Int32) throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t()
        sigfillset(&all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] =
            ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executablePath, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        self.pid = pid
    }

    /// On its own thread: waits for the exit without reaping (the child stays a zombie, holding its process ID),
    /// records it, then reaps the child and records its status (the exit code, or the signal that ended it, as
    /// `Process.terminationStatus` gives).
    func watch(_ changed: @escaping @Sendable () -> Void) {
        Thread { [self] in
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            lock.withLock { exited = true }
            var raw: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &raw, 0) } while reaped == -1 && errno == EINTR
            let code = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : raw & 0x7f
            lock.withLock { status = reaped == pid ? code : -1 }
            changed()
        }.start()
    }

    /// Kills the child unless its exit was already seen. Under the lock the waiting thread takes before it reaps,
    /// so the signal can only reach this child.
    func kill() {
        lock.withLock {
            if !exited { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    /// The status once the child is reaped; nil until then.
    var exitStatus: Int32? { lock.withLock { status } }
}

/// One output stream: a pipe whose read end never blocks and is read on `queue` as data arrives (a dispatch read
/// source, whose cancel closes the descriptor after any read in progress), keeping at most `limit` bytes.
private final class BoundedOutput: @unchecked Sendable {
    let writeEnd: Int32
    private let readEnd: Int32
    private let limit: Int
    private let queue: DispatchQueue
    private let changed: @Sendable () -> Void
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    private var tooLarge = false
    private var failed = false
    private var writeOpen = true
    private var source: DispatchSourceRead?
    private var closed = false

    init(limit: Int, queue: DispatchQueue, changed: @escaping @Sendable () -> Void) throws {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        readEnd = ends[0]
        writeEnd = ends[1]
        // Neither end reaches another process this one starts (the child gets its copy through `dup2`).
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) | O_NONBLOCK)
        self.limit = max(0, limit)
        self.queue = queue
        self.changed = changed
    }

    /// This process's copy of the write end, closed once the child has its own, so the stream ends with the child.
    func closeWriteEnd() {
        lock.withLock {
            guard writeOpen else { return }
            writeOpen = false
            _ = Darwin.close(writeEnd)
        }
    }

    func start() {
        let fd = readEnd
        lock.withLock {
            guard !closed, source == nil else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            source.setCancelHandler { _ = Darwin.close(fd) }
            self.source = source
            source.resume()
        }
    }

    /// Reads what is there. A full stream, its end or a read error stops it.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(readEnd, &buffer, buffer.count)
            let error = errno
            if count < 0, error == EINTR { continue }
            if count < 0, error == EAGAIN || error == EWOULDBLOCK { break }
            let done: Bool = lock.withLock {
                if count > 0, data.count + count <= limit {
                    data.append(contentsOf: buffer[0..<count])
                    return false
                }
                if count > 0 { tooLarge = true } else if count == 0 { ended = true } else { failed = true }
                return true
            }
            if done {
                lock.withLock { source }?.cancel()
                break
            }
        }
        changed()
    }

    /// Stops reading and closes both ends, once: a started stream's read end closes when its source is cancelled,
    /// one never started closes here.
    func close() {
        closeWriteEnd()
        let (started, closeNow): (DispatchSourceRead?, Bool) = lock.withLock {
            guard !closed else { return (nil, false) }
            closed = true
            return (source, source == nil)
        }
        if let started {
            started.cancel()
        } else if closeNow {
            _ = Darwin.close(readEnd)
        }
    }

    var finished: Bool { lock.withLock { ended } }
    var overflowed: Bool { lock.withLock { tooLarge } }
    var unreadable: Bool { lock.withLock { failed } }
    var wrote: Bool { lock.withLock { !data.isEmpty } }
    var text: String { lock.withLock { String(data: data, encoding: .utf8) ?? "" } }
}
