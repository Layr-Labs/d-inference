import Darwin
import Foundation

/// One command of `SecurityCommandRunner.bounded(timeout:outputLimit:)`, run without Foundation's `Process` so that
/// this file owns the child's whole life. It spawns the child, waits for its exit without reaping it, sends a kill
/// only before that exit is seen (until then the child can't have been reaped, so its process ID names no other
/// process), and then reaps it. Each output stream is read without blocking as data arrives, and kept up to the
/// limit. The caller returns at its deadline; the reaping of a killed child finishes on its waiting thread.
enum BoundedCommand {
    /// `hooks` stand in for the system calls behind the process (tests); `pauseBeforeCheck` runs before each look
    /// at the command's state (tests: a late wake).
    static func run(
        _ executablePath: String, _ arguments: [String], timeout: TimeInterval, outputLimit: Int,
        hooks: BoundedCommandHooks = .live, pauseBeforeCheck: (() -> Void)? = nil
    ) throws -> SecurityCommandResult {
        let deadline = DispatchTime.now() + max(0, timeout)
        let changed = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "dev.darkbloom.bounded-command.output")
        let steps = SetupSteps(failing: hooks.failingSetupStep)
        let stdout = try BoundedOutput(limit: outputLimit, queue: queue, steps: steps) { changed.signal() }
        defer { stdout.close() }
        let stderr = try BoundedOutput(limit: outputLimit, queue: queue, steps: steps) { changed.signal() }
        defer { stderr.close() }
        let child = try OwnedChild(executablePath, arguments, stdout: stdout.writeEnd, stderr: stderr.writeEnd,
                                   hooks: hooks, steps: steps)
        stdout.closeWriteEnd()
        stderr.closeWriteEnd()
        child.watch { changed.signal() }
        stdout.start()
        stderr.start()
        // Every change is recorded before it signals, so a check after any wake sees it. The deadline wins: a wake
        // after it times out even when the command finished meanwhile, and wakes queued past it don't extend it.
        while true {
            pauseBeforeCheck?()
            guard DispatchTime.now() < deadline else {
                child.kill()
                throw SecurityCommandRunner.CommandError.timedOut
            }
            if stdout.unreadable || stderr.unreadable {
                child.kill()
                throw SecurityCommandRunner.CommandError.outputUnreadable
            }
            if stdout.overflowed || stderr.overflowed {
                child.kill()
                throw SecurityCommandRunner.CommandError.outputTooLarge
            }
            switch child.outcome {
            case .running:
                break
            case .unobserved:
                throw SecurityCommandRunner.CommandError.exitUnobserved
            case .exited(let status) where stdout.finished && stderr.finished:
                return SecurityCommandResult(terminationStatus: status, stdout: stdout.text, stderr: stderr.text,
                                             wroteToStderr: stderr.wrote)
            case .exited:
                break
            }
            guard changed.wait(timeout: deadline) == .success else {
                child.kill()
                throw SecurityCommandRunner.CommandError.timedOut
            }
        }
    }

    /// A setup step's result: 0 goes on; anything else throws that error.
    fileprivate static func check(_ result: Int32) throws {
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
    }

    /// For calls that return -1 and set `errno`.
    fileprivate static func checkErrno(_ result: Int32) throws {
        guard result != -1 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// The system calls behind a command's process. Production uses `live`; tests stand in for one to reach a path a
/// real system rarely takes (an interrupted or failed wait, a child another reaper took, a failed setup step).
struct BoundedCommandHooks: @unchecked Sendable {
    /// `waitid(P_PID, pid, WEXITED | WNOWAIT)`: its result and `errno`.
    var waitForExit: @Sendable (pid_t) -> (result: Int32, error: Int32)
    /// `waitpid(pid, &status, options)`: the process it returned, the raw status and `errno`.
    var reap: @Sendable (pid_t, Int32) -> (pid: pid_t, raw: Int32, error: Int32)
    /// Sends `SIGKILL`.
    var signal: @Sendable (pid_t) -> Void
    /// This setup step (counted from 1) fails with `EIO` before its call is made.
    var failingSetupStep: Int?

    static let live = BoundedCommandHooks(
        waitForExit: { pid in
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
            return (result, result == -1 ? errno : 0)
        },
        reap: { pid, options in
            var raw: Int32 = 0
            let reaped = waitpid(pid, &raw, options)
            return (reaped, raw, reaped == -1 ? errno : 0)
        },
        signal: { _ = Darwin.kill($0, SIGKILL) },
        failingSetupStep: nil)
}

/// Counts the setup steps of one command, so a test can fail one (`BoundedCommandHooks.failingSetupStep`).
private final class SetupSteps: @unchecked Sendable {
    private let failing: Int?
    private let lock = NSLock()
    private var taken = 0
    init(failing: Int?) { self.failing = failing }
    /// Before each setup call: throws when this is the step to fail, so that call is never made.
    func next() throws {
        let step: Int = lock.withLock {
            taken += 1
            return taken
        }
        if step == failing { throw POSIXError(.EIO) }
    }
}

/// A child process this file spawned and alone reaps.
private final class OwnedChild: @unchecked Sendable {
    enum Outcome {
        case running
        /// Reaped: the exit code, or the signal that ended it, as `Process.terminationStatus` gives.
        case exited(Int32)
        /// The exit can't be seen: the child isn't this process's to wait for.
        case unobserved
    }

    private let pid: pid_t
    private let hooks: BoundedCommandHooks
    private let lock = NSLock()
    /// The child's exit was seen (or it can no longer be waited for): no kill after this.
    private var done = false
    private var result = Outcome.running

    /// Standard input reads `/dev/null`; standard output and error go to the given descriptors; no other descriptor
    /// reaches the child, which gets this process's environment. Signals start at their defaults with none blocked,
    /// as with `Process`. Every setup step is checked; a failed one starts nothing.
    init(_ executablePath: String, _ arguments: [String], stdout: Int32, stderr: Int32,
         hooks: BoundedCommandHooks, steps: SetupSteps) throws {
        var actions: posix_spawn_file_actions_t?
        try steps.next()
        try BoundedCommand.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try steps.next()
        try BoundedCommand.check(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0))
        try steps.next()
        try BoundedCommand.check(posix_spawn_file_actions_adddup2(&actions, stdout, 1))
        try steps.next()
        try BoundedCommand.check(posix_spawn_file_actions_adddup2(&actions, stderr, 2))
        var attributes: posix_spawnattr_t?
        try steps.next()
        try BoundedCommand.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t()
        sigfillset(&all)
        var none = sigset_t()
        sigemptyset(&none)
        try steps.next()
        try BoundedCommand.check(posix_spawnattr_setsigdefault(&attributes, &all))
        try steps.next()
        try BoundedCommand.check(posix_spawnattr_setsigmask(&attributes, &none))
        try steps.next()
        try BoundedCommand.check(posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        let strings = ([executablePath] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        try steps.next()
        guard strings.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        var argv = strings + [nil]
        var pid: pid_t = 0
        try steps.next()
        let spawned = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, executablePath, &actions, &attributes, buffer.baseAddress!, environ)
        }
        try BoundedCommand.check(spawned)
        self.pid = pid
        self.hooks = hooks
    }

    /// On its own thread: waits for the exit without reaping it (the child stays a zombie, holding its process ID),
    /// records that under the lock, then reaps it and records the status. If that wait fails for another reason, it
    /// reaps by polling, each poll under the lock, so a kill still reaches a running child and never a reaped one.
    /// A child that can't be waited for at all (`ECHILD`) is never signalled.
    func watch(_ changed: @escaping @Sendable () -> Void) {
        Thread { [self] in
            var waited: (result: Int32, error: Int32)
            repeat { waited = hooks.waitForExit(pid) } while waited.result == -1 && waited.error == EINTR
            if waited.result == 0 {
                lock.withLock { done = true }
                var reaped: (pid: pid_t, raw: Int32, error: Int32)
                repeat { reaped = hooks.reap(pid, 0) } while reaped.pid == -1 && reaped.error == EINTR
                lock.withLock { result = reaped.pid == pid ? Self.outcome(reaped.raw) : .unobserved }
            } else if waited.error == ECHILD {
                lock.withLock {
                    done = true
                    result = .unobserved
                }
            } else {
                while true {
                    let finished: Bool = lock.withLock {
                        let reaped = hooks.reap(pid, WNOHANG)
                        if reaped.pid == pid {
                            done = true
                            result = Self.outcome(reaped.raw)
                        } else if reaped.pid == -1, reaped.error != EINTR {
                            done = true
                            result = .unobserved
                        }
                        return done
                    }
                    if finished { break }
                    usleep(20_000)
                }
            }
            changed()
        }.start()
    }

    private static func outcome(_ raw: Int32) -> Outcome {
        .exited((raw & 0x7f) == 0 ? (raw >> 8) & 0xff : raw & 0x7f)
    }

    /// Kills the child unless its exit was already seen. Under the lock the waiting thread holds while it records
    /// the exit or reaps by polling, so the signal can only reach this child.
    func kill() {
        lock.withLock {
            if !done { hooks.signal(pid) }
        }
    }

    var outcome: Outcome { lock.withLock { result } }
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

    /// Both ends close on exec (the child gets its copy of the write end through `dup2`), and the read end never
    /// blocks. Before macOS 27 the flag follows `pipe`: the provider's other launchers (`Process`, and `posix_spawn`
    /// with `POSIX_SPAWN_CLOEXEC_DEFAULT`) pass no descriptor they weren't given, so that gap passes nothing on. A
    /// failed step closes both ends.
    init(limit: Int, queue: DispatchQueue, steps: SetupSteps, changed: @escaping @Sendable () -> Void) throws {
        var ends: [Int32] = [-1, -1]
        try steps.next()
        if #available(macOS 27, *) {
            try BoundedCommand.checkErrno(pipe2(&ends, O_CLOEXEC))
        } else {
            try BoundedCommand.checkErrno(pipe(&ends))
        }
        do {
            try steps.next()
            try BoundedCommand.checkErrno(fcntl(ends[0], F_SETFD, FD_CLOEXEC))
            try steps.next()
            try BoundedCommand.checkErrno(fcntl(ends[1], F_SETFD, FD_CLOEXEC))
            try steps.next()
            let flags = fcntl(ends[0], F_GETFL)
            try BoundedCommand.checkErrno(flags)
            try steps.next()
            try BoundedCommand.checkErrno(fcntl(ends[0], F_SETFL, flags | O_NONBLOCK))
        } catch {
            _ = Darwin.close(ends[0])
            _ = Darwin.close(ends[1])
            throw error
        }
        readEnd = ends[0]
        writeEnd = ends[1]
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

    /// Reads what is there. A full stream, its end or a read error stops it; so does `close()`, between reads.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if lock.withLock({ closed }) { break }
            let count = Darwin.read(readEnd, &buffer, buffer.count)
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
