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

        do {
            try await WatchdogDrainTransaction().run {
                _ = try await drainProviderBeforeLifecycleAction("stopping")
            }
        } catch {
            printError("Stop cancelled: \(error)")
            throw ExitCode.failure
        }

        // The transaction already disarmed crash recovery before the provider
        // exited. Delete its plist only after a successful drain.
        if uninstall {
            try? WatchdogAgent.uninstall()
        }
        try? FileManager.default.removeItem(at: WatchdogStateStore.path())

        if uninstall {
            try LaunchAgent.uninstall()
            print("Provider service uninstalled.")
        } else {
            try LaunchAgent.stop()
            if wasLoaded {
                print("Provider service stopped. (Won't auto-start at login/reboot until you run `darkbloom start` again.)")
            } else {
                print("Provider service is not running. (Auto-start at login/reboot is now disabled.)")
            }
        }
    }
}
