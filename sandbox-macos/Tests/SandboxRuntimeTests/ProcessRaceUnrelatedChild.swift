import Darwin
import Foundation

/// Independent kernel child control: no Foundation Process, run loop, app
/// registration, or shared process monitor is involved in this positive control.
final class ProcessRaceUnrelatedChild {
    let identity: ProcessBirthIdentity
    private var reaped = false

    init() throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        guard sigemptyset(&defaults) == 0, sigaddset(&defaults, SIGTERM) == 0,
              sigemptyset(&mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0
        else { throw POSIXError(.EIO) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null",
                descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0 else { throw POSIXError(.EIO) }
        }
        let executable = strdup("/bin/sleep"), duration = strdup("30")
        defer { free(executable); free(duration) }
        guard executable != nil, duration != nil else { throw POSIXError(.ENOMEM) }
        var argv: [UnsafeMutablePointer<CChar>?] = [executable, duration, nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sleep", &actions, &attributes, &argv, &environment)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        guard let identity = ProcessBirthIdentity.read(pid) else {
            _ = kill(pid, SIGKILL)
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            var status: Int32 = 0
            while waitpid(pid, &status, WNOHANG) != pid {
                guard DispatchTime.now().uptimeNanoseconds < deadline else {
                    throw ProcessRaceFixtureError.timedOut
                }
                usleep(1_000)
            }
            throw ProcessRaceFixtureError.identityUnavailable
        }
        self.identity = identity
    }

    func stop() throws {
        guard !reaped else { return }
        if try collectIfExited() { return }
        // This direct child has not been reaped, so its PID remains reserved.
        guard kill(identity.pid, SIGTERM) == 0 || errno == ESRCH else { throw POSIXError(.EIO) }
        if try awaitExit(seconds: 1) { return }
        guard kill(identity.pid, SIGKILL) == 0 || errno == ESRCH else { throw POSIXError(.EIO) }
        guard try awaitExit(seconds: 1) else { throw ProcessRaceFixtureError.timedOut }
    }

    private func collectIfExited() throws -> Bool {
        var status: Int32 = 0
        while true {
            let result = waitpid(identity.pid, &status, WNOHANG)
            if result == identity.pid { reaped = true; return true }
            if result == 0 { return false }
            if errno == EINTR { continue }
            throw ProcessRaceFixtureError.childWaitFailed
        }
    }

    private func awaitExit(seconds: Double) throws -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        repeat {
            if try collectIfExited() { return true }
            usleep(1_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return false
    }
}
