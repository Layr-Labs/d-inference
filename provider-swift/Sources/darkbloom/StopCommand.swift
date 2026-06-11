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

        // Disarm crash recovery FIRST so the watchdog can't relaunch the daemon
        // we're about to stop. Tear it down to match the provider agent: plain
        // stop unloads it (plist stays for reboot); uninstall deletes the plist.
        // Best-effort — a watchdog hiccup must never block stopping the provider.
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
