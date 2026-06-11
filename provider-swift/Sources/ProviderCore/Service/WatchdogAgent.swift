/// The crash-recovery watchdog's launchd agent (`io.darkbloom.watchdog`),
/// separate from the provider service. Runs `darkbloom watchdog` once a minute
/// (`StartInterval`) as a check-and-exit one-shot, so a wedged tick can't stall
/// recovery. Lifecycle mirrors the provider agent: `start` installs+loads it,
/// `stop` bootouts it (plist stays for reboot), `stop --uninstall` deletes it.

import Foundation

public enum WatchdogAgent: Sendable {

    public static let label = "io.darkbloom.watchdog"
    public static let checkIntervalSeconds = 60

    public static func plistPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    /// `~/.darkbloom/watchdog.log` — kept separate from provider.log.
    public static func logPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/watchdog.log")
    }

    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath().path)
    }

    public static func isLoaded() -> Bool {
        LaunchctlControl.printSucceeds(label: label)
    }

    /// Write the plist and (re)load it; idempotent.
    public static func installAndStart() throws {
        if isLoaded() {
            try bootout()
            Thread.sleep(forTimeInterval: 0.2)
        }
        try writePlist(binaryPath: LaunchctlControl.currentExecutablePath())
        try loadService()
    }

    /// Unload (no-op if not loaded); leaves the plist on disk.
    public static func stop() throws {
        if isLoaded() { try bootout() }
    }

    /// Unload and delete the plist.
    public static func uninstall() throws {
        try stop()
        let path = plistPath()
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private static func writePlist(binaryPath: String) throws {
        let plist = plistPath()
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dict = makeWatchdogPlist(
            label: label,
            programArguments: [binaryPath, "watchdog"],
            logPath: logPath().path,
            intervalSeconds: checkIntervalSeconds
        )
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
    }

    /// Pure plist builder (testable). KeepAlive=false (cadence is StartInterval's
    /// job); RunAtLoad=true (guard immediately + at login); Background priority.
    static func makeWatchdogPlist(label: String, programArguments: [String], logPath: String, intervalSeconds: Int) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": programArguments,
            "StartInterval": intervalSeconds,
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "ProcessType": "Background",
        ]
    }

    private static func loadService() throws {
        let bootstrap = LaunchctlControl.run(["bootstrap", LaunchctlControl.guiDomain(), plistPath().path], captureStderr: true)
        // Error 37 = "already loaded" — benign.
        if !bootstrap.succeeded, !bootstrap.stderr.contains("37:"), !bootstrap.stderr.contains("already loaded") {
            throw WatchdogAgentError.bootstrapFailed(bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // RunAtLoad already started it; this kickstart is belt-and-suspenders.
        let kickstart = LaunchctlControl.run(["kickstart", LaunchctlControl.target(label: label)], captureStderr: true)
        if !kickstart.succeeded {
            throw WatchdogAgentError.kickstartFailed(kickstart.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func bootout() throws {
        let result = LaunchctlControl.run(["bootout", LaunchctlControl.target(label: label)], captureStderr: true)
        // Error 3 = "could not find service" — already unloaded, benign.
        if !result.succeeded, !result.stderr.contains("3:"), !result.stderr.contains("could not find service") {
            throw WatchdogAgentError.bootoutFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

public enum WatchdogAgentError: Error, CustomStringConvertible, Sendable {
    case bootstrapFailed(String)
    case bootoutFailed(String)
    case kickstartFailed(String)

    public var description: String {
        switch self {
        case .bootstrapFailed(let d): return "watchdog launchctl bootstrap failed: \(d)"
        case .bootoutFailed(let d): return "watchdog launchctl bootout failed: \(d)"
        case .kickstartFailed(let d): return "watchdog launchctl kickstart failed: \(d)"
        }
    }
}
