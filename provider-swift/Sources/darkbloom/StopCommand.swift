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
            // Drain before uninstall so we don't tear down the launchd job while
            // the daemon is still serving requests.
            _ = await drainRunningProvider(action: .stop)
            try LaunchAgent.uninstall()
            print("Provider service uninstalled.")
        } else {
            let didDrain = await drainRunningProvider(action: .stop)
            try LaunchAgent.stop()
            if wasLoaded {
                if didDrain {
                    print("Provider service stopped after draining active requests. (Won't auto-start at login/reboot until you run `darkbloom start` again.)")
                } else {
                    print("Provider service stopped. (Won't auto-start at login/reboot until you run `darkbloom start` again.)")
                }
            } else {
                print("Provider service is not running. (Auto-start at login/reboot is now disabled.)")
            }
        }
    }
}
