import ArgumentParser
import ProviderCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the provider launchd service."
    )

    @Flag(help: "Also remove the launchd plist (full uninstall).")
    var uninstall = false

    mutating func run() async throws {
        let wasLoaded = LaunchAgent.isLoaded()

        if uninstall {
            try LaunchAgent.uninstall()
            print("Provider service uninstalled.")
        } else {
            try LaunchAgent.stop()
            if wasLoaded {
                print("Provider service stopped.")
            } else {
                print("Provider service is not running.")
            }
        }

        // launchd stops the daemon with SIGTERM, which skips its own cleanup,
        // so the CLI removes the diagnostics state file on its behalf.
        DaemonStateFile.remove()
    }
}
