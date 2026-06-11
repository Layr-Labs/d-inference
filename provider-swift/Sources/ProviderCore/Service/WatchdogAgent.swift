/// WatchdogAgent -- the crash-recovery watchdog's launchd user agent.
///
/// A second, deliberately tiny launchd agent (`io.darkbloom.watchdog`) separate
/// from the provider service (`LaunchAgent`, `io.darkbloom.provider`). It runs
/// `darkbloom watchdog` once a minute (`StartInterval`); each run is a quick
/// check-and-exit (see `WatchdogPolicy`). Running as a periodic one-shot rather
/// than a long-lived daemon is intentional: if a tick wedges or crashes, launchd
/// simply runs the next one — the watchdog can't itself get stuck.
///
/// Its lifecycle mirrors the provider agent exactly, so the two arm and disarm
/// together:
///   - `darkbloom start`     → install + load both.
///   - `darkbloom stop`      → `bootout` both (plists stay on disk; a reboot
///                             reloads them via RunAtLoad).
///   - `darkbloom stop -u`   → `bootout` + delete both plists.
///
/// `KeepAlive = false` because relaunch cadence is owned by `StartInterval`, not
/// by exit status; `RunAtLoad = true` so it begins guarding immediately on load
/// (and again at login after a reboot); `ProcessType = Background` because it is
/// a low-priority maintenance task, never on the inference hot path.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum WatchdogAgent: Sendable {

    public static let label = "io.darkbloom.watchdog"

    /// How often launchd runs the watchdog one-shot, in seconds.
    public static let checkIntervalSeconds = 60

    // MARK: - Paths

    /// `~/Library/LaunchAgents/io.darkbloom.watchdog.plist`.
    public static func plistPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    /// `~/.darkbloom/watchdog.log` — kept separate from `provider.log` so the
    /// recovery audit trail isn't tangled with serving output.
    public static func logPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/watchdog.log")
    }

    // MARK: - Queries

    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath().path)
    }

    public static func isLoaded() -> Bool {
        LaunchctlControl.printSucceeds(label: label)
    }

    // MARK: - Install & Start

    /// Write the plist and (re)load the watchdog. Idempotent: if already loaded
    /// it is booted out first so plist changes are picked up.
    public static func installAndStart() throws {
        let binaryPath = LaunchctlControl.currentExecutablePath()

        if isLoaded() {
            try bootout()
            Thread.sleep(forTimeInterval: 0.2)
        }

        try writePlist(binaryPath: binaryPath)
        try loadService()
    }

    // MARK: - Stop & Uninstall

    /// Unload the watchdog (no-op if not loaded). Leaves the plist on disk.
    public static func stop() throws {
        if isLoaded() {
            try bootout()
        }
    }

    /// Unload and delete the plist.
    public static func uninstall() throws {
        try stop()
        let path = plistPath()
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    // MARK: - Plist

    private static func writePlist(binaryPath: String) throws {
        let plist = plistPath()
        try FileManager.default.createDirectory(
            at: plist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plistDict = makeWatchdogPlist(
            label: label,
            programArguments: [binaryPath, "watchdog"],
            logPath: logPath().path,
            intervalSeconds: checkIntervalSeconds
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        )
        try data.write(to: plist, options: .atomic)
    }

    /// Build the watchdog plist dictionary. Pure (no I/O) so its shape is
    /// unit-testable.
    static func makeWatchdogPlist(
        label: String,
        programArguments: [String],
        logPath: String,
        intervalSeconds: Int
    ) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": programArguments,
            "StartInterval": intervalSeconds,
            "RunAtLoad": true,
            // Cadence is owned by StartInterval; do not relaunch on exit.
            "KeepAlive": false,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "ProcessType": "Background",
        ]
    }

    // MARK: - launchctl

    private static func loadService() throws {
        let bootstrap = LaunchctlControl.run(
            ["bootstrap", LaunchctlControl.guiDomain(), plistPath().path]
        )
        if !bootstrap.succeeded {
            // Error 37 = "already loaded" — benign.
            if !bootstrap.stderr.contains("37:") && !bootstrap.stderr.contains("already loaded") {
                throw WatchdogAgentError.bootstrapFailed(bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // RunAtLoad starts the first tick on bootstrap, but kickstart is
        // harmless and makes a freshly-loaded watchdog run immediately.
        let kickstart = LaunchctlControl.run(["kickstart", LaunchctlControl.target(label: label)])
        if !kickstart.succeeded {
            throw WatchdogAgentError.kickstartFailed(kickstart.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func bootout() throws {
        let result = LaunchctlControl.run(["bootout", LaunchctlControl.target(label: label)])
        if !result.succeeded {
            // Error 3 = "could not find service" — already unloaded, benign.
            if !result.stderr.contains("3:") && !result.stderr.contains("could not find service") {
                throw WatchdogAgentError.bootoutFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

// MARK: - Errors

public enum WatchdogAgentError: Error, CustomStringConvertible, Sendable {
    case bootstrapFailed(String)
    case bootoutFailed(String)
    case kickstartFailed(String)

    public var description: String {
        switch self {
        case .bootstrapFailed(let detail):
            return "watchdog launchctl bootstrap failed: \(detail)"
        case .bootoutFailed(let detail):
            return "watchdog launchctl bootout failed: \(detail)"
        case .kickstartFailed(let detail):
            return "watchdog launchctl kickstart failed: \(detail)"
        }
    }
}
