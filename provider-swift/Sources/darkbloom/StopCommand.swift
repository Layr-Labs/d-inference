import ArgumentParser
import Foundation
import ProviderCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drain accepted requests, then persistently stop the provider service.",
        discussion: "On a Mac in a two-Mac cluster it stops the pair on both Macs, as `darkbloom cluster stop` does: they "
            + "stay stopped after a restart, and `darkbloom start` on either Mac starts the pair again. With --solo it "
            + "stops single-Mac serving on this Mac only and never touches the pair."
    )

    @OptionGroup var drain: DrainOptions

    @Flag(help: "Also remove the provider, watchdog and desktop API launchd agents (full uninstall).")
    var uninstall = false

    @Flag(help: "On a Mac in a two-Mac cluster: stop single-Mac serving on this Mac only; the pair keeps running.")
    var solo = false

    /// What `darkbloom stop` does on a Mac in a two-Mac cluster.
    enum PairedStop: Equatable {
        /// Stop the pair on both Macs (`ClusterPairCommands.stop`).
        case stopPair
        /// This Mac's pairing record can't be read: nothing changes, and why.
        case refuse([String])
        /// Single-Mac serving only (`--solo`, `--uninstall`, or not in a cluster): as on any Mac, its process only.
        case stopSingleMac
    }

    static func pairedStop(_ pair: ClusterPairSummary, solo: Bool, uninstall: Bool) -> PairedStop {
        guard pair.paired, !solo, !uninstall else { return .stopSingleMac }
        return pair.pairingUnreadable ? .refuse(pair.unsureRefusal("stop", "stopped")) : .stopPair
    }

    mutating func run() async throws {
        let pair = ClusterPairSummary.local()
        switch Self.pairedStop(pair, solo: solo, uninstall: uninstall) {
        case .stopPair:
            let actions = ClusterPairActions.live(config: nil)
            let teardown = ClusterPairCommands.teardownWait
            let code = await Task.detached { ClusterPairCommands.stop(pair, actions: actions, teardown: teardown) }.value
            if code != 0 { throw ExitCode(code) }
            return
        case .refuse(let lines):
            for line in lines { print(line) }
            throw ExitCode.failure
        case .stopSingleMac:
            break
        }
        let wasLoaded = LaunchAgent.isLoaded()
        if pair.paired, !wasLoaded, !uninstall {
            for line in pair.soloStopNothing { print(line) }
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
