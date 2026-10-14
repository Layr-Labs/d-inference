import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// `darkbloom cluster` with no subcommand: the guided setup wizard on a
    /// terminal, the guided link setup line by line everywhere else.
    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "setup",
            abstract: "Set up a cluster: start on any Mac, run it on the other Mac too and confirm the code; afterwards it works on every member.",
            discussion: """
                On a terminal, bare `darkbloom cluster` is the onboarding. It checks RDMA, the cable and the \
                cable port's isolation (one macOS approval when needed) and the RDMA GID. When no other Mac waits \
                on the cable, this Mac becomes the leader and says "On your other Mac, run `darkbloom cluster`"; \
                the other Mac then finds it by itself, both show the same code, y on each pairs them, and the \
                other Mac is told where to continue. The leader shows both Macs' hardware, the models both hold \
                with the planner's placement, and on y saves the plan, syncs the member's setup over the cable, \
                starts both Macs' parts and serves. Afterwards the cluster's control leader is derived (the \
                plan's rank 0, where requests enter) and fails over when it disappears; `darkbloom cluster` on any \
                member shows the status and changes the model, stops or starts it, forwarding to the leader. \
                Run again, it shows where this Mac stands and the next step. \
                --wizard opens the earlier six-step wizard instead; --plain prints its six steps.

                As `darkbloom cluster setup`, with --json, --yes or --temporary, or when not run in a terminal, \
                it is the guided link setup: it checks that RDMA is enabled, waits for a Thunderbolt 5 connection \
                to another Mac, and sets the connected port up for the cluster alone (out of every bridge, with \
                its own network service, a fixed address, no router and no DNS, which macOS keeps also after a \
                restart), behind macOS's own approval prompt. Darkbloom never uses sudo and never changes \
                Internet Sharing. When not run in a terminal, or with --json, nothing is waited for or asked \
                unless --yes is given. `darkbloom cluster link --remove` restores the network settings this changes.
                """)
        @OptionGroup var configOptions: ConfigOptions
        @Flag(help: "Print one JSON object at the end instead of a line per step.") var json = false
        @Flag(help: "Allow the wait for a connection and the macOS approval prompt when not run in a terminal or with --json.")
        var yes = false
        @Flag(help: "Add a link-local address alone, without changing the network settings; it lasts until macOS next reconfigures the port.")
        var temporary = false
        @Flag(name: .customLong("dry-run"), help: "Print the commands a link approval would run, and change no network setting; in the wizard, the link fix only shows its commands.")
        var dryRun = false
        @Flag(help: "Print the setup wizard's six steps as text and exit.") var plain = false
        @Option(help: "Absolute path to the pair description: the two Macs and their installations (the leader, once).")
        var pair: String?
        @Option(help: "Absolute path to the worker's capability record for the pair description's model.")
        var capability: String?
        @Option(name: .customLong("capability-sha256"), help: "Expected SHA-256 of that capability record.")
        var capabilitySHA256: String?
        @Option(help: "This Mac's member ID in the pair description.")
        var member: String?
        @Option(name: .customLong("model-dir"), help: "Absolute path of the folder holding this Mac's model folders (once; the wizard remembers it).")
        var modelDir: String?
        @Option(help: "Absolute path of this Mac's cluster worker, when it is not the installed one (Darkbloom.app/Contents/Helpers).")
        var worker: String?
        @Flag(help: "Open the six-step setup wizard instead of the leader-first onboarding.")
        var wizard = false

        func validate() throws { try validateWizardOptions() }

        mutating func run() async throws {
            if plain { return try await printWizardPlain() }
            if Self.opensWizard(arguments: CommandLine.arguments, json: json, yes: yes, temporary: temporary, plain: plain,
                inputIsTerminal: isatty(STDIN_FILENO) == 1, outputIsTerminal: isatty(STDOUT_FILENO) == 1,
                terminalType: ProcessInfo.processInfo.environment["TERM"]) {
                return try await (wizard ? runWizard() : runOnboarding())
            }
            Darkbloom.ensureLogging()
            let mode = temporary ? ClusterLinkRepair.Mode.temporary : .durable, dryRun = dryRun
            var flow = ClusterLinkSetupFlow(mayPrompt: ClusterLinkSetupFlow.mayPrompt(
                standardOutputIsTerminal: isatty(STDOUT_FILENO) == 1, json: json, yes: yes),
                temporary: temporary, dryRun: dryRun)
            var narration = [String](), lastReport: ClusterLinkReadinessReport?, manualCommands = [String]()
            var step = flow.begin()
            while true {
                narration += step.lines
                if !json {
                    for line in step.lines { print(line) }
                    // Each observation is shown when it is made, also on a pipe.
                    fflush(stdout)
                }
                switch step.action {
                case .inspect:
                    let report = await Task.detached { ClusterLinkReadinessProbe.inspectLocalLink() }.value
                    lastReport = report
                    step = flow.observed(report)
                case .awaitConnection:
                    guard try await ClusterLinkWatchLoop.nextChange(after: lastReport) != nil else {
                        step = flow.interrupted()
                        continue
                    }
                    // The watch reads ports only; the flow decides on a full reading.
                    let changed = await Task.detached { ClusterLinkReadinessProbe.inspectLocalLink() }.value
                    lastReport = changed
                    step = flow.observed(changed)
                case .awaitKeeper:
                    // Bounded: the keeper runs every few seconds, and the flow decides what to do if it has not.
                    var polls = max(1, ClusterLinkSetupFlow.keeperWaitSeconds / ClusterLinkWatch.pollIntervalSeconds)
                    var report: ClusterLinkReadinessReport
                    repeat {
                        try? await Task.sleep(for: .seconds(ClusterLinkWatch.pollIntervalSeconds))
                        report = await Task.detached { ClusterLinkReadinessProbe.inspectLocalLink() }.value
                        polls -= 1
                    } while polls > 0 && report.state == lastReport?.state
                    lastReport = report
                    step = flow.observed(report)
                case .fix(let device):
                    // Blocks while the person at the screen answers the macOS prompt; a dry run asks nothing.
                    let result = await Task.detached { ClusterLinkRepair.fix(device: device, mode: mode, dryRun: dryRun) }.value
                    // One short line where the commands went into an owner-only script.
                    manualCommands = result.manualScript.map { ["sudo sh \($0)"] } ?? result.manualCommands
                    step = flow.repaired(result)
                case .finish(let exitCode):
                    // A dry run also ends with status 0, so readiness is what was observed, not the status.
                    if json { try printJSON(ClusterLinkSetupResult(ready: flow.linkState == .ready, state: flow.linkState, narration: narration)) }
                    // As with `cluster link --fix`: outside a dry run the address is
                    // shown only here, on standard error, where no prompt could be,
                    // and after the message that announces it even on a shared pipe.
                    if !manualCommands.isEmpty {
                        fflush(stdout)
                        for command in manualCommands { printError(command) }
                    }
                    if exitCode != 0 { throw ExitCode(exitCode) }
                    return
                }
            }
        }
    }
}
