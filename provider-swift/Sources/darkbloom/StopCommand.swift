import ArgumentParser
import Foundation
import ProviderCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drain accepted requests, then persistently stop the provider service.",
        discussion: "On a Mac in a two-Mac cluster it stops the pair on both Macs, as `\(ClusterPairSummary.cli) cluster stop` does: they "
            + "stay stopped after a restart, and `\(ClusterPairSummary.cli) start` on either Mac starts the pair again. With --solo it "
            + "stops single-Mac serving on this Mac only and never touches the pair."
    )

    @OptionGroup var drain: DrainOptions

    @Flag(help: "Also remove the provider, watchdog and desktop API launchd agents; files stay. To take Darkbloom off this Mac, run `\(BuildEnvironment.current.cliName) uninstall`.")
    var uninstall = false

    @Flag(help: "On a Mac in a two-Mac cluster: stop single-Mac serving on this Mac only; the pair keeps running.")
    var solo = false

    @Flag(help: "With --solo, when single-Mac serving runs on the other Mac instead: stop it there without asking.")
    var yes = false

    /// The other Mac's single-Mac serving, when `stop --solo` finds none here.
    static func otherMacSolo(_ found: [ClusterOnboardingSoloServing]) -> ClusterOnboardingSoloServing? {
        found.first { $0.mac != ClusterOnboardingMacName.this }
    }

    static func otherMacLines(_ solo: ClusterOnboardingSoloServing, cli: String) -> [String] {
        ["Single-Mac serving doesn't run on this Mac; it runs on \(solo.mac)" + (solo.pid.map { " (process \($0))" } ?? "") + ".",
         "Stop it there? `\(cli) stop --solo --yes` does it without asking."]
    }

    static func otherMacDeclined(_ solo: ClusterOnboardingSoloServing, cli: String) -> String {
        "Nothing was stopped. On \(solo.mac), run `\(cli) stop --solo`."
    }

    /// `stop --solo` where none runs here: single-Mac serving on the other Mac is named and stopped there with consent
    /// (`--yes` for scripts). True when it handled the stop (stopped there); throws when declined or it failed.
    private func stopOnOtherMac() throws -> Bool {
        guard solo, let actions = ClusterPairActions.live(config: nil),
              let there = Self.otherMacSolo(actions.soloServing()) else { return false }
        let cli = BuildEnvironment.current.cliName
        let lines = Self.otherMacLines(there, cli: cli)
        print(lines[0])
        var go = yes
        if !go, ClusterPairCommands.isTerminal() {
            print(lines[1] + " [y/N]: ", terminator: ""); fflush(stdout)
            go = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("y")
        }
        guard go else { print(Self.otherMacDeclined(there, cli: cli)); throw ExitCode.failure }
        switch actions.stopSoloServing() {
        case .success(let said): for line in said { print(line) }; return true
        case .failure(let failure): for line in failure.lines { print(line) }; throw ExitCode.failure
        }
    }

    /// What `darkbloom stop` does on a Mac in a two-Mac cluster.
    enum PairedStop: Equatable {
        /// Stop the pair on both Macs (`ClusterPairCommands.stop`).
        case stopPair
        /// This Mac's pairing record can't be read: nothing changes, and why.
        case refuse([String])
        /// Single-Mac serving only (`--solo`, `--uninstall`, or not in a cluster): as on any Mac, its process only.
        case stopSingleMac
        /// The pair doesn't run here: what runs on this Mac stops, single-Mac serving and a leftover part of the pair
        /// (whose saved start is cleared, so it doesn't come back at login).
        case stopHere
    }

    static func pairedStop(_ pair: ClusterPairSummary, solo: Bool, uninstall: Bool) -> PairedStop {
        guard pair.paired, !solo, !uninstall else { return .stopSingleMac }
        if pair.pairingUnreadable { return .refuse(pair.unsureRefusal("stop", "stopped")) }
        // A started pair whose other Mac answers (it may still be loading) stops on both Macs: a follower's own cleared
        // start would come back with its leader's next lease.
        return pair.pairIdle && (!pair.started || !pair.otherMacReachable) ? .stopHere : .stopPair
    }

    /// The command's look, opened with the mark: for a stop that goes ahead.
    private static func openLook() -> DarkbloomCommandLook {
        let look = DarkbloomCommandLook.forCommand()
        look.open("Darkbloom stop")
        return look
    }

    mutating func run() async throws {
        let pair = ClusterPairSummary.local()
        let stop = Self.pairedStop(pair, solo: solo, uninstall: uninstall)
        if case .refuse(let lines) = stop {
            for line in lines { print(line) }
            throw ExitCode.failure
        }
        // Decided first: only a stop that goes ahead opens with the mark, never a refusal or `--solo` with nothing to stop.
        if stop == .stopPair {
            let look = Self.openLook()
            let actions = ClusterPairActions.live(config: nil)
            let teardown = ClusterPairCommands.teardownWait, progressAfter = ClusterPairCommands.progressDelay
            let say = look.saying(ClusterPairCommands.printLine)
            let code = await look.working("Stopping both Macs") {
                await Task.detached {
                    ClusterPairCommands.stop(pair, actions: actions, teardown: teardown, progressAfter: progressAfter, say: say)
                }.value
            }
            if code != 0 { throw ExitCode(code) }
            return
        }
        if stop == .stopHere, pair.leftoverPartHere {
            print(pair.leftoverStopLine)
            try await Start.releaseLeftoverPart(pair)
        }
        // Stopping single-Mac serving here: a choice of it made before no longer stands.
        if pair.paired { Start.clearSoloChoice() }
        let wasLoaded = LaunchAgent.isLoaded()
        if pair.paired, !wasLoaded, !uninstall {
            if stop == .stopSingleMac, !pair.pairingUnreadable, try stopOnOtherMac() { return }
            if stop != .stopHere { for line in pair.soloStopNothing { print(line) } }
            else if !pair.started { print("Nothing serves on this Mac: nothing was stopped.") }
            return
        }
        let look = Self.openLook()
        let session = try await look.working("Draining accepted requests") {
            try await ServiceDrain.prepare(options: drain, state: ServiceDrain.soloProviderState())
        }
        defer { session.release() }

        try await look.working("Stopping the provider") {
            try await ServiceDrain.stopDrainedProvider(daemonState: ServiceDrain.soloProviderState())
        }
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
        if pair.paired, stop != .stopHere { for line in pair.stopAddendum { print(line) } }
    }
}
