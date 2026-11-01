import ArgumentParser
import Darwin
import Foundation
import ProviderCore

/// `darkbloom sandbox`: set up and manage the Darkbloom Sandbox add-on, which
/// runs CI jobs in VMs on this Mac. Every subcommand drives the add-on's own
/// command (`SandboxAddon`); only `setup` talks to the sandbox service, to
/// download the add-on's installer.
struct Sandbox: AsyncParsableCommand {
    static let docsURL = "https://github.com/Layr-Labs/d-inference/blob/master/docs/provider/sandboxes.md"
    static let defaultServer = "https://api-sandbox.darkbloom.dev"
    /// `darkbloom status` waits no longer than this for the add-on.
    static let statusLineTimeout: TimeInterval = 2
    static let statusTimeout: TimeInterval = 10
    static let actionTimeout: TimeInterval = 60

    static var cli: String { BuildEnvironment.current.cliName }

    static let configuration = CommandConfiguration(
        commandName: "sandbox",
        abstract: "Host CI sandboxes (GitHub Actions jobs in Linux and macOS VMs) on this Mac.",
        discussion: """
        Darkbloom Sandbox runs approved GitHub Actions jobs in isolated Linux and macOS virtual machines \
        on this Mac, pausing inference while a job runs and paying each job's price minus a 10% fee into \
        your Darkbloom balance. Docs: \(docsURL)

        Start with `\(BuildEnvironment.current.cliName) sandbox setup`. Without a subcommand, shows this \
        Mac's sandbox status. The add-on is a separate app in ~/DarkbloomSandbox that keeps itself up to date.
        """,
        subcommands: [Setup.self, Status.self, Pause.self, Resume.self, Logs.self, Uninstall.self])

    /// Bare `darkbloom sandbox` shows the status, while `--help` still shows
    /// this group's help (a default subcommand would answer `--help` itself).
    mutating func run() async throws {
        var status = try Status.parse([])
        try await status.run()
    }
}

extension Sandbox {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show whether this Mac hosts sandboxes: state, jobs, slots and images.",
            discussion: "`--json` prints the add-on's status document (schema 1) unchanged.")

        @Flag(help: "Print the add-on's status as JSON.")
        var json = false

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let addon = SandboxAddon.live()
            let query = addon.queryStatus(timeout: Sandbox.statusTimeout)
            if json {
                try Sandbox.printJSON(query)
            } else {
                try await Sandbox.show(query, addon: addon, color: DoctorTerminalStyle.enabled())
            }
        }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Let running jobs finish and take no new ones until you resume.",
            discussion: "Inference serves again once the running jobs end. The add-on stays installed and "
                + "keeps updating itself.")

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            try Sandbox.perform("pause")
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Take sandbox jobs again after a pause.")

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            try Sandbox.perform("resume")
        }
    }

    struct Logs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the add-on agent's log (~/DarkbloomSandbox/agent/agent.log).")

        @Flag(name: .shortAndLong, help: "Keep printing new lines as the agent writes them.")
        var follow = false

        /// `-n` as in tail; `-l` as in `darkbloom logs`.
        @Option(name: [.customShort("n"), .customShort("l"), .long], help: "Number of lines to show.")
        var lines: Int = 50

        mutating func validate() throws {
            guard (0...1_000_000).contains(lines) else {
                throw ValidationError("--lines must be between 0 and 1000000")
            }
        }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let addon = SandboxAddon.live()
            guard FileManager.default.fileExists(atPath: addon.agentLog.path) else {
                print(addon.isInstalled
                    ? "No agent log yet at \(addon.agentLog.path). The agent writes it once it starts; "
                        + "check `\(Sandbox.cli) sandbox status`."
                    : "Darkbloom Sandbox is not set up on this Mac, so it has no log. "
                        + "Set it up with `\(Sandbox.cli) sandbox setup`.")
                return
            }
            let exit = try await SandboxChildProcess.run(
                URL(fileURLWithPath: "/usr/bin/tail"),
                Self.tailArguments(path: addon.agentLog.path, lines: lines, follow: follow))
            if !exit.succeeded, !exit.interrupted { throw ExitCode(exit.status) }
        }

        /// `-F` keeps following when the agent's restart recreates the file.
        static func tailArguments(path: String, lines: Int, follow: Bool) -> [String] {
            (follow ? ["-F"] : []) + ["-n", String(lines), path]
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove the add-on: stop its agent and delete ~/DarkbloomSandbox.",
            discussion: "Running jobs end and are not paid; pause first to let them finish. "
                + "Inference and your Darkbloom balance are not affected.")

        @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
        var yes = false

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            let addon = SandboxAddon.live()
            guard addon.isInstalled else {
                print("Darkbloom Sandbox is not installed on this Mac; nothing to remove.")
                return
            }
            var jobsRunning = 0
            if case .status(let status, _) = addon.queryStatus(timeout: Sandbox.statusTimeout) {
                jobsRunning = status.jobsRunning
            }
            for line in Self.consequences(root: addon.root.path, jobsRunning: jobsRunning) { print(line) }
            if !yes {
                guard isatty(STDIN_FILENO) != 0 else {
                    printError("Confirm in an interactive terminal, or pass --yes to uninstall without a prompt.")
                    throw ExitCode.failure
                }
                guard SandboxTerminal.confirm("Uninstall Darkbloom Sandbox?") else {
                    print("Nothing changed.")
                    return
                }
            }
            let exit = try await SandboxChildProcess.run(addon.command, ["uninstall", "--yes"])
            guard exit.succeeded else { throw ExitCode(exit.signal == nil ? exit.status : 1) }
            print("Set it up again any time with `\(Sandbox.cli) sandbox setup`.")
        }

        static func consequences(root: String, jobsRunning: Int) -> [String] {
            var lines = ["This stops the Darkbloom Sandbox agent and removes \(root): the app, its VM images and its state."]
            if jobsRunning > 0 {
                lines.append("  \(SandboxStatusView.jobs(jobsRunning)) running now will end and will not be paid. "
                    + "To let \(jobsRunning == 1 ? "it" : "them") finish, run `\(Sandbox.cli) sandbox pause` first.")
            }
            lines.append("  Inference is not affected, and nothing pauses it for sandbox jobs any more.")
            return lines
        }
    }
}

