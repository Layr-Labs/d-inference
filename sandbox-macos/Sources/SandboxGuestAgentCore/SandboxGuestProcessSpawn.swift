import Darwin
import Foundation

/// Spawns a guest command in its own process group.
///
/// The process group matters: a deadline must be able to kill everything the
/// command started, not just the direct child. `POSIX_SPAWN_CLOEXEC_DEFAULT`
/// means only the descriptors explicitly wired below survive `exec`, so a
/// command cannot inherit the agent's channel.
enum SandboxGuestProcessSpawn {
    enum SpawnError: Error, CustomStringConvertible {
        case fileActions
        case attributes
        case spawn(Int32)

        var description: String {
            switch self {
            case .fileActions:
                return "could not configure spawned process descriptors"
            case .attributes:
                return "could not configure spawned process attributes"
            case .spawn(let code):
                return "posix_spawn failed (\(code))"
            }
        }
    }

    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        standardOutput: Int32,
        standardError: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw SpawnError.fileActions
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let steps: [Int32] = [
            posix_spawn_file_actions_addopen(
                &actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0
            ),
            posix_spawn_file_actions_adddup2(&actions, standardOutput, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, standardError, STDERR_FILENO),
        ]
        guard steps.allSatisfy({ $0 == 0 }) else {
            throw SpawnError.fileActions
        }
        guard workingDirectory.withCString({
            posix_spawn_file_actions_addchdir_np(&actions, $0)
        }) == 0 else {
            throw SpawnError.fileActions
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw SpawnError.attributes
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP)
            | Int16(bitPattern: UInt16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw SpawnError.attributes
        }

        let argv: [UnsafeMutablePointer<CChar>?] =
            arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            environment
            .sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
            for pointer in envp where pointer != nil { free(pointer) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw SpawnError.spawn(status)
        }
        return pid
    }

    /// Kills the command and everything it started.
    ///
    /// The group signal is the one that reaches grandchildren; the direct
    /// signal is a cheap backstop in case the child managed to join another
    /// group.
    static func killProcessGroup(_ pid: pid_t) {
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    /// Blocking reap. Safe only once the process is known to be dying.
    ///
    /// Returns `nil` when the child cannot be reaped, which must never be
    /// flattened into a zero status: that would decode as a clean exit 0.
    static func wait(for pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result < 0 {
                if errno == EINTR { continue }
                return nil
            }
            return status
        }
    }

    /// `WIFEXITED` / `WEXITSTATUS` / `WTERMSIG` are C macros with no Swift
    /// equivalent, so the wait status is decoded by hand.
    static func exitCode(from status: Int32) -> Int32 {
        let terminatingSignal = status & 0x7F
        if terminatingSignal == 0 {
            return (status >> 8) & 0xFF
        }
        // Signalled: report the shell convention, clamped into the legal range
        // the result envelope allows.
        return min(128 + terminatingSignal, 255)
    }
}
