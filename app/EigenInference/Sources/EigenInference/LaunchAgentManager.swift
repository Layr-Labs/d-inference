/// LaunchAgentManager — Install/remove a launchd LaunchAgent for app auto-launch on login.
///
/// Creates a plist at ~/Library/LaunchAgents/com.darkbloom.app.plist that opens
/// the Darkbloom app on login. This is separate from the provider service plist
/// which is managed by the CLI's `start`/`stop`.
///
/// Only installed when the user explicitly toggles "Start Darkbloom when you
/// log in" in Settings. Opening the app does NOT auto-start the provider;
/// the user must click "Go Online" to begin serving.

import Foundation

enum LaunchAgentManager {

    private static let plistName = "com.darkbloom.app.plist"

    private static var plistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(plistName)
    }

    /// Also check for legacy plist name and migrate if needed.
    private static var legacyPlistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("io.darkbloom.app.plist")
    }

    /// Whether the LaunchAgent is currently installed.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath.path)
            || FileManager.default.fileExists(atPath: legacyPlistPath.path)
    }

    /// Install the LaunchAgent to start DarkBloom on login.
    static func install() throws {
        // Remove legacy plist if it exists
        if FileManager.default.fileExists(atPath: legacyPlistPath.path) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["unload", legacyPlistPath.path]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            try? FileManager.default.removeItem(at: legacyPlistPath)
        }

        let launchAgentsDir = plistPath.deletingLastPathComponent()

        // Ensure ~/Library/LaunchAgents exists
        try FileManager.default.createDirectory(
            at: launchAgentsDir,
            withIntermediateDirectories: true
        )

        // Find the app or executable path.
        // When running as a .app bundle, use `open` to launch it.
        // When running from a debug build (swift run), use the executable directly.
        let bundlePath = Bundle.main.bundlePath
        let isAppBundle = bundlePath.hasSuffix(".app")
        let programArgs: [String] = isAppBundle
            ? ["/usr/bin/open", bundlePath]
            : [ProcessInfo.processInfo.arguments[0]]

        // Ensure ~/.darkbloom/ directory exists for log files
        let appDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".darkbloom")
        try FileManager.default.createDirectory(
            at: appDir,
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": "com.darkbloom.app",
            "ProgramArguments": programArgs,
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": appDir.appendingPathComponent("launchagent.log").path,
            "StandardErrorPath": appDir.appendingPathComponent("launchagent.log").path,
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistPath)

        // Load the agent
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["load", plistPath.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
    }

    /// Remove the LaunchAgent.
    static func uninstall() throws {
        // Unload and remove current plist
        for path in [plistPath, legacyPlistPath] {
            guard FileManager.default.fileExists(atPath: path.path) else { continue }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            proc.arguments = ["unload", path.path]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()

            try FileManager.default.removeItem(at: path)
        }
    }

    /// Sync the LaunchAgent state with the desired auto-start setting.
    static func sync(autoStart: Bool) {
        do {
            if autoStart && !isInstalled {
                try install()
            } else if !autoStart && isInstalled {
                try uninstall()
            }
        } catch {
            print("LaunchAgent sync failed: \(error)")
        }
    }
}