// MARK: - Shared behavior

extension Sandbox {
    /// The `darkbloom sandbox status` screen for every answer the add-on can give.
    static func show(_ query: SandboxAddonQuery, addon: SandboxAddon, color: Bool) async throws {
        switch query {
        case .notInstalled:
            SandboxStatusView.notInstalledLines().forEach { print($0) }
        case .status(let status, _) where !status.installed || status.state == .notInstalled:
            SandboxStatusView.notInstalledLines().forEach { print($0) }
        case .status(let status, _):
            SandboxStatusView.lines(status, color: color).forEach { print($0) }
        case .outdated:
            print("This version of the add-on has no `status --json`, so its own status follows. It updates "
                + "itself, or run `\(cli) sandbox setup` to update it now.")
            print("")
            let exit = try await SandboxChildProcess.run(addon.command, ["status"])
            if !exit.succeeded { throw ExitCode(exit.signal == nil ? exit.status : 1) }
        case .unresponsive(let seconds):
            printError("The Darkbloom Sandbox add-on did not answer within \(seconds) seconds. "
                + "See `\(cli) sandbox logs`, or run `\(cli) sandbox setup` to repair it.")
            throw ExitCode.failure
        case .failed(let reason):
            printError("Could not read the Darkbloom Sandbox status (\(reason)). "
                + "Run `\(cli) sandbox setup` to repair the add-on.")
            throw ExitCode.failure
        }
    }

    /// The add-on's JSON unchanged, or a schema 1 `not_installed` document.
    static func printJSON(_ query: SandboxAddonQuery) throws {
        switch query {
        case .status(_, let json):
            print(json, terminator: json.hasSuffix("\n") ? "" : "\n")
        case .notInstalled:
            print(notInstalledJSON)
        case .outdated:
            printError("This version of the add-on cannot report its status as JSON. "
                + "Run `\(cli) sandbox setup` to update it.")
            throw ExitCode.failure
        case .unresponsive(let seconds):
            printError("The Darkbloom Sandbox add-on did not answer within \(seconds) seconds.")
            throw ExitCode.failure
        case .failed(let reason):
            printError("Could not read the Darkbloom Sandbox status (\(reason)).")
            throw ExitCode.failure
        }
    }

    static var notInstalledJSON: String {
        let document: [String: Any] = [
            "schema": 1, "installed": false, "version": "", "host_id": NSNull(), "state": "not_installed",
            "detail": "Darkbloom Sandbox is not set up on this Mac. Run `\(cli) sandbox setup`.",
            "slots": ["linux": ["total": 0, "free": 0], "macos": ["total": 0, "free": 0]],
            "jobs_running": 0, "images": [Any](), "accepting": false, "last_update_check": NSNull(),
            "console_url": defaultServer + "/macs",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `pause` or `resume` through the add-on, then the state it left.
    static func perform(_ action: String) throws {
        let addon = SandboxAddon.live()
        let notSetUp = "Darkbloom Sandbox is not set up on this Mac. Set it up with `\(cli) sandbox setup`."
        switch addon.perform([action], timeout: actionTimeout) {
        case .notInstalled:
            printError(notSetUp)
            throw ExitCode.failure
        case .outdated:
            printError("This version of the add-on cannot \(action) from the CLI. It updates itself; "
                + "run `\(cli) sandbox setup` to update it now.")
            throw ExitCode.failure
        case .failed(let reason):
            // The add-on refuses both when nothing is installed under its command.
            if case .status(let status, _) = addon.queryStatus(timeout: statusTimeout), !status.installed {
                printError(notSetUp)
            } else {
                printError("The add-on could not \(action) (\(reason)). See `\(cli) sandbox logs`.")
            }
            throw ExitCode.failure
        case .done:
            var jobsRunning = 0
            if case .status(let status, _) = addon.queryStatus(timeout: statusTimeout) {
                jobsRunning = status.jobsRunning
            }
            actionLines(action, jobsRunning: jobsRunning).forEach { print($0) }
        }
    }

    static func actionLines(_ action: String, jobsRunning: Int) -> [String] {
        guard action == "pause" else {
            return ["Resumed: this Mac takes sandbox jobs again. Inference pauses while a job runs."]
        }
        let running = jobsRunning == 0
            ? "No jobs are running; inference serves as usual."
            : "\(SandboxStatusView.jobs(jobsRunning)) still running; inference serves again once "
                + (jobsRunning == 1 ? "it ends." : "they end.")
        return [
            "Paused: this Mac takes no new sandbox jobs until you run `\(cli) sandbox resume`.",
            "  \(running)",
        ]
    }
}
