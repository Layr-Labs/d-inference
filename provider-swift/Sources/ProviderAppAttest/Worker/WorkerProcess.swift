import Darwin
import Foundation

/// A posix_spawn child remains ours until waitpid reaps it. All exit observation
/// and signalling share one lock; no cached PID can signal a reused process.
final class WorkerProcess: @unchecked Sendable {
    let pid: pid_t
    private let lock = NSLock()
    private var reaped = false
    private var qualificationSuspended = false

    private init(pid: pid_t) { self.pid = pid }

    static func spawn(executable: URL, arguments: [String]) throws -> (WorkerProcess, WorkerDescriptor) {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { throw AppAttestWorkerError.systemFailure }
        // Keep source descriptors above the fixed child fd and stdio slots.
        let readFD = fcntl(pipeFDs[0], F_DUPFD_CLOEXEC, 4)
        let writeFD = fcntl(pipeFDs[1], F_DUPFD_CLOEXEC, 4)
        close(pipeFDs[0]); close(pipeFDs[1])
        guard readFD >= 0, writeFD >= 0 else {
            if readFD >= 0 { close(readFD) }; if writeFD >= 0 { close(writeFD) }
            throw AppAttestWorkerError.systemFailure
        }
        let input = WorkerDescriptor(readFD), output = WorkerDescriptor(writeFD)
        try WorkerDescriptor.configure(writeFD)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw AppAttestWorkerError.systemFailure }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AppAttestWorkerError.systemFailure }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t()
        var defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawn_file_actions_adddup2(&actions, input.fd, 3) == 0,
              posix_spawn_file_actions_addclose(&actions, input.fd) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 else {
            throw AppAttestWorkerError.systemFailure
        }
        let argv = ([executable.path] + arguments).map { value in value.withCString { strdup($0)! } }
        // No auth tokens, loader overrides, inherited service descriptors or
        // configuration flags. The child keeps its parent's OS security session.
        let environment = ["PATH=/usr/bin:/bin", "HOME=\(NSHomeDirectory())"].map { value in value.withCString { strdup($0)! } }
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var argvPointers = argv.map(Optional.some) + [nil]
        var envPointers = environment.map(Optional.some) + [nil]
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable.path, &actions, &attributes, &argvPointers, &envPointers) == 0 else {
            throw AppAttestWorkerError.systemFailure
        }
        return (Self(pid: pid), output)
    }

    func requireAlive() throws {
        try lock.withLock {
            guard !observeExitLocked() else { throw AppAttestWorkerError.connectionClosed }
        }
    }

    func terminateAndReap(graceSeconds: Double = 2, killSeconds: Double = 2) throws {
        try lock.withLock {
            if observeExitLocked() { return }
            _ = kill(pid, SIGTERM)
            if waitLocked(seconds: graceSeconds) { return }
            _ = kill(pid, SIGKILL)
            guard waitLocked(seconds: killSeconds) else { throw AppAttestWorkerError.childWouldNotExit }
        }
    }

    /// Shares the waitpid/signalling lock. Even if this child exits between the
    /// status read and kill, it cannot be reaped and its PID reused underneath us.
    func suspendOwnedWorkerForQualification() throws {
        try lock.withLock {
            guard !observeExitLocked() else { throw AppAttestWorkerError.connectionClosed }
            guard !qualificationSuspended else { throw AppAttestWorkerError.busy }
            let status = try statusLocked()
            guard status == UInt32(SRUN) || status == UInt32(SSLEEP) else { throw AppAttestWorkerError.busy }
            guard kill(pid, SIGSTOP) == 0 else { throw AppAttestWorkerError.connectionClosed }
            qualificationSuspended = true
            let deadline = WorkerDeadline(seconds: 1)
            while true {
                guard !observeExitLocked() else { throw AppAttestWorkerError.connectionClosed }
                if try statusLocked() == UInt32(SSTOP) { return }
                try deadline.check()
                usleep(1_000)
            }
        }
    }

    private func statusLocked() throws -> UInt32 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_ppid == UInt32(getpid()) else {
            throw AppAttestWorkerError.connectionClosed
        }
        return info.pbi_status
    }

    private func waitLocked(seconds: Double) -> Bool {
        let deadline = WorkerDeadline(seconds: seconds)
        repeat {
            if observeExitLocked() { return true }
            usleep(10_000)
        } while deadline.remaining > 0
        return observeExitLocked()
    }

    private func observeExitLocked() -> Bool {
        if reaped { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        // A traced child can report a stop even without WUNTRACED. Only a
        // terminal status proves exit; treating a stop as exit permits overlap.
        if result == pid, status & 0x7f != 0x7f { reaped = true }
        // No other code may reap this child. ECHILD is not proof that a cached
        // PID is still ours; never signal it after ownership has been lost.
        if result < 0, errno == ECHILD { reaped = true }
        return reaped
    }
}

/// Single native-operation process owner. Even a failed kill keeps the old
/// owner quarantined, so callers cannot spawn overlapping replacements.
final class WorkerProcessSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var process: WorkerProcess?
    private var channel: WorkerDescriptor?
    private var epoch: UInt64 = 0
    private var stopped = false

    deinit { try? cancel(permanently: true) }

    func currentEpoch() throws -> UInt64 {
        try lock.withLock {
            guard !stopped else { throw AppAttestWorkerError.stopped }
            return epoch
        }
    }

    func launch(executable: URL, arguments: [String], bootstrap: Data, epoch expected: UInt64) throws -> WorkerProcess {
        try lock.withLock {
            guard !stopped, epoch == expected, process == nil else { throw AppAttestWorkerError.staleExchange }
            guard bootstrap.count <= 4096 else { throw AppAttestWorkerError.frameTooLarge }
            let (child, input) = try WorkerProcess.spawn(executable: executable, arguments: arguments)
            // Record ownership before the first fallible post-spawn operation.
            // A failed bootstrap AND failed kill must quarantine this child too.
            process = child
            do { try input.write(bootstrap, deadline: WorkerDeadline(seconds: 5)) }
            catch {
                try child.terminateAndReap()
                process = nil
                throw error
            }
            return child
        }
    }

    func attach(_ socket: WorkerDescriptor, epoch expected: UInt64) throws {
        try lock.withLock {
            guard !stopped, epoch == expected, process != nil else { throw AppAttestWorkerError.staleExchange }
            channel = socket
        }
    }

    func suspendOwnedWorkerForQualification(expectedEpoch: UInt64, expectedProcess: WorkerProcess) throws {
        try lock.withLock {
            guard !stopped, epoch == expectedEpoch, let process,
                  process === expectedProcess, channel != nil else { throw AppAttestWorkerError.staleExchange }
            try process.suspendOwnedWorkerForQualification()
        }
    }

    func cancel(permanently: Bool = false, expectedEpoch: UInt64? = nil) throws {
        try lock.withLock {
            if let expectedEpoch, expectedEpoch != epoch { return }
            epoch &+= 1
            stopped = stopped || permanently
            channel?.shutdown()
            if let process { try process.terminateAndReap() }
            process = nil
            channel = nil
        }
    }
}
