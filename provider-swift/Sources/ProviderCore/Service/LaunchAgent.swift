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

    // MARK: - Queries

    /// Whether the plist file exists on disk.
    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath().path)
    }

    /// Whether the launchd service is currently loaded (registered with launchd).
    public static func isLoaded() -> Bool {
        isLoaded(label: label)
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
    ///   - KeepAlive = false (no auto-restart on crash)
    ///   - RunAtLoad = false (no auto-start on login)
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

        let plistDict: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "KeepAlive": false,
            "RunAtLoad": false,
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "ProcessType": "Interactive",
            "Nice": -5,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        )
        try data.write(to: plist, options: .atomic)
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
