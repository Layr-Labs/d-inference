import ArgumentParser
import Darwin
import Foundation
import ProviderCore

extension Sandbox {
    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check this Mac, then install the add-on and enroll this Mac. Safe to run again.",
            discussion: """
            Checks this Mac, then downloads the add-on's installer from the Darkbloom Sandbox service over \
            HTTPS and asks it for the add-on's plan: how many jobs this Mac can run at a time and the disk \
            they take. It explains what changes and asks before installing anything. The installer then \
            verifies the release, installs it in ~/DarkbloomSandbox, and enrolls this Mac once you approve \
            it in your browser.

            Running it again reports the current state, continues an unfinished setup, repairs or updates \
            the add-on, or applies new slot counts.
            """)

        @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
        var yes = false

        @Flag(help: "Don't open the browser for approval; open the printed link yourself.")
        var noBrowser = false

        @Option(help: "Linux jobs to run at a time (0-16). Default: what fits this Mac.")
        var linuxSlots: Int?

        @Option(name: .customLong("macos-slots"), help: "macOS jobs to run at a time (0-2). Default: what fits this Mac.")
        var macOSSlots: Int?

        @Flag(help: "Wait until the VM images are downloaded and this Mac is ready for jobs.")
        var waitReady = false

        @Option(help: "The Darkbloom Sandbox service to download the installer from (https).")
        var server = Sandbox.defaultServer

        mutating func validate() throws {
            guard SandboxInstaller.scriptURL(server: server) != nil else {
                throw ValidationError("--server must be an https URL, such as \(Sandbox.defaultServer)")
            }
            if let linuxSlots, !(0...SandboxEligibility.maximumLinuxSlots).contains(linuxSlots) {
                throw ValidationError("--linux-slots must be between 0 and \(SandboxEligibility.maximumLinuxSlots)")
            }
            if let macOSSlots, !(0...SandboxEligibility.maximumMacOSSlots).contains(macOSSlots) {
                throw ValidationError("--macos-slots must be between 0 and \(SandboxEligibility.maximumMacOSSlots)")
            }
            if linuxSlots == 0, macOSSlots == 0 {
                throw ValidationError("--linux-slots 0 with --macos-slots 0 leaves nothing to run")
            }
        }

        var options: SandboxSetupOptions {
            SandboxSetupOptions(server: server, noBrowser: noBrowser, waitReady: waitReady,
                                linuxSlots: linuxSlots, macOSSlots: macOSSlots)
        }

        mutating func run() async throws {
            Darkbloom.ensureLogging()
            // Line-buffer stdout: piped or over ssh it is block-buffered, and the
            // approval link (and every progress line) would appear only when the
            // buffer fills or setup exits, long after the owner needs it.
            setvbuf(stdout, nil, _IOLBF, 0)
            guard geteuid() != 0 else {
                printError("Run `\(Sandbox.cli) sandbox setup` as yourself, not with sudo: the add-on runs in your "
                    + "login session.")
                throw ExitCode.failure
            }
            try await SandboxSetupFlow(
                options: options, confirmed: yes, addon: .live(), interactiveInput: isatty(STDIN_FILENO) != 0,
                terminal: SandboxTerminal.interactive(), color: DoctorTerminalStyle.enabled()
            ).run()
        }
    }
}

/// What `setup` does, given the add-on's current answer.
enum SandboxSetupPlan: Equatable, Sendable {
    /// Set up already; report it and change nothing.
    case alreadySetUp(SandboxAddonStatus)
    /// Run the installer over the existing install, for this reason.
    case rerun(String)
    /// A first setup: check eligibility and ask first.
    case fresh

