import Darwin
import Foundation

/// Reads device profiles through a narrowly scoped sudo command while sudo
/// remains in the caller's foreground process group. Foundation.Process creates
/// a separate group on macOS, which stops an interactive child on SIGTTIN.
enum ProfileInventoryAuthorization {
    static func readAuthenticatedProfiles(arguments: [String]) -> Data? {
        return runInCurrentProcessGroup(
            executable: "/usr/bin/sudo",
            arguments: ["--", "/usr/bin/profiles"] + arguments)
    }

    /// Internal PTY-test seam. Production uses only the fixed sudo/profiles
    /// path and arguments; no shell or password handling enters this process.
    static func runInCurrentProcessGroup(executable: String, arguments: [String]) -> Data? {
        // A background job still has a TTY, but terminal reads stop it with
        // SIGTTIN. Withhold guidance before launching an interactive child.
        guard isatty(STDIN_FILENO) != 0,
              tcgetpgrp(STDIN_FILENO) == getpgrp() else { return nil }
        var descriptors = [Int32](repeating: 0, count: 2)
        guard pipe(&descriptors) == 0 else { return nil }
        defer { close(descriptors[0]) }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(descriptors[1]); return nil
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0,
              posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO) == 0,
              posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO) == 0 else {
            close(descriptors[1]); return nil
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            close(descriptors[1]); return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }
        // The CLI may hold unrelated files or sockets. Only the terminal and
        // captured XML output are inherited by the privileged read command.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            close(descriptors[1]); return nil
        }

        let strings = ([executable] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else {
            close(descriptors[1]); return nil
        }
        var argv = strings + [nil]
        var pid: pid_t = 0
        // No process-group flag is set, so the child stays in the foreground group.
        // sudo owns echo and terminal input; only stdout is captured for XML.
        let spawned = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, executable, &actions, &attributes, buffer.baseAddress!, environ)
        }
        close(descriptors[1])
        guard spawned == 0 else { return nil }

        let output = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: false).readDataToEndOfFile()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return nil }
        }
        // A signal, stopped child or nonzero exit withholds removal guidance.
        guard (status & 0x7f) == 0, ((status >> 8) & 0xff) == 0 else { return nil }
        return output
    }
}
