/// LaunchAgentManager — Install/remove a launchd LaunchAgent for auto-start on login.
///
/// Creates a plist at ~/Library/LaunchAgents/io.dginf.provider.plist that
/// launches the DGInf.app on login. This wires the "Start DGInf when you
/// log in" toggle in SettingsView to an actual system mechanism.

import Foundation

enum LaunchAgentManager {

    private static let plistName = "io.dginf.provider.plist"

    private static var plistPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(plistName)
    }

    /// Whether the LaunchAgent is currently installed.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath.path)
    }

    /// Install the LaunchAgent to start DGInf on login.
    static func install() throws {
        let launchAgentsDir = plistPath.deletingLastPathComponent()

        // Ensure ~/Library/LaunchAgents exists
        try FileManager.default.createDirectory(
            at: launchAgentsDir,
            withIntermediateDirectories: true
        )

        // Find the app bundle path
        let appPath: String
        if let bundlePath = Bundle.main.bundlePath as String?,
           bundlePath.hasSuffix(".app") {
            appPath = bundlePath
        } else {
            // Development: use the binary path directly
            appPath = Bundle.main.executablePath ?? ""
        }

        let plist: [String: Any] = [
            "Label": "io.dginf.provider",
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".dginf/launchagent.log").path,
            "StandardErrorPath": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".dginf/launchagent.log").path,
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
        guard isInstalled else { return }

        // Unload first
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["unload", plistPath.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()

        // Remove plist
        try FileManager.default.removeItem(at: plistPath)
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
            // Log but don't crash — this is a nice-to-have feature
            print("LaunchAgent sync failed: \(error)")
        }
    }
}