    static func decide(_ query: SandboxAddonQuery, changingSlots: Bool) -> SandboxSetupPlan {
        let repair = "running the installer again to repair it"
        let capitalizedRepair = "Running the installer again to repair it"
        switch query {
        case .notInstalled:
            return .fresh
        case .status(let status, _) where !status.installed:
            return .fresh
        case .status(let status, _):
            switch status.state {
            case .notInstalled:
                return .fresh
            case .waitingForApproval, .waitlisted, .enrolling:
                return .rerun("Continuing the setup on this Mac (\(SandboxStatusView.headline(status).text)).")
            case .stopped:
                return .rerun("The add-on's agent is stopped; \(repair).")
            case .error:
                guard let detail = status.detail else { return .rerun("The add-on reports an error; \(repair).") }
                return .rerun("The add-on reports an error: \(detail). \(capitalizedRepair).")
            case .ready, .running, .paused, .downloadingImages, .updating, .unknown:
                return changingSlots ? .rerun("Applying the new slot counts.") : .alreadySetUp(status)
            }
        case .outdated:
            return .rerun("Updating the add-on: this version is older than the CLI expects.")
        case .unresponsive(let seconds):
            return .rerun("The add-on did not answer within \(seconds) seconds; \(repair).")
        case .failed(let reason):
            return .rerun("The add-on's status failed (\(reason)); \(repair).")
        }
    }
}

/// `darkbloom sandbox setup`: check, explain and confirm, install, summarize.
struct SandboxSetupFlow {
    let options: SandboxSetupOptions
    /// `--yes`: the owner agreed without a prompt.
    let confirmed: Bool
    let addon: SandboxAddon
    let interactiveInput: Bool
    let terminal: Bool
    let color: Bool
    /// Measures this Mac for a first setup.
    var probe: @Sendable (SandboxAddon) async -> SandboxHostFacts = {
        await SandboxHostProbe.live(addon: $0, imagesInstalled: false)
    }

    private var cli: String { Sandbox.cli }

    func run() async throws {
        let existing = addon.queryStatus(timeout: Sandbox.statusTimeout)
        let changingSlots = options.linuxSlots != nil || options.macOSSlots != nil
        switch SandboxSetupPlan.decide(existing, changingSlots: changingSlots) {
        case .alreadySetUp(let status):
            print("Darkbloom Sandbox is already set up on this Mac.")
            print("")
            SandboxStatusView.lines(status, color: color).forEach { print($0) }
            print("")
            print("To change how many jobs run at a time: \(cli) sandbox setup --linux-slots <n> --macos-slots <n>")
        case .rerun(let reason):
            print(reason)
            try await withInstaller { try await install($0, script: $1) }
        case .fresh:
            let eligibility = try await checkMac()
            try await withInstaller { installer, script in
                guard try await sizeAndConfirm(eligibility, installer: installer, script: script) else { return }
                try await install(installer, script: script)
            }
        }
    }

    // MARK: - Check and confirm

    /// Prints the checks setup makes itself; throws, before anything is
    /// downloaded, when this Mac can never host sandboxes as it is.
    private func checkMac() async throws -> SandboxEligibility {
        print("Darkbloom Sandbox setup")
        print("")
        print(DoctorTerminalStyle.heading("Checking this Mac", color: color))
        let eligibility = SandboxEligibility(await probe(addon))
        printChecks(eligibility.checks)
        if let refusal = eligibility.refusal {
            print("")
            print(DoctorTerminalStyle.verdict("Not eligible: \(refusal)", level: .fail, color: color))
            throw ExitCode.failure
        }
        return eligibility
    }

    /// Prints the add-on's plan (else the fallback estimate) and the
    /// trade-off, then asks. False when the owner declines; throws when no job
    /// fits.
    private func sizeAndConfirm(_ eligibility: SandboxEligibility, installer: URL, script: Data) async throws -> Bool {
        let plan: SandboxSizingPlan
        if let reportedPlan = try await requestAddonPlan(installer, script: script) {
            plan = reportedPlan
        } else {
            printChecks([SandboxEligibility.Check(
                level: .info, name: "Sizing",
                detail: "this installer reports no plan (add-on 1.1.1 and later do); the CLI estimated the lines below")])
            plan = eligibility.estimatedPlan(linuxRequested: options.linuxSlots, macOSRequested: options.macOSSlots)
        }
        printChecks(plan.checks)
        print("")
        let verdict = plan.verdict
        print(DoctorTerminalStyle.verdict(verdict[0], level: plan.canRunJobs ? .pass : .fail, color: color))
        verdict.dropFirst().forEach { print($0) }
        guard plan.canRunJobs else { throw ExitCode.failure }
        print("")
        Self.tradeOff.forEach { print($0) }
        guard !confirmed else { return true }
        print("")
        guard interactiveInput else {
            printError("Confirm in an interactive terminal, or pass --yes to set up without a prompt.")
            throw ExitCode.failure
        }
        guard SandboxTerminal.confirm("Set up Darkbloom Sandbox on this Mac?") else {
            print("Nothing changed.")
            return false
        }
        return true
    }

