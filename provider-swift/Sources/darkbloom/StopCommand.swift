import ArgumentParser
import Foundation
import ProviderCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the provider launchd service."
    )

    @Flag(help: "Also remove the launchd plist (full uninstall).")
    var uninstall = false

    mutating func run() async throws {
        let wasLoaded = LaunchAgent.isLoaded()

        // Disarm crash recovery FIRST so the watchdog can't relaunch what we're
        // stopping (uninstall deletes its plist + state). Best-effort.
        if uninstall {
            try? WatchdogAgent.uninstall()
            try? FileManager.default.removeItem(at: WatchdogStateStore.path())
        } else {
            try? WatchdogAgent.stop()
        }

        if uninstall {
            try LaunchAgent.uninstall()
            print("Provider service uninstalled.")
        } else {
            try LaunchAgent.stop()
            if wasLoaded {
                print("Provider service stopped. (Auto-restart disabled until you start again.)")
            } else {
                print("Provider service is not running.")
            }
        }
    }
}
