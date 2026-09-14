import Darwin
import Foundation

/// Independent, bounded outer broker control. The inner probe uses the real
/// process runner, so this fixture must not share its monitor or cancellation.
final class ManagedProcessBrokerFixture {
    private let pid: pid_t
    private var reaped = false
    private var exitCode: Int32?

    init(executable: URL, directory: URL, mode: String? = nil) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        guard sigemptyset(&defaults) == 0, sigaddset(&defaults, SIGTERM) == 0, sigaddset(&defaults, SIGINT) == 0,
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
        let strings = [executable.path] + (mode.map { [$0] } ?? []) + [directory.path]
        let allocated = strings.map { strdup($0) }
        let path = strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin")
        defer { allocated.forEach { free($0) }; free(path) }
        guard allocated.allSatisfy({ $0 != nil }), path != nil else { throw POSIXError(.ENOMEM) }
        var argv: [UnsafeMutablePointer<CChar>?] = allocated + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [path, nil]
        var child: pid_t = 0
        let result = posix_spawn(&child, executable.path, &actions, &attributes, &argv, &environment)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        pid = child
    }

    func killAndWait() throws {
        guard !reaped else { return }
        if try collectIfExited() { return }
        // The direct child is unreaped, so the kernel still reserves this PID.
        guard kill(pid, SIGKILL) == 0 || errno == ESRCH else { throw POSIXError(.EIO) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        repeat {
            if try collectIfExited() { return }
            usleep(1_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        throw POSIXError(.ETIMEDOUT)
    }

    func send(signal: Int32) throws {
        guard !reaped, try !collectIfExited() else { throw POSIXError(.ESRCH) }
        // No reaper runs concurrently; this direct child's PID remains reserved.
        guard kill(pid, signal) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func waitForExit() throws -> Int32 {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !reaped, DispatchTime.now().uptimeNanoseconds < deadline {
            if try collectIfExited() { break }
            usleep(1_000)
        }
        guard let exitCode else { throw POSIXError(.ETIMEDOUT) }
        return exitCode
    }

    private func collectIfExited() throws -> Bool {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                reaped = true
                let signal = status & 0x7f
                exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
                return true
            }
            if result == 0 { return false }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