    private func printChecks(_ checks: [SandboxEligibility.Check]) {
        for check in checks {
            print("  \(DoctorTerminalStyle.marker(check.level, color: color)) \(check.name): \(check.detail)")
            if let fix = check.fix { print("         ↳ fix: \(fix)") }
        }
    }

    /// The add-on's own plan from `install.sh --plan`, which verifies the
    /// release and sizes this Mac without installing anything. Nil, for the
    /// fallback, from an installer without plan mode (it names no `--plan`),
    /// a failed run or one without a `plan` event.
    private func requestAddonPlan(_ installer: URL, script: Data) async throws -> SandboxSizingPlan? {
        guard SandboxInstaller.supportsPlan(script) else { return nil }
        let output = SandboxOutputTail()
        let exit = try await SandboxChildProcess.run(
            Self.shell, [installer.path] + SandboxInstaller.planArguments(options),
            currentDirectory: installer.deletingLastPathComponent(), closeStandardInput: true,
            standardOutput: .tail(output), standardError: .tail(SandboxOutputTail()))
        // Ctrl-C or a signal stops setup; it never goes on to install.
        if exit.interrupted || exit.signal != nil {
            print("")
            print("Setup stopped. Nothing changed.")
            throw ExitCode(exit.interrupted ? 130 : 1)
        }
        guard exit.succeeded else { return nil }
        return output.lastLines(.max).compactMap(SandboxSizingPlan.init(line:)).last
    }

    static var tradeOff: [String] {
        [
            "What changes",
            "  • While a sandbox job runs, inference pauses: your provider finishes the requests in progress,",
            "    unloads its models and takes no new requests until the job ends.",
            "  • You earn each job's price minus a 10% fee, paid into your Darkbloom balance.",
            "  • Jobs run in isolated Linux and macOS VMs. The add-on lives in ~/DarkbloomSandbox and downloads",
            "    the VM images its jobs need (their sizes are under Disk above).",
            "  • You approve this Mac once, in your browser, signed in to your Darkbloom account.",
            "  Keep this Mac plugged in, awake and logged in.",
            "  Docs: \(Sandbox.docsURL)",
        ]
    }

    // MARK: - Install

    /// Downloads the installer into a new owner-only directory for `body`,
    /// then removes it.
    private func withInstaller(_ body: (_ installer: URL, _ script: Data) async throws -> Void) async throws {
        guard let url = SandboxInstaller.scriptURL(server: options.server) else {
            throw ValidationError("--server must be an https URL, such as \(Sandbox.defaultServer)")
        }
        let script: Data
        do {
            script = try await SandboxInstaller.download(url)
        } catch let failure as SandboxInstaller.Failure {
            printError("\(failure) Check this Mac's connection, then run `\(cli) sandbox setup` again.")
            throw ExitCode.failure
        }
        let installer = try SandboxInstaller.stage(script)
        defer { try? FileManager.default.removeItem(at: installer.deletingLastPathComponent()) }
        try await body(installer, script)
    }

    private func install(_ installer: URL, script: Data) async throws {
        let jsonProgress = SandboxInstaller.supportsJSONProgress(script)
        let arguments = [installer.path] + SandboxInstaller.arguments(options, jsonProgress: jsonProgress)
        let directory = installer.deletingLastPathComponent()
        print("")
        let exit: SandboxChildProcess.Exit
        var summary: SandboxInstallerEvent?
        if jsonProgress {
            (exit, summary) = try await runWithProgress(arguments, directory: directory)
        } else {
            print("This version of the installer does not report its steps to the CLI; its own output follows.")
            if options.noBrowser || options.waitReady { print("It does not support --no-browser or --wait-ready.") }
            print("")
            exit = try await SandboxChildProcess.run(Self.shell, arguments, currentDirectory: directory)
        }
        guard exit.succeeded else {
            print("")
            print(Self.advice(exit))
            throw ExitCode(exit.interrupted ? 130 : exit.signal == nil && exit.status != 0 ? exit.status : 1)
        }
        printSummary(installer: summary)
    }

