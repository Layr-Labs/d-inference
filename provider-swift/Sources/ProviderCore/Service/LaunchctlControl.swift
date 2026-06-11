/// LaunchctlControl -- thin shared wrapper over `/bin/launchctl`.
///
/// The provider runs two launchd user agents: the main provider service
/// (`LaunchAgent`, label `io.darkbloom.provider`) and the crash-recovery
/// watchdog (`WatchdogAgent`, label `io.darkbloom.watchdog`). Both need the
/// same low-level plumbing -- build a `gui/<uid>/<label>` target, spawn
/// launchctl, capture its output, and resolve the current executable path.
/// This enum centralises that plumbing so the agents only encode policy
/// (which plist keys to write, which launchctl errors are benign).
///
/// NOTE: `LaunchAgent` deliberately keeps its own bootstrap/bootout/kickstart
/// implementations (proven on the whole fleet) and only borrows
/// `currentExecutablePath()` from here; the watchdog, which is new, is built
/// entirely on these helpers.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum LaunchctlControl {

    /// The current user's GUI launchd domain, e.g. `gui/501`.
    static func guiDomain(uid: uid_t = getuid()) -> String {
        "gui/\(uid)"
    }

    /// A launchd service target, e.g. `gui/501/io.darkbloom.watchdog`.
    static func target(label: String, uid: uid_t = getuid()) -> String {
        "gui/\(uid)/\(label)"
    }

    /// The result of running launchctl: exit status plus captured streams.
    /// `status == -1` means the process could not be spawned at all.
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { status == 0 }
    }

    /// Run `/bin/launchctl <arguments>`, capturing stdout (optional) and stderr.
    ///
    /// Reads the pipes *before* `waitUntilExit()` so a large `launchctl print`
    /// dump can't deadlock by filling the pipe buffer while we wait.
    @discardableResult
    static func run(_ arguments: [String], captureStdout: Bool = false) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let outPipe = captureStdout ? Pipe() : nil
        let errPipe = Pipe()
        process.standardOutput = outPipe ?? FileHandle.nullDevice
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: "", stderr: "could not run launchctl: \(error.localizedDescription)")
        }

        let outData = outPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Output(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Whether `launchctl print <target>` exits 0 — i.e. the job is registered
    /// (loaded) with launchd, whether or not it is currently running.
    static func printSucceeds(label: String, uid: uid_t = getuid()) -> Bool {
        run(["print", target(label: label, uid: uid)]).succeeded
    }

    /// The full `launchctl print <target>` output (and exit status) for liveness
    /// parsing. Output is empty when the job is not loaded (non-zero status).
    static func printOutput(label: String, uid: uid_t = getuid()) -> Output {
        run(["print", target(label: label, uid: uid)], captureStdout: true)
    }

    /// Resolve the path of the running executable. Falls back to the canonical
    /// install location (`~/.darkbloom/bin/darkbloom`) if introspection fails so
    /// a plist we write always points somewhere plausible.
    static func currentExecutablePath() -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var size = UInt32(MAXPATHLEN)
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            if let resolved = realpath(buffer, nil) {
                defer { free(resolved) }
                return String(cString: resolved)
            }
            return String(cString: buffer)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/bin/darkbloom")
            .path
    }
}
