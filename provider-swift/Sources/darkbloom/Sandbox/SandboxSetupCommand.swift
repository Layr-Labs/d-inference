import ArgumentParser
import Darwin
import Foundation
import ProviderCore

extension Sandbox {
    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check this Mac, then install the add-on and enroll this Mac. Safe to run again.",
            discussion: """
            Checks that Darkbloom approved your account from the Darkbloom Sandbox waitlist (and offers to \
            join it) and checks this Mac. It then downloads the add-on's installer from the Darkbloom Sandbox \
            service over HTTPS and asks it for the add-on's plan: how many jobs this Mac can run at a time and \
            the disk they take. It explains what changes and asks before installing anything. The installer \
            then verifies the release, installs it in ~/DarkbloomSandbox, and enrolls this Mac once you approve \
            it in your browser.

            Running it again reports the current state, continues an unfinished setup, repairs or updates \
            the add-on, or applies new slot counts or work disks. On a Mac that is set up, it asks the \
            installer's plan again and offers the add-on's slot counts when they differ from the installed \
            ones; with --yes or without a terminal it applies them only when they add slots and remove none.

            With --disk, the VM images and jobs go on that drive instead of the internal disk; the add-on, \
            its settings and logs stay in ~/DarkbloomSandbox. Without --disk, at a prompt, setup lists the \
            external APFS drives with room for jobs and asks which one to use (Enter keeps the internal \
            disk). The drive must be APFS with ownership on: setup checks both first. When ownership is off \
            it prints the command and, at a prompt, offers to run it (sudo asks for your password). Setup \
            never formats a drive. Work disks need add-on \(SandboxWorkDisk.minimumAddonVersion) or later.
            """)

        @Flag(name: .shortAndLong, help: "Don't ask for confirmation.")
        var yes = false

        @Flag(help: "Don't open the browser for approval; open the printed link yourself.")
        var noBrowser = false

        @Option(help: "Linux jobs to run at a time (0-16). Default: what fits this Mac.")
        var linuxSlots: Int?

        @Option(name: .customLong("macos-slots"), help: "macOS jobs to run at a time (0-2). Default: what fits this Mac.")
        var macOSSlots: Int?

        @Option(name: .customLong("disk"), help: ArgumentHelp(
            "A drive for the VM images and jobs, such as /Volumes/FastSSD (APFS, ownership on). Repeat for "
                + "more drives; add ~ to keep using the internal disk too.",
            valueName: "volume"))
        var disks: [String] = []

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
            if disks.contains(where: \.isEmpty) {
                throw ValidationError("--disk needs a drive, such as /Volumes/FastSSD")
            }
        }

        var options: SandboxSetupOptions {
            SandboxSetupOptions(server: server, noBrowser: noBrowser, waitReady: waitReady,
                                linuxSlots: linuxSlots, macOSSlots: macOSSlots,
                                disks: disks.map { SandboxWorkDisk.absolutePath($0) })
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
    /// Set up already; report it, then offer the add-on's plan when its slot
    /// counts differ.
    case alreadySetUp(SandboxAddonStatus)
    /// Run the installer over the existing install, for this reason.
    case rerun(String)
    /// A first setup: check eligibility and ask first.
    case fresh

    static func decide(_ query: SandboxAddonQuery, changingSlots: Bool, changingDisks: Bool = false)
        -> SandboxSetupPlan
    {
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
                let changes = [changingSlots ? "slot counts" : nil, changingDisks ? "work disks" : nil].compactMap { $0 }
                return changes.isEmpty ? .alreadySetUp(status)
                    : .rerun("Applying the new \(changes.joined(separator: " and ")).")
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
    /// The volume of each `--disk`.
    var workDiskVolume: @Sendable (String) -> SandboxWorkDisk.Volume? = SandboxWorkDisk.volume(at:)
    /// The drives to offer when the owner gives no `--disk`.
    var workDiskCandidates: @Sendable () -> [SandboxWorkDisk.Volume] = { SandboxWorkDisk.candidates() }
    /// Turns ownership on for the drive mounted there (`sudo diskutil
    /// enableOwnership`) on this terminal; true when it did.
    var enableOwnership: @Sendable (String) -> Bool = { SandboxWorkDisk.enableOwnership(mountPoint: $0) }
    /// The coordinator's waitlists; a first setup requires the account to be
    /// approved from the Darkbloom Sandbox waitlist.
    var waitlist: FeatureWaitlistAccess = .live()

    private var cli: String { Sandbox.cli }

    func run() async throws {
        let existing = addon.queryStatus(timeout: Sandbox.statusTimeout)
        let changingSlots = options.linuxSlots != nil || options.macOSSlots != nil
        switch SandboxSetupPlan.decide(existing, changingSlots: changingSlots, changingDisks: !options.disks.isEmpty) {
        case .alreadySetUp(let status):
            try await reportAndRecheckSizing(status)
        case .rerun(let reason):
            print(reason)
            if !options.disks.isEmpty {
                print("")
                print(DoctorTerminalStyle.heading("Checking the work disks", color: color))
                try checkWorkDisks(options.disks)
            }
            try await withInstaller { try await install($0, script: $1, options: options) }
        case .fresh:
            try await requireApproval()
            let eligibility = try await checkMac()
            try await withInstaller { installer, script in
                let chosen = try chooseWorkDisk(script: script)
                guard try await sizeAndConfirm(eligibility, installer: installer, script: script, options: chosen)
                else { return }
                try await install(installer, script: script, options: chosen)
            }
        }
    }

    // MARK: - Already set up

    private static let changeCountsHint = "To change how many jobs run at a time: \(Sandbox.cli) sandbox setup "
        + "--linux-slots <n> --macos-slots <n>"

    /// The ways to change the install: the slot counts, and work disks
    /// only when the installed add-on takes them.
    private func printChangeHints(_ status: SandboxAddonStatus) {
        print(Self.changeCountsHint)
        guard status.supportsWorkDisks else { return }
        print("To put the VM images and jobs on an external drive: \(cli) sandbox setup --disk /Volumes/<name>")
    }

    /// Reports the install, then asks the installer's `--plan` how many jobs
    /// this Mac fits now and offers what differs. Changes nothing unless the
    /// owner agrees, or, without a prompt, the plan only adds slots. Skipped
    /// while jobs run: the installer changes slots only while none does, and
    /// their disk would shrink the plan.
    private func reportAndRecheckSizing(_ status: SandboxAddonStatus) async throws {
        print("Darkbloom Sandbox is already set up on this Mac.")
        print("")
        SandboxStatusView.lines(status, color: color).forEach { print($0) }
        print("")
        guard status.jobsRunning == 0 else {
            printChangeHints(status)
            print("Jobs are running, so setup did not check whether this Mac now fits other slot counts. Run "
                + "`\(cli) sandbox setup` again once they finish; `\(cli) sandbox pause` keeps new ones from starting.")
            return
        }
        try await withInstaller(ifUnavailable: { failure in
            printChangeHints(status)
            print("Could not check whether this Mac now fits other slot counts: \(failure)")
        }) { installer, script in
            let plan = try await withTransientNote("Checking how many jobs this Mac fits now…") {
                try await requestAddonPlan(installer, script: script, options: options)
            }
            // The same counts (or no plan to compare) keep today's report exactly.
            guard let plan, let change = SandboxSlotChange(installed: status, plan: plan) else {
                printChangeHints(status)
                return
            }
            guard offer(change, plan: plan) else { return }
            print("")
            try await install(installer, script: script, options: change.applying(to: options))
        }
    }

    /// Shows the add-on's plan against the installed counts; true to apply it.
    /// With a prompt the default is yes. Without one (`--yes`, or no
    /// terminal) it applies only a change that adds slots and removes none.
    private func offer(_ change: SandboxSlotChange, plan: SandboxSizingPlan) -> Bool {
        print("The add-on's plan for this Mac now:")
        printChecks(plan.checks)
        if let note = plan.freeSpaceNote { print("  " + note) }
        print("")
        guard !confirmed, interactiveInput else {
            print(change.headline)
            guard change.onlyAdds else {
                print("Not applied: it removes slots, and without a prompt setup applies only a plan that adds "
                    + "slots. To apply it: \(change.command)")
                return false
            }
            print("Applying it: it only adds slots.")
            return true
        }
        // The installer stops the agent only between jobs: it refuses (exit 4), it does not wait.
        guard SandboxTerminal.confirm(change.headline + " If a job is running, the installer refuses and changes "
            + "nothing. Apply?", defaultYes: true) else {
            print("Nothing changed. To apply it later: \(change.command)")
            return false
        }
        return true
    }

    /// Runs `body` with `note` on the running line of a terminal, erased
    /// afterwards; elsewhere prints nothing.
    private func withTransientNote<T>(_ note: String, _ body: () async throws -> T) async rethrows -> T {
        guard terminal else { return try await body() }
        SandboxTerminal.write(note)
        defer { SandboxTerminal.write("\r\u{1B}[2K") }
        return try await body()
    }

    // MARK: - Waitlist

    /// The Darkbloom Sandbox waitlist's id in the coordinator's catalog.
    static let waitlistFeature = "sandbox"
    /// Names the waitlist when the coordinator gave no answer; an answer
    /// brings the coordinator's own title.
    static let waitlistTitle = "Darkbloom Sandbox"

    /// Darkbloom Sandbox is open to the accounts Darkbloom approves from its
    /// waitlist, so a first setup goes on only as `FeatureWaitlistGate` lets
    /// it; nothing is installed until Darkbloom approves the account.
    private func requireApproval() async throws {
        try await FeatureWaitlistGate(
            feature: Self.waitlistFeature, fallbackTitle: Self.waitlistTitle, setupCommand: "\(cli) sandbox setup",
            unchanged: "Nothing was installed.", access: waitlist, joinWithoutAsking: confirmed,
            ask: interactiveInput ? { SandboxTerminal.confirm($0) } : nil
        ).require()
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
        try checkWorkDisks(options.disks)
        return eligibility
    }

    /// Prints a `Work disk` line per disk; throws, before anything is
    /// installed, when one is not ready. At a prompt it offers to turn
    /// ownership on (sudo asks for the password), then checks that disk
    /// again; the other fixes are the owner's. Setup never formats a drive.
    private func checkWorkDisks(_ disks: [String]) throws {
        var ready = true
        for path in disks {
            let volume = workDiskVolume(path)
            let check = SandboxWorkDisk.check(path: path, volume: volume)
            printChecks([check])
            guard check.level == .fail else { continue }
            if let mount = ownershipToTurnOn(path, on: volume), turnOnOwnership(mount) {
                let again = SandboxWorkDisk.check(path: path, volume: workDiskVolume(path))
                printChecks([again])
                if again.level != .fail { continue }
            }
            ready = false
        }
        guard !ready else { return }
        print("")
        print(DoctorTerminalStyle.verdict("A work disk is not ready: follow the fix above, then run setup again. "
            + "Nothing changed.", level: .fail, color: color))
        throw ExitCode.failure
    }

    /// The mount point of the drive at `path` (on `volume`) when its one
    /// problem is ownership off and there is a prompt to offer the fix at.
    private func ownershipToTurnOn(_ path: String, on volume: SandboxWorkDisk.Volume?) -> String? {
        guard !confirmed, interactiveInput, let volume,
              SandboxWorkDisk.problem(path: path, volume: volume) == .ownershipOff else { return nil }
        return volume.mountPoint
    }

    /// Asks, then runs the fix for ownership off; true when it ran and exited 0.
    private func turnOnOwnership(_ mount: String) -> Bool {
        guard SandboxTerminal.confirm("Turn ownership on for \(mount) now? Setup runs the command above; sudo asks "
            + "for your password.") else { return false }
        guard enableOwnership(mount) else {
            print("Ownership is still off on \(mount).")
            return false
        }
        return true
    }

    /// Without `--disk`, at a prompt, and from a release with work disks:
    /// lists the external drives that could take the VM images and jobs and
    /// asks which one to use. Enter (or no drive to offer) keeps the internal
    /// disk. Returns the options with the chosen drive, checked.
    private func chooseWorkDisk(script: Data) throws -> SandboxSetupOptions {
        guard options.disks.isEmpty, !confirmed, interactiveInput, SandboxInstaller.supportsDisks(script) else {
            return options
        }
        let drives = workDiskCandidates()
        guard !drives.isEmpty else { return options }
        print("")
        print(DoctorTerminalStyle.heading("Where the VM images and jobs go", color: color))
        print("  1) This Mac's internal disk")
        for (index, drive) in drives.enumerated() {
            let note = drive.ignoresOwnership ? "; ownership is off, setup can turn it on" : ""
            print("  \(index + 2)) \(drive.mountPoint): \(drive.freeBytes / SandboxEligibility.gib) GiB free\(note)")
        }
        print("  Use an external drive only if it is a Thunderbolt or USB4 NVMe SSD that stays connected: a job on "
            + "a drive that goes away is stopped and not paid.")
        let choice = SandboxTerminal.choose(count: drives.count + 1)
        var chosen = options
        if choice > 1 {
            chosen.disks = [drives[choice - 2].mountPoint]
            print("")
            print(DoctorTerminalStyle.heading("Checking the work disks", color: color))
            try checkWorkDisks(chosen.disks)
        }
        // The plan's lines follow; they no longer sit under "Checking this Mac".
        print("")
        print(DoctorTerminalStyle.heading("The add-on's plan for this Mac", color: color))
        return chosen
    }

    /// Prints the add-on's plan (else the fallback estimate) and the
    /// trade-off, then asks. False when the owner declines; throws when no job
    /// fits.
    private func sizeAndConfirm(_ eligibility: SandboxEligibility, installer: URL, script: Data,
                                options: SandboxSetupOptions) async throws -> Bool {
        let reportedPlan = try await requestAddonPlan(installer, script: script, options: options)
        let plan: SandboxSizingPlan
        if let reportedPlan {
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
        // The add-on's plan only: the fallback estimate's report stays as it was.
        if let note = reportedPlan?.freeSpaceNote { print("  " + note) }
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
    private func requestAddonPlan(_ installer: URL, script: Data, options: SandboxSetupOptions) async throws
        -> SandboxSizingPlan?
    {
        guard SandboxInstaller.supportsPlan(script) else { return nil }
        let output = SandboxOutputTail()
        let errors = SandboxOutputTail()
        let exit = try await SandboxChildProcess.run(
            Self.shell, [installer.path] + SandboxInstaller.planArguments(options),
            currentDirectory: installer.deletingLastPathComponent(), closeStandardInput: true,
            standardOutput: .tail(output), standardError: .tail(errors))
        // Ctrl-C or a signal stops setup; it never goes on to install.
        if exit.interrupted || exit.signal != nil {
            print("")
            print("Setup stopped. Nothing changed.")
            throw ExitCode(exit.interrupted ? 130 : 1)
        }
        guard exit.succeeded else {
            // The CLI's estimate knows no work disks, and the installer
            // refuses a disk it cannot use (exit 2) with the fix on stderr.
            guard options.disks.isEmpty else {
                print("")
                errors.lastLines(5).forEach { print("  \($0)") }
                print(DoctorTerminalStyle.verdict("The installer's plan failed with these work disks; fix what it "
                    + "says above, then run setup again. Nothing changed.", level: .fail, color: color))
                throw ExitCode(exit.status > 0 ? exit.status : 1)
            }
            return nil
        }
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
    /// then removes it. A failed download goes to `ifUnavailable` when given,
    /// else fails setup.
    private func withInstaller(ifUnavailable: ((SandboxInstaller.Failure) -> Void)? = nil,
                               _ body: (_ installer: URL, _ script: Data) async throws -> Void) async throws {
        guard let url = SandboxInstaller.scriptURL(server: options.server) else {
            throw ValidationError("--server must be an https URL, such as \(Sandbox.defaultServer)")
        }
        let script: Data
        do {
            script = try await SandboxInstaller.download(url)
        } catch let failure as SandboxInstaller.Failure {
            if let ifUnavailable { return ifUnavailable(failure) }
            printError("\(failure) Check this Mac's connection, then run `\(cli) sandbox setup` again.")
            throw ExitCode.failure
        }
        guard options.disks.isEmpty || SandboxInstaller.supportsDisks(script) else {
            printError("The add-on release that \(options.server) offers does not support --disk: work disks need "
                + "add-on \(SandboxWorkDisk.minimumAddonVersion) or later. Nothing changed. Run "
                + "`\(cli) sandbox setup` without --disk, or with it once that release is available.")
            throw ExitCode.failure
        }
        let installer = try SandboxInstaller.stage(script)
        defer { try? FileManager.default.removeItem(at: installer.deletingLastPathComponent()) }
        try await body(installer, script)
    }

    private func install(_ installer: URL, script: Data, options: SandboxSetupOptions) async throws {
        let jsonProgress = SandboxInstaller.supportsJSONProgress(script)
        let arguments = [installer.path] + SandboxInstaller.arguments(options, jsonProgress: jsonProgress)
        let directory = installer.deletingLastPathComponent()
        print("")
        let exit: SandboxChildProcess.Exit
        var summary: SandboxInstallerEvent?
        var waitsInBackground = false
        if jsonProgress {
            (exit, summary, waitsInBackground) = try await runWithProgress(arguments, directory: directory)
        } else {
            print("This version of the installer does not report its steps to the CLI; its own output follows.")
            if options.noBrowser || options.waitReady { print("It does not support --no-browser or --wait-ready.") }
            print("")
            exit = try await SandboxChildProcess.run(Self.shell, arguments, currentDirectory: directory)
        }
        guard exit.succeeded else {
            print("")
            print(Self.advice(exit, waitsInBackground: waitsInBackground))
            throw ExitCode(exit.interrupted ? 130 : exit.signal == nil && exit.status != 0 ? exit.status : 1)
        }
        printSummary(installer: summary)
    }

    static let shell = URL(fileURLWithPath: "/bin/sh")

    /// What a failed or stopped installer means for the owner, by its exit
    /// status. A stop while this Mac waits for approval in the background
    /// (`SandboxSetupRenderer.waitsInBackground`) says that the wait goes on.
    static func advice(_ exit: SandboxChildProcess.Exit, waitsInBackground: Bool) -> String {
        let rerun = "`\(Sandbox.cli) sandbox setup`"
        if exit.interrupted {
            guard waitsInBackground else {
                return "Setup stopped. An enrollment waiting for approval goes on; run \(rerun) again to follow it."
            }
            return "Setup stopped. This Mac keeps waiting for approval in the background, also across restarts, "
                + "and enrolls by itself once approved; `\(Sandbox.cli) sandbox status` shows where it is."
        }
        switch exit.signal == nil ? exit.status : 1 {
        case 2: return "This Mac cannot host Darkbloom Sandbox as it is; see why above."
        case 3: return "This Mac was not enrolled: the code was denied or expired, or the waitlist request ended. "
            + "Run \(rerun) to start again."
        // The installer refuses rather than waits; its --force would stop the jobs unpaid.
        case 4: return "A job is running on this Mac, so the installer changed nothing. Run \(rerun) again when it "
            + "finishes; `\(Sandbox.cli) sandbox pause` keeps new jobs from starting. Setup never passes the "
            + "installer's --force: it would stop running jobs, and stopped jobs aren't paid."
        default: return "Setup did not finish. When the problem above is fixed, run \(rerun) again; it is safe to rerun."
        }
    }

    /// Runs a `--json-progress` installer and renders its events. Returns its
    /// exit, its `summary` event and whether this Mac waits for approval in
    /// the background.
    private func runWithProgress(_ arguments: [String], directory: URL) async throws
        -> (exit: SandboxChildProcess.Exit, summary: SandboxInstallerEvent?, waitsInBackground: Bool)
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
        return (exit, renderer.summary, renderer.waitsInBackground)
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