    static let shell = URL(fileURLWithPath: "/bin/sh")

    /// What a failed or stopped installer means for the owner, by its exit status.
    static func advice(_ exit: SandboxChildProcess.Exit) -> String {
        let rerun = "`\(Sandbox.cli) sandbox setup`"
        if exit.interrupted {
            return "Setup stopped. An enrollment waiting for approval goes on; run \(rerun) again to follow it."
        }
        switch exit.signal == nil ? exit.status : 1 {
        case 2: return "This Mac cannot host Darkbloom Sandbox as it is; see why above."
        case 3: return "This Mac was not enrolled: the code was denied or expired, or the waitlist request ended. "
            + "Run \(rerun) to start again."
        case 4: return "Jobs are running on this Mac. Run \(rerun) again once they finish; "
            + "`\(Sandbox.cli) sandbox pause` keeps new ones from starting."
        default: return "Setup did not finish. When the problem above is fixed, run \(rerun) again; it is safe to rerun."
        }
    }

    private func runWithProgress(_ arguments: [String], directory: URL) async throws
        -> (SandboxChildProcess.Exit, SandboxInstallerEvent?)
    {
        let renderer = SandboxSetupRenderer(interactive: terminal, color: color)
        let errors = SandboxOutputTail()
        let spinner: Task<Void, Never>? = terminal ? Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                renderer.tick()
            }
        } : nil
        // Also when the installer cannot even be launched.
        defer { spinner?.cancel() }
        let exit = try await SandboxChildProcess.run(
            Self.shell, arguments, currentDirectory: directory, closeStandardInput: true,
            standardOutput: .lines { line in
                if let output = SandboxInstallerOutput(line: line) { renderer.handle(output) }
            },
            standardError: .tail(errors))
        spinner?.cancel()
        await spinner?.value
        if exit.succeeded {
            renderer.finish(.succeeded)
        } else if exit.interrupted {
            renderer.finish(.interrupted)
        } else {
            // The installer writes its error to stderr as `error: …` too; the renderer drops repeats.
            renderer.finish(.failed(status: exit.status, errors: errors.lastLines(5)))
        }
        return (exit, renderer.summary)
    }

    // MARK: - Summary

    private func printSummary(installer: SandboxInstallerEvent?) {
        print("")
        guard case .status(let status, _) = addon.queryStatus(timeout: Sandbox.statusTimeout), status.installed else {
            print("Done. Check this Mac with `\(cli) sandbox status`.")
            return
        }
        Self.summary(status, installer: installer, server: options.server, color: color).forEach { print($0) }
    }

    /// The add-on's state now, the slots the installer chose (from its
    /// summary event, else the configured totals) and the next commands.
    static func summary(_ status: SandboxAddonStatus, installer: SandboxInstallerEvent? = nil, server: String,
                        color: Bool) -> [String] {
        let cli = Sandbox.cli
        let headline = SandboxStatusView.headline(status)
        var lines = ["Darkbloom Sandbox is set up on this Mac: "
            + DoctorTerminalStyle.verdict(headline.text, level: headline.level, color: color)]
        lines.append("  " + SandboxStatusView.explanation(status))
        let slots: [String] = [("Linux", installer?.linuxSlots, status.linux), ("macOS", installer?.macOSSlots, status.macOS)]
            .compactMap { name, choice, configured in
                guard let count = choice?.count ?? configured?.total, count > 0 else { return nil }
                guard let choice else { return "\(count) \(name)" }
                return "\(count) \(name) (" + (choice.automatic ? "automatic" + (choice.limit.map { ", limited by \($0)" } ?? "")
                    : "your choice") + ")"
            }
        if !slots.isEmpty { lines.append("  Jobs at a time: \(slots.joined(separator: ", "))") }
        lines += [
            "",
            "Next",
            "  \(cli) sandbox status    see jobs, slots and images",
            "  \(cli) sandbox pause     let running jobs finish and take no new ones",
            "  \(cli) sandbox logs -f   follow the add-on's log",
            "  Console: \(status.consoleURL ?? installer?.consoleURL ?? server) (jobs; earnings under Billing → Earnings)",
            "  Keep this Mac plugged in, awake and logged in.",
        ]
        return lines
    }
}
