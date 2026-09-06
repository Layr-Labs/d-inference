/// Shared `/bin/launchctl` plumbing for the provider's launchd agents
/// (`LaunchAgent`, `WatchdogAgent`) and the watchdog probe: target strings,
/// process spawn + output capture, and managed executable-path persistence.

import Foundation
import ProviderCoreFoundation
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

    /// `launchctl enable|disable gui/$UID/<label>`.
    ///
    /// Unlike `bootout` — which only deregisters the job from the CURRENT login
    /// session — the enabled/disabled state lives in launchd's per-user override
    /// database and PERSISTS across logins and reboots. This is what keeps a
    /// stopped agent stopped after a reboot even though its plist
    /// (RunAtLoad=true) stays in ~/Library/LaunchAgents.
    @discardableResult
    static func setEnabled(_ enabled: Bool, label: String, uid: uid_t = getuid()) -> Output {
        run([enabled ? "enable" : "disable", target(label: label, uid: uid)], captureStderr: true)
    }

    /// `launchctl print` exit-0 check — i.e. the job is loaded.
    static func printSucceeds(label: String, uid: uid_t = getuid()) -> Bool {
        run(["print", target(label: label, uid: uid)]).succeeded
    }

    /// Full `launchctl print` output for liveness parsing.
    static func printOutput(label: String, uid: uid_t = getuid()) -> Output {
        run(["print", target(label: label, uid: uid)], captureStdout: true)
    }

    /// Persist the validated nested managed CLI, or a valid legacy flat CLI.
    /// Reject malformed installs before writing or reloading a LaunchAgent.
    ///
    /// In particular, do not derive this from `_NSGetExecutablePath` or
    /// `realpath`: a CLI started from Downloads or App Translocation would
    /// otherwise survive in a LaunchAgent plist after the source app exits.
    static func managedExecutablePath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> String {
        guard let executable = ManagedProviderCLIPathValidator().validatedCLIURL(
            homeDirectory: homeDirectory
        ) else {
            throw ManagedExecutableUnavailable()
        }
        return executable.path
    }

    struct ManagedExecutableUnavailable: LocalizedError {
        var errorDescription: String? {
            "The managed Darkbloom CLI is missing or has an unsafe path. Reinstall Darkbloom before starting the provider."
        }
    }
}
