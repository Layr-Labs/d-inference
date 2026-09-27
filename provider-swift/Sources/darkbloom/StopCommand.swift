import ArgumentParser
import Foundation
import ProviderCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drain accepted requests, then persistently stop the provider service."
    )

    @OptionGroup var drain: DrainOptions

    @Flag(help: "Also remove the launchd plist (full uninstall).")
    var uninstall = false

    mutating func run() async throws {
        let wasLoaded = LaunchAgent.isAnySupportedLabelLoaded()
        let session = try await ServiceDrain.prepare(options: drain)
        defer { session.release() }

        try await ServiceDrain.stopDrainedProvider()
        if uninstall { try? WatchdogAgent.uninstall() }

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
