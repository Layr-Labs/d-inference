import Foundation
import ArgumentParser
import ProviderCore

extension Cluster {
    /// `darkbloom cluster` (and `darkbloom cluster setup`): the onboarding on a terminal; the line-by-line link
    /// setup only with the options that ask for it.
    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "setup",
            abstract: "Set up two or more Macs to serve one model together. Run it on each Mac and follow the screen.",
            discussion: """
                Run `darkbloom cluster` in Terminal on each Mac (`darkbloom cluster setup` is the same). The first Mac \
                checks its Thunderbolt cable and asks macOS for one approval, then says "On your other Mac, run \
                `darkbloom cluster`". The other Mac finds it by itself; both show the same code; press y on each. \
                Then choose a model on the first Mac: Darkbloom works out how to split it across both Macs, copies \
                it to a Mac that lacks it, starts both Macs and shows one line saying how the model is served. \
                Nothing else is needed: no SSH, no address and no network setting is typed.

                Run it again on any Mac to see the cluster, change the model or stop it.
                """)
        @OptionGroup var configOptions: ConfigOptions
        @Flag(help: ArgumentHelp("Link setup only: print one JSON object at the end instead of a line per step.", visibility: .hidden))
        var json = false
        @Flag(help: ArgumentHelp("Link setup only: allow the wait for a connection and the macOS approval prompt when not run in a terminal.", visibility: .hidden))
        var yes = false
        @Flag(help: ArgumentHelp("Link setup only: add a link-local address alone, without changing the network settings.", visibility: .hidden))
        var temporary = false
        @Flag(name: .customLong("dry-run"), help: ArgumentHelp("Link setup only: print the commands a link approval would run, and change no network setting.", visibility: .hidden))
        var dryRun = false
        @Flag(name: .customLong("link-only"), help: ArgumentHelp("Run only the line-by-line link setup (developer).", visibility: .hidden))
        var linkOnly = false
        @Flag(help: ArgumentHelp("Developer: print the earlier setup wizard's six steps as text and exit.", visibility: .hidden)) var plain = false
        @Option(help: ArgumentHelp("Developer: absolute path to a pair description.", visibility: .hidden))
        var pair: String?
        @Option(help: ArgumentHelp("Developer: absolute path to the worker's capability record for the pair description's model.", visibility: .hidden))
        var capability: String?
        @Option(name: .customLong("capability-sha256"), help: ArgumentHelp("Developer: expected SHA-256 of that capability record.", visibility: .hidden))
        var capabilitySHA256: String?
        @Option(help: ArgumentHelp("Developer: this Mac's member ID in the pair description.", visibility: .hidden))
        var member: String?
        @Option(name: .customLong("model-dir"), help: ArgumentHelp("Developer: absolute path of the folder holding this Mac's model folders.", visibility: .hidden))
        var modelDir: String?
        @Option(help: ArgumentHelp("Developer: absolute path of this Mac's cluster worker, when it is not the installed one.", visibility: .hidden))
        var worker: String?
        @Flag(help: ArgumentHelp("Developer: open the earlier six-step setup wizard instead of the onboarding.", visibility: .hidden))
        var wizard = false

        func validate() throws { try validateWizardOptions() }

        mutating func run() async throws {
            if plain { return try await printWizardPlain() }
            switch Self.entry(json: json, yes: yes, temporary: temporary, dryRun: dryRun, linkOnly: linkOnly, wizard: wizard,
                inputIsTerminal: isatty(STDIN_FILENO) == 1, outputIsTerminal: isatty(STDOUT_FILENO) == 1,
                terminalType: ProcessInfo.processInfo.environment["TERM"]) {
            case .onboarding:
                return try await Self.runOnboarding(config: configOptions.config, modelDir: modelDir, worker: worker, request: .init())
            case .wizard: return try await runWizard()
            case .needsTerminal:
                print(Self.needsTerminalLine)
                throw ExitCode.failure
            case .linkSetup: break
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
