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
        // stopping, and drop its timer so the next start gets a fresh grace
        // window (uninstall additionally deletes its plist). Best-effort.
        if uninstall {
            try? WatchdogAgent.uninstall()
        } else {
            try? WatchdogAgent.stop()
        }
        try? FileManager.default.removeItem(at: WatchdogStateStore.path())

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
