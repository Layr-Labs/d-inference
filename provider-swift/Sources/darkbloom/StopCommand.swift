import ArgumentParser
import Foundation
import ProviderCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drain accepted requests, then persistently stop the provider service.",
        discussion: "On a Mac in a two-Mac cluster it stops single-Mac serving only, never the cluster's part: "
            + "`darkbloom cluster stop` stops the cluster on both Macs."
    )

    @OptionGroup var drain: DrainOptions

    @Flag(help: "Also remove the provider, watchdog and desktop API launchd agents (full uninstall).")
    var uninstall = false

    /// What `darkbloom stop` does on a Mac in a two-Mac cluster (UX audit P4a).
    enum PairedStop: Equatable {
        /// No single-Mac serving runs: say so and where the cluster is stopped; nothing is drained or disabled.
        case refuse(lines: [String], exitCode: Int32)
        /// Stop single-Mac serving as on any Mac (its process only), then say the cluster keeps serving.
        case stopSingleMac
    }

    static func pairedStop(_ pair: ClusterPairSummary, singleMacLoaded: Bool, uninstall: Bool) -> PairedStop {
        guard !singleMacLoaded, !uninstall else { return .stopSingleMac }
        let refusal = pair.stopRefusal
        return .refuse(lines: refusal.lines, exitCode: refusal.exitCode)
    }

    mutating func run() async throws {
        let pair = ClusterPairSummary.local()
        let wasLoaded = LaunchAgent.isLoaded()
        if pair.paired, case .refuse(let lines, let exitCode) = Self.pairedStop(pair, singleMacLoaded: wasLoaded, uninstall: uninstall) {
            for line in lines { print(line) }
            if exitCode != 0 { throw ExitCode(exitCode) }
            return
        }
        let session = try await ServiceDrain.prepare(options: drain, state: ServiceDrain.soloProviderState())
        defer { session.release() }

        try await ServiceDrain.stopDrainedProvider(daemonState: ServiceDrain.soloProviderState())
        if uninstall {
            try? WatchdogAgent.uninstall()
            // The desktop API agent is KeepAlive; leaving it would keep it running
            // (and auto-updating) after the app and provider are removed.
            try? DesktopService.uninstall()
        }

        if uninstall {
            try LaunchAgent.uninstall()
            print("Provider service uninstalled.")
        } else {
            try LaunchAgent.stop()
            if wasLoaded {
                let start = "`\(BuildEnvironment.current.cliName) start\(pair.paired ? " --solo" : "")`"
                print("Provider service stopped. (Won't auto-start at login/reboot until you run \(start) again.)")
            } else {
                print("Provider service is not running. (Auto-start at login/reboot is now disabled.)")
            }
        }
        if pair.paired { for line in pair.stopAddendum { print(line) } }
    }
}
