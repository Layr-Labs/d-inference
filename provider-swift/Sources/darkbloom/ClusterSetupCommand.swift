import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// `darkbloom cluster` with no subcommand: the guided link setup.
    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "setup",
            abstract: "Get this Mac's Thunderbolt RDMA link ready; the only thing asked of you is approval in a macOS prompt.",
            discussion: """
                Checks that RDMA is enabled, waits for a Thunderbolt 5 connection to another Mac, and gives the \
                connected port the address RDMA needs if it lacks one, with a small system job that puts the \
                address back whenever macOS removes it. macOS shows its own approval prompt for that one \
                change; Darkbloom never uses sudo. When not run in a terminal, or with --json, nothing is \
                waited for or asked: the current state and the next step are printed instead, unless --yes \
                is given. `darkbloom cluster link --remove` undoes everything this installs.
                """)
        @Flag(help: "Print one JSON object at the end instead of a line per step.") var json = false
        @Flag(help: "Allow the wait for a connection and the macOS approval prompt when not run in a terminal or with --json.")
        var yes = false
        @Flag(help: "Add the address alone, without the system job that keeps it; it lasts until macOS next reconfigures the port.")
        var temporary = false
        @Flag(name: .customLong("dry-run"), help: "Print the commands an approval would run, and change nothing.")
        var dryRun = false

        mutating func run() async throws {
            // Bare `darkbloom cluster` in a terminal opens the console, which continues this flow.
            if Console.replacesGuidedSetup(arguments: CommandLine.arguments, json: json, yes: yes, temporary: temporary,
                dryRun: dryRun, inputIsTerminal: isatty(STDIN_FILENO) == 1, outputIsTerminal: isatty(STDOUT_FILENO) == 1,
                terminalType: ProcessInfo.processInfo.environment["TERM"]) {
                return try await Console.runAsGuidedSetup()
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
                    guard let changed = try await ClusterLinkWatchLoop.nextChange(after: lastReport) else {
                        step = flow.interrupted()
                        continue
                    }
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
                    manualCommands = result.manualCommands
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
