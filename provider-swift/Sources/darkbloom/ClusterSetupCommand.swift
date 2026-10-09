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
                connected port the address RDMA needs if it lacks one. macOS shows its own approval prompt for \
                that one change; Darkbloom never uses sudo. When not run in a terminal, or with --json, nothing \
                is waited for or asked: the current state and the next step are printed instead, unless --yes \
                is given.
                """)
        @Flag(help: "Print one JSON object at the end instead of a line per step.") var json = false
        @Flag(help: "Allow the wait for a connection and the macOS approval prompt when not run in a terminal or with --json.")
        var yes = false

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            var flow = ClusterLinkSetupFlow(mayPrompt: ClusterLinkSetupFlow.mayPrompt(
                standardOutputIsTerminal: isatty(STDOUT_FILENO) == 1, json: json, yes: yes))
            var narration = [String](), lastReport: ClusterLinkReadinessReport?, manualCommand: String?
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
                case .fix(let device):
                    // Blocks while the person at the screen answers the macOS prompt.
                    let result = await Task.detached { ClusterLinkRepair.fix(device: device) }.value
                    manualCommand = result.manualCommand
                    step = flow.repaired(result)
                case .finish(let exitCode):
                    if json { try printJSON(ClusterLinkSetupResult(ready: exitCode == 0, state: flow.linkState, narration: narration)) }
                    // As with `cluster link --fix`: the address is shown only here,
                    // on standard error, where no prompt could be, and after the
                    // message that announces it even when both streams share a pipe.
                    if let manualCommand {
                        fflush(stdout)
                        printError(manualCommand)
                    }
                    if exitCode != 0 { throw ExitCode(exitCode) }
                    return
                }
            }
        }
    }
}
