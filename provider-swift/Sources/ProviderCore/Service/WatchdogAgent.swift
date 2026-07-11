/// The crash-recovery watchdog's launchd agent (`io.darkbloom.watchdog`),
/// separate from the provider service. It keeps one lightweight
/// `darkbloom watchdog` process alive; that process owns a monotonic timer.
/// Lifecycle mirrors the provider agent: `start` installs+loads it
/// (re-enabling any persistent disable), `stop` bootouts it AND persistently
/// disables it so KeepAlive/RunAtLoad can't resurrect it at the next
/// login/reboot (plist stays on disk), `stop --uninstall` deletes it.
///
/// KNOWN LIMITATION (threat model T-043): the agent runs the SAME replaceable
/// `darkbloom` binary it recovers. Rollback protection therefore depends on
/// the pre-update watchdog process surviving a candidate's stabilization
/// window; after a reboot, launchd relaunches the watchdog FROM the candidate
/// binary, so a candidate broken at the binary level (dyld/codesign/eager
/// crash before command dispatch) cannot be rolled back by this mechanism.
/// A truly independent recovery authority requires a separately installed
/// bootstrap executable outside the replaceable install tree.

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

    /// The `--config` path recorded in the installed watchdog plist, if any.
    /// Re-arm paths (`darkbloom restart`) use this so rewriting the plist
    /// cannot silently drop a custom config the operator installed with.
    public static func installedConfigPath() -> URL? {
        guard let data = try? Data(contentsOf: plistPath()),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else {
            return nil
        }
        return configPathArgument(in: arguments)
    }

    /// Pure parser for the watchdog `ProgramArguments` config flag.
    static func configPathArgument(in arguments: [String]) -> URL? {
        for (index, argument) in arguments.enumerated()
        where argument == "--config" || argument == "-c" {
            guard index + 1 < arguments.count else { return nil }
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return nil
    }

    /// The config path a re-arm should install with: an explicit override
    /// wins; otherwise the already-installed plist's config is preserved.
    public static func rearmConfigPath(
        explicit: String?,
        installed: URL?
    ) -> URL? {
        if let explicit {
            return URL(
                fileURLWithPath: (explicit as NSString).expandingTildeInPath
            )
        }
        return installed
    }

    public enum RearmAction: Sendable, Equatable {
        case arm
        case disarm
    }

    /// What an arming site (`start`, `restart`) should do with the watchdog
    /// job. `auto_restart = false` DISARMS a previously loaded watchdog rather
    /// than leaving it running on its old plist config — otherwise a host
    /// whose operator switched to an opted-out config would still get
    /// watchdog-driven relaunches from the stale job.
    public static func rearmAction(
        autoRestartEnabled: Bool,
        isLoaded: Bool
    ) -> RearmAction? {
        if autoRestartEnabled { return .arm }
        return isLoaded ? .disarm : nil
    }

    public static func isLoaded() -> Bool {
        LaunchctlControl.printSucceeds(label: label)
    }

    /// Write the plist and (re)load it; idempotent.
    public static func installAndStart(
        configPath: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        if isLoaded() {
            try bootout()
            Thread.sleep(forTimeInterval: 0.2)
        }
        try writePlist(
            binaryPath: LaunchctlControl.currentExecutablePath(),
            configPath: configPath,
            environment: environment
        )
        try loadService()
    }

    /// Unload (no-op if not loaded) and persistently disable, so the plist left
    /// on disk (RunAtLoad=true) cannot resurrect the watchdog at the next
    /// login/reboot. `installAndStart()` re-enables.
    public static func stop() throws {
        if isLoaded() { try bootout() }
        let result = LaunchctlControl.setEnabled(false, label: label)
        if !result.succeeded {
            throw WatchdogAgentError.disableFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private static func writePlist(
        binaryPath: String,
        configPath: URL?,
        environment: [String: String]
    ) throws {
        let plist = plistPath()
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        var arguments = [binaryPath, "watchdog"]
        if let configPath {
            arguments.append(contentsOf: ["--config", configPath.path])
        }
        let dict = makeWatchdogPlist(
            label: label,
            programArguments: arguments,
            logPath: logPath().path,
            environment: environment
        )
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
    }

    static let passthroughEnvKeys = [
        "DARKBLOOM_NO_UPDATE_CHECK",
        "DARKBLOOM_STATE_FILE",
        "DARKBLOOM_WATCHDOG_STATE",
    ]

    static func passthroughEnvironment(
        from environment: [String: String]
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: passthroughEnvKeys.compactMap { key in
            guard let value = environment[key], !value.isEmpty else { return nil }
            return (key, value)
        })
    }

    /// Persistent job: launchd starts it at login and keeps it alive. This
    /// avoids StartInterval jobs being stranded by GUI on-demand-only mode.
    static func makeWatchdogPlist(
        label: String,
        programArguments: [String],
        logPath: String,
        environment: [String: String] = [:]
    ) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "ProcessType": "Background",
        ]
        let passed = passthroughEnvironment(from: environment)
        if !passed.isEmpty {
            plist["EnvironmentVariables"] = passed
        }
        return plist
    }

    private static func loadService() throws {
        // Clear any persistent disable left by `stop()`; best-effort — a real
        // failure surfaces via the bootstrap below.
        LaunchctlControl.setEnabled(true, label: label)
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
    case disableFailed(String)

    public var description: String {
        switch self {
        case .bootstrapFailed(let d): return "watchdog launchctl bootstrap failed: \(d)"
        case .bootoutFailed(let d): return "watchdog launchctl bootout failed: \(d)"
        case .kickstartFailed(let d): return "watchdog launchctl kickstart failed: \(d)"
        case .disableFailed(let d): return "watchdog launchctl disable failed (it may auto-start again at next login): \(d)"
        }
    }
}
