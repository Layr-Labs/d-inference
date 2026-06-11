/// LaunchAgent -- launchd user agent management for the Darkbloom provider.
///
/// The provider only runs when the user explicitly starts it via
/// `darkbloom start` or the macOS app's "Go Online" toggle.
/// It does NOT auto-start on login or auto-restart after crashes.
/// The user is always in control of when their GPU is being used.

import Foundation

public enum LaunchAgent: Sendable {

    public static let label = "io.darkbloom.provider"
    private static let legacyLabels = ["dev.darkbloom.provider"]

    // MARK: - Paths

    /// Path to the launchd plist: ~/Library/LaunchAgents/io.darkbloom.provider.plist
    public static func plistPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    /// Path to the provider log file: ~/.darkbloom/provider.log
    public static func logPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/provider.log")
    }

    // MARK: - In-place policy refresh

    /// Surgically refresh the KeepAlive policy in the EXISTING on-disk plist.
    ///
    /// The crash-recovery KeepAlive={SuccessfulExit:false} only ships in plists
    /// written by `darkbloom start` — auto-update restarts via `kickstart -k`
    /// (which never re-reads the file) and login/reboot re-bootstrap whatever
    /// file is on disk. Without this, the existing fleet would NEVER gain crash
    /// recovery. Called at serve startup: rewrites ONLY the KeepAlive key in
    /// place (preserving ProgramArguments/env customizations) so the policy
    /// takes effect at the next bootstrap. Deliberately does NOT bootout/
    /// re-bootstrap — that would kill the running provider; the file change is
    /// inert until launchd next loads it.
    ///
    /// Returns true if any file was updated, false if absent/already current.
    /// Best-effort: failures are logged by the caller, never fatal.
    ///
    /// Also refreshes plists installed under the supported LEGACY labels:
    /// `restart()`/`stop()` keep legacy-label installs running, so a machine
    /// that never re-ran `darkbloom start` since the rename still boots from
    /// the legacy plist — without this it would never gain crash recovery.
    @discardableResult
    public static func syncKeepAlivePolicyOnDisk() throws -> Bool {
        var updated = try syncKeepAlivePolicy(at: plistPath())
        let agentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        for legacyLabel in legacyLabels {
            let legacyPath = agentsDir.appendingPathComponent("\(legacyLabel).plist")
            if try syncKeepAlivePolicy(at: legacyPath) {
                updated = true
            }
        }
        return updated
    }

    /// Path-injectable core of `syncKeepAlivePolicyOnDisk` (separated for tests).
    @discardableResult
    static func syncKeepAlivePolicy(at path: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return false // not a launchd install (foreground/terminal serve)
        }
        let data = try Data(contentsOf: path)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format
        ) as? [String: Any] else {
            return false
        }
        if let keepAlive = plist["KeepAlive"] as? [String: Bool],
           keepAlive["SuccessfulExit"] == false {
            return false // already current
        }
        plist["KeepAlive"] = ["SuccessfulExit": false]
        let updated = try PropertyListSerialization.data(
            fromPropertyList: plist, format: format, options: 0
        )
        try updated.write(to: path, options: .atomic)
        return true
    }

    // MARK: - Queries

    /// Whether the plist file exists on disk.
    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath().path)
    }

    /// Whether the launchd service is currently loaded (registered with launchd).
    public static func isLoaded() -> Bool {
        isLoaded(label: label)
    }

    /// Whether any supported launchd label is currently loaded. Prefer this for
    /// process-lifecycle decisions where legacy installations should still be
    /// treated as launchd-managed.
    public static func isAnySupportedLabelLoaded() -> Bool {
        if isLoaded() { return true }
        return legacyLabels.contains { isLoaded(label: $0) }
    }

    private static func isLoaded(label: String) -> Bool {
        let target = "gui/\(getuid())/\(label)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Install & Start

    /// Write the plist, load the service, and kickstart the process.
    ///
    /// If the service is already loaded it is unloaded first to pick up
    /// any plist changes. The plist is written with:
    ///   - KeepAlive = false (no auto-restart on crash; avoids racing the updater)
    ///   - RunAtLoad = true (auto-start when the GUI session loads, i.e. at login —
    ///     at boot on an auto-login box — so a rebooted provider re-attests via APNs
    ///     without a manual `darkbloom start`)
    ///   - ProcessType = Interactive (high priority for real-time inference)
    ///   - Nice = -5 (slight scheduling boost)
    ///
    /// - Parameters:
    ///   - coordinatorURL: WebSocket URL for the coordinator (ws:// or wss://).
    ///   - models: Model IDs to serve (passed as --model flags to `serve`).
    ///   - idleTimeout: Optional idle timeout in minutes (passed as --idle-timeout).
    /// Options for the unified local OpenAI endpoint (serve the public fleet AND
    /// a local endpoint off the same loaded models). `enabled == false` keeps the
    /// daemon coordinator-only.
    public struct LocalEndpointOptions: Sendable {
        public let enabled: Bool
        public let port: UInt16
        public let bind: String
        public let noAuth: Bool
        public init(enabled: Bool = false, port: UInt16 = 8000, bind: String = "127.0.0.1", noAuth: Bool = false) {
            self.enabled = enabled
            self.port = port
            self.bind = bind
            self.noAuth = noAuth
        }
    }

    public static func installAndStart(
        coordinatorURL: String,
        models: [String] = [],
        idleTimeout: UInt64? = nil,
        localEndpoint: LocalEndpointOptions = LocalEndpointOptions()
    ) throws {
        // Determine the binary path (current executable)
        let binaryPath = currentExecutablePath()

        // If already loaded, unload first so we pick up plist changes.
        if isLoaded() {
            try unloadService()
            Thread.sleep(forTimeInterval: 0.5)
        }
        for legacyLabel in legacyLabels where isLoaded(label: legacyLabel) {
            try unloadService(label: legacyLabel)
        }

        try writePlist(
            binaryPath: binaryPath,
            coordinatorURL: coordinatorURL,
            models: models,
            idleTimeout: idleTimeout,
            localEndpoint: localEndpoint
        )
        try loadService()
    }

    // MARK: - Stop

    /// Stop the provider by unloading the launchd agent.
    ///
    /// If the service is not loaded this is a no-op.
    public static func stop() throws {
        if isLoaded() {
            try unloadService()
        }
        for legacyLabel in legacyLabels where isLoaded(label: legacyLabel) {
            try unloadService(label: legacyLabel)
        }
    }

    // MARK: - Restart

    /// Restart the provider in place, preserving the current model selection.
    ///
    /// This re-runs the EXISTING launchd plist (same coordinator URL and
    /// `--model` flags) — it never rewrites the plist or shows the model
    /// picker. Behaviour by state:
    ///   - loaded:    `launchctl kickstart -k` kills the running instance and
    ///                immediately relaunches it from the plist's ProgramArguments.
    ///   - installed: (plist on disk but not loaded) bootstrap + kickstart.
    ///   - neither:   throws — there is nothing to restart.
    public static func restart() throws {
        // Canonical label first.
        if isLoaded() {
            try kickstartInPlace(label: label)
            return
        }
        // An upgraded machine may still be running under a legacy label; bounce
        // whichever is actually loaded. Mirrors `stop()`/`installAndStart()`,
        // which both iterate `legacyLabels`, so `restart` can preserve a running
        // provider that hasn't been migrated to the current label yet.
        for legacyLabel in legacyLabels where isLoaded(label: legacyLabel) {
            try kickstartInPlace(label: legacyLabel)
            return
        }
        if isInstalled() {
            // Plist exists but the service isn't loaded — load + kickstart it.
            try loadService()
            return
        }
        throw LaunchAgentError.notInstalled
    }

    /// `launchctl kickstart -k gui/<uid>/<label>` — restart the already-loaded
    /// service in place. The `-k` flag kills the current instance before
    /// relaunching it from the existing plist.
    private static func kickstartInPlace(label serviceLabel: String) throws {
        let target = "gui/\(getuid())/\(serviceLabel)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", target]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            // Error 3 = "could not find service": the service vanished between
            // the isLoaded() check and here. Fall back to a fresh load.
            if stderr.contains("3:") || stderr.contains("could not find service") {
                try loadService()
                return
            }
            throw LaunchAgentError.kickstartFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Uninstall

    /// Completely remove the service: unload + delete plist.
    public static func uninstall() throws {
        try stop()
        let path = plistPath()
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    // MARK: - Private

    /// Env vars passed through from the installing shell into the launchd plist's
    /// `EnvironmentVariables`. Kept to a small allowlist so the daemon's
    /// environment stays predictable; only non-empty values are forwarded.
    static let passthroughEnvKeys = ["DARKBLOOM_PREFIX_CACHE"]

    /// Build the daemon `EnvironmentVariables` map from a source environment,
    /// keeping only the allowlisted, non-empty keys. Pure (environment injected)
    /// so it is unit-testable without touching the real process environment.
    static func passthroughEnvironment(from environment: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in passthroughEnvKeys {
            if let value = environment[key], !value.isEmpty {
                out[key] = value
            }
        }
        return out
    }

    private static func writePlist(
        binaryPath: String,
        coordinatorURL: String,
        models: [String],
        idleTimeout: UInt64?,
        localEndpoint: LocalEndpointOptions = LocalEndpointOptions()
    ) throws {
        let plist = plistPath()
        let parentDir = plist.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true
        )

        let log = logPath().path

        // Build the ProgramArguments array.
        var programArguments: [String] = [
            binaryPath,
            "start",
            "--foreground",
            "--coordinator-url",
            coordinatorURL,
        ]
        for model in models {
            programArguments.append("--model")
            programArguments.append(model)
        }
        if let timeout = idleTimeout {
            programArguments.append("--idle-timeout")
            programArguments.append("\(timeout)")
        }
        if localEndpoint.enabled {
            programArguments.append("--local-endpoint")
            programArguments.append(contentsOf: ["--port", "\(localEndpoint.port)"])
            programArguments.append(contentsOf: ["--bind", localEndpoint.bind])
            if localEndpoint.noAuth {
                programArguments.append("--no-auth")
            }
        }

        let plistDict = makeServicePlist(
            label: label,
            programArguments: programArguments,
            logPath: log,
            environment: ProcessInfo.processInfo.environment
        )

        let data = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        )
        try data.write(to: plist, options: .atomic)
    }

    /// Build the launchd plist dictionary for the provider service. Pure (no I/O)
    /// so the auto-start and environment-passthrough behavior is unit-testable.
    ///
    /// `RunAtLoad = true`: launchd starts the provider as soon as the GUI session
    /// loads the agent — i.e. at login, which on an auto-login box is at boot. This
    /// is what lets a rebooted/power-cycled provider come back and re-attest via
    /// APNs with no human running `darkbloom start`. (APNs registration needs the
    /// GUI/Aqua session, which a gui-domain LaunchAgent already runs in.)
    ///
    /// `KeepAlive = { SuccessfulExit = false }`: relaunch only on ABNORMAL exit
    /// (crash/panic/OOM-kill) — crash-recovery the old `KeepAlive=false` lacked.
    /// The intentional teardowns don't race it: `stop`/uninstall is a `bootout`
    /// (removes the job) and self-update is `kickstart -k` (atomic restart;
    /// binary is swapped while still running).
    ///
    /// PROPAGATION: nothing rewrites an existing install's plist by itself —
    /// self-update is `kickstart -k` (doesn't re-read the file) and login/reboot
    /// re-bootstrap the OLD on-disk file. `syncKeepAlivePolicyOnDisk` (called at
    /// serve startup) refreshes the FILE in place so the policy takes effect at
    /// the next bootstrap; only a fresh `darkbloom start` regenerates the whole
    /// plist.
    static func makeServicePlist(
        label: String,
        programArguments: [String],
        logPath: String,
        environment: [String: String]
    ) -> [String: Any] {
        var plistDict: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            // Restart only on abnormal exit; clean bootout (stop) stays stopped.
            "KeepAlive": ["SuccessfulExit": false],
            "RunAtLoad": true,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "ProcessType": "Interactive",
            "Nice": -5,
        ]

        // launchd does NOT inherit the installing shell's environment, so any
        // opt-out the operator set (e.g. DARKBLOOM_PREFIX_CACHE=0 to disable the
        // on-by-default encrypted SSD KV cache) would be silently ignored by the
        // daemon. Persist the allowlisted passthrough vars into the plist so the
        // operator actually has a per-machine off switch.
        let environmentVariables = passthroughEnvironment(from: environment)
        if !environmentVariables.isEmpty {
            plistDict["EnvironmentVariables"] = environmentVariables
        }

        return plistDict
    }

    private static func loadService() throws {
        let path = plistPath()
        let domain = "gui/\(getuid())"

        // Bootstrap registers the service with launchd.
        let bootstrap = Process()
        bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootstrap.arguments = ["bootstrap", domain, path.path]

        let errPipe = Pipe()
        bootstrap.standardOutput = FileHandle.nullDevice
        bootstrap.standardError = errPipe

        try bootstrap.run()
        bootstrap.waitUntilExit()

        if bootstrap.terminationStatus != 0 {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            // Error 37 = "already loaded" -- not a real failure.
            if !stderr.contains("37:") && !stderr.contains("already loaded") {
                throw LaunchAgentError.bootstrapFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // With RunAtLoad=false, bootstrap registers the service but doesn't
        // start it. Kickstart actually launches the process. After a successful
        // bootstrap the service exists, so kickstart should return 0 — surface a
        // non-zero exit (or a spawn failure) rather than silently reporting
        // success when launchd never launched the process.
        let target = "gui/\(getuid())/\(label)"
        let kickstart = Process()
        kickstart.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kickstart.arguments = ["kickstart", target]
        let kickstartErr = Pipe()
        kickstart.standardOutput = FileHandle.nullDevice
        kickstart.standardError = kickstartErr

        do {
            try kickstart.run()
        } catch {
            throw LaunchAgentError.kickstartFailed("could not run launchctl kickstart: \(error.localizedDescription)")
        }
        kickstart.waitUntilExit()

        if kickstart.terminationStatus != 0 {
            let stderr = String(
                data: kickstartErr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw LaunchAgentError.kickstartFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func unloadService(label serviceLabel: String = LaunchAgent.label) throws {
        let target = "gui/\(getuid())/\(serviceLabel)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", target]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            // Error 3 = "could not find service" -- already unloaded, not an error.
            if !stderr.contains("3:") && !stderr.contains("could not find service") {
                throw LaunchAgentError.bootoutFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// Resolve the current executable path. Falls back to ~/.darkbloom/bin/darkbloom.
    private static func currentExecutablePath() -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var size = UInt32(MAXPATHLEN)
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            if let resolved = realpath(buffer, nil) {
                defer { free(resolved) }
                return String(cString: resolved)
            }
            return String(cString: buffer)
        }
        // Fallback
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom/bin/darkbloom")
            .path
    }

}

// MARK: - Errors

public enum LaunchAgentError: Error, CustomStringConvertible, Sendable {
    case bootstrapFailed(String)
    case bootoutFailed(String)
    case kickstartFailed(String)
    case notInstalled

    public var description: String {
        switch self {
        case .bootstrapFailed(let detail):
            return "launchctl bootstrap failed: \(detail)"
        case .bootoutFailed(let detail):
            return "launchctl bootout failed: \(detail)"
        case .kickstartFailed(let detail):
            return "launchctl kickstart failed: \(detail)"
        case .notInstalled:
            return "provider service is not installed; run `darkbloom start` first"
        }
    }
}
