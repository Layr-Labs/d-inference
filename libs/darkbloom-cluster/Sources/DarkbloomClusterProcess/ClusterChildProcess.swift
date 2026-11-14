import Darwin
import Foundation

/// A cluster launcher's child (a worker, an owner or a calibration process),
/// started from a `ClusterWorkerLaunch` with its standard streams on the
/// launcher's pipes.
///
/// A launch that carries `verifyLaunched` is spawned suspended: the kernel has
/// mapped the image but the child has run none of its instructions. The check
/// runs then, and only a child it accepts is resumed; a refused child is killed
/// and reaped, having run nothing and read nothing. A check after an ordinary
/// start would come too late, the child having already run. A launch without
/// a check is a Foundation `Process`, as before.
///
/// Read the termination only after the exit was reported (see `ClusterProcessExit`).
public final class ClusterChildProcess: @unchecked Sendable {
    private let launch: ClusterWorkerLaunch
    private let standardInput: Pipe, standardOutput: Pipe, standardError: Pipe
    private let foundation = Process()
    private let lock = NSLock()
    private let reaped = DispatchGroup()
    private var spawned: pid_t?
    /// The spawned child has exited and is about to be (or was) reaped: no
    /// signal is sent from then on, as its identifier may soon name another process.
    private var exited = false
    private var status: Int32?

    public init(launch: ClusterWorkerLaunch, standardInput: Pipe, standardOutput: Pipe, standardError: Pipe) {
        self.launch = launch
        self.standardInput = standardInput; self.standardOutput = standardOutput; self.standardError = standardError
        if launch.verifyLaunched == nil {
            foundation.executableURL = launch.executable; foundation.arguments = launch.arguments
            foundation.environment = launch.environment
            foundation.standardInput = standardInput; foundation.standardOutput = standardOutput
            foundation.standardError = standardError
        }
    }

    public var processIdentifier: Int32 {
        launch.verifyLaunched == nil ? foundation.processIdentifier : lock.withLock { spawned ?? 0 }
    }

    /// From the start until the exit has been collected.
    public var isRunning: Bool {
        launch.verifyLaunched == nil ? foundation.isRunning : lock.withLock { spawned != nil && status == nil }
    }

    public var terminationReason: Process.TerminationReason {
        guard launch.verifyLaunched != nil else { return foundation.terminationReason }
        return lock.withLock { status.map { $0 & 0x7f == 0 } ?? true } ? .exit : .uncaughtSignal
    }

    /// The exit status, or the signal that ended the child.
    public var terminationStatus: Int32 {
        guard launch.verifyLaunched != nil else { return foundation.terminationStatus }
        return lock.withLock { status.map { $0 & 0x7f == 0 ? ($0 >> 8) & 0xff : $0 & 0x7f } ?? 0 }
    }

    /// Sends SIGTERM to a child that has not exited.
    public func terminate() {
        guard launch.verifyLaunched != nil else { foundation.terminate(); return }
        _ = signal(SIGTERM)
    }

    /// Starts the child; `onExit` runs once, after it has been reaped. With a
    /// check, a refused child has been killed and reaped (and `onExit` has
    /// run) by the time its error is thrown.
    func run(onExit: @escaping @Sendable () -> Void) throws {
        guard let verify = launch.verifyLaunched else {
            foundation.terminationHandler = { _ in onExit() }
            try foundation.run()
            return
        }
        let pid = try spawnSuspended()
        reaped.enter()
        lock.withLock { spawned = pid }
        // The exit is watched from before the check; without that watch the
        // child could not be signalled safely, so it is not launched.
        let exits = Self.exitWatch(pid), watchError = errno
        Thread.detachNewThread { [self] in collect(pid, exits: exits); onExit() }
        do {
            guard exits != nil else { throw Self.cannotStart(watchError) }
            try verify(pid)
            guard signal(SIGCONT) else { throw ClusterWorkerOwnerError.invalid("The launched child could not be resumed") }
        } catch {
            if exits == nil { _ = Darwin.kill(pid, SIGKILL) } else { _ = signal(SIGKILL) }
            reaped.wait()
            throw error
        }
    }

    /// A kernel queue that reports the child's exit (before it is collected),
    /// or nil when none could be set up. Darwin's `waitid` cannot stand in: it
    /// reports a suspended child as an event even when asked for exits only.
    private static func exitWatch(_ pid: pid_t) -> Int32? {
        let queue = kqueue()
        guard queue >= 0 else { return nil }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: NOTE_EXIT, data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { Darwin.close(queue); return nil }
        return queue
    }

    /// Learns of the exit before collecting the child, so that no signal is
    /// sent once its identifier is free to be used again. Without a watch the
    /// child was killed unchecked and is only collected.
    private func collect(_ pid: pid_t, exits: Int32?) {
        if let exits {
            var event = kevent()
            while kevent(exits, nil, 0, &event, 1, nil) < 0 && errno == EINTR {}
            Darwin.close(exits)
        }
        lock.withLock { exited = true }
        var collected: Int32 = 0
        while waitpid(pid, &collected, 0) < 0 && errno == EINTR {}
        lock.withLock { status = collected }
        reaped.leave()
    }

    private func signal(_ number: Int32) -> Bool {
        lock.withLock {
            guard let spawned, !exited else { return false }
            return Darwin.kill(spawned, number) == 0
        }
    }

    /// The launch's executable, arguments and environment, on the launcher's
    /// pipes, inheriting no other descriptor, every signal at its default
    /// disposition and none blocked, stopped before its first instruction.
    private func spawnSuspended() throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Self.cannotStart(errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw Self.cannotStart(errno) }
        defer { posix_spawnattr_destroy(&attributes) }
        var every = sigset_t(), none = sigset_t()
        sigfillset(&every); sigemptyset(&none)
        let flags = POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        guard posix_spawnattr_setsigdefault(&attributes, &every) == 0, posix_spawnattr_setsigmask(&attributes, &none) == 0,
              posix_spawnattr_setflags(&attributes, Int16(flags)) == 0 else { throw Self.cannotStart(EINVAL) }
        for (pipe, target) in [(standardInput.fileHandleForReading, STDIN_FILENO),
                               (standardOutput.fileHandleForWriting, STDOUT_FILENO),
                               (standardError.fileHandleForWriting, STDERR_FILENO)] {
            guard posix_spawn_file_actions_adddup2(&actions, pipe.fileDescriptor, target) == 0 else { throw Self.cannotStart(EINVAL) }
        }
        let arguments = ([launch.executable.path] + launch.arguments).map { strdup($0) }
        let environment = launch.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (arguments + environment).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, launch.executable.path, &actions, &attributes, arguments + [nil], environment + [nil])
        guard result == 0 else { throw Self.cannotStart(result) }
        return pid
    }

    private static func cannotStart(_ code: Int32) -> ClusterWorkerOwnerError {
        .invalid("The child process could not be started (error \(code))")
    }
}
