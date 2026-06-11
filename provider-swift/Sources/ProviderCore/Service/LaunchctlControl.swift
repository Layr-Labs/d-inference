/// Shared `/bin/launchctl` plumbing for the provider's launchd agents
/// (`LaunchAgent`, `WatchdogAgent`) and the watchdog probe: target strings,
/// process spawn + output capture, and executable-path resolution.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum LaunchctlControl {

    static func guiDomain(uid: uid_t = getuid()) -> String { "gui/\(uid)" }
    static func target(label: String, uid: uid_t = getuid()) -> String { "gui/\(uid)/\(label)" }

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { status == 0 }
    }

    /// Run launchctl, capturing at most one stream (enforced): draining two
    /// pipes sequentially can deadlock once the unread one fills.
    @discardableResult
    static func run(_ arguments: [String], captureStdout: Bool = false, captureStderr: Bool = false) -> Output {
        precondition(!(captureStdout && captureStderr), "capture at most one stream")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let outPipe = captureStdout ? Pipe() : nil
        let errPipe = captureStderr ? Pipe() : nil
        process.standardOutput = outPipe ?? FileHandle.nullDevice
        process.standardError = errPipe ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Output(status: -1, stdout: "", stderr: "could not run launchctl: \(error.localizedDescription)")
        }
        let outData = outPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let errData = errPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// `launchctl print` exit-0 check — i.e. the job is loaded.
    static func printSucceeds(label: String, uid: uid_t = getuid()) -> Bool {
        run(["print", target(label: label, uid: uid)]).succeeded
    }

    /// Full `launchctl print` output for liveness parsing.
    static func printOutput(label: String, uid: uid_t = getuid()) -> Output {
        run(["print", target(label: label, uid: uid)], captureStdout: true)
    }

    /// Path of the running executable; falls back to the canonical install path.
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
            .appendingPathComponent(".darkbloom/bin/darkbloom").path
    }
}
