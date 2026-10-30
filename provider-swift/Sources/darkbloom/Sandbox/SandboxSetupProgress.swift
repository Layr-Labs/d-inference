import Darwin
import Foundation
import ProviderCore

/// One stdout line of `install.sh --json-progress` (schema 1): a JSON event,
/// or any other text, which is shown as it is.
enum SandboxInstallerOutput: Equatable, Sendable {
    case event(SandboxInstallerEvent)
    case text(String)

    init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("{"), let event = SandboxInstallerEvent(json: trimmed) else {
            self = .text(trimmed)
            return
        }
        self = .event(event)
    }
}

/// The add-on installer's progress contract: `{"event":"stage","stage":…,
/// "status":"started|progress|done|failed","message":…}` per stage event, the
/// stage's own fields beside them, then one `{"event":"summary",…}` when the
/// run succeeds. New fields and events may appear; unknown ones are ignored.
struct SandboxInstallerEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case stage, summary, other(String) }
    enum Status: Equatable, Sendable {
        case started, progress, done, failed
        case other(String)

        init(_ raw: String?) {
            switch raw {
            case "started": self = .started
            case "progress": self = .progress
            case "done": self = .done
            case "failed": self = .failed
            default: self = .other(raw ?? "")
            }
        }
    }

    /// The installer's own choice for one platform, from the summary.
    struct SlotChoice: Equatable, Sendable {
        var count: Int
        var automatic: Bool
        var limit: String?
    }

    var kind: Kind
    /// The stage id: `checking_mac`, `verifying_release`, `installing`,
    /// `waiting_for_approval`, `enrolled`, `starting`, `downloading_images`, `ready`.
    var stage: String?
    var status: Status = .other("")
    /// One line for people (a stage's title when it starts, its result when done).
    var message: String?
    var exitCode: Int?
    // `waiting_for_approval`
    var userCode: String?
    var verificationURI: String?
    var verificationURIComplete: String?
    var browserOpened: Bool?
    var waitlisted = false
    // `downloading_images` with `--wait-ready`
    var progress: Double?
    // `summary`
    var hostID: String?
    var consoleURL: String?
    var linuxSlots: SlotChoice?
    var macOSSlots: SlotChoice?

    init(kind: Kind, stage: String? = nil, status: Status = .other(""), message: String? = nil) {
        self.kind = kind
        self.stage = stage
        self.status = status
        self.message = message
    }

    init?(json: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        func text(_ key: String) -> String? {
            (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func choice(_ key: String) -> SlotChoice? {
            guard let slots = object["slots"] as? [String: Any], let entry = slots[key] as? [String: Any],
                  let count = entry["count"] as? Int else { return nil }
            return SlotChoice(count: count, automatic: entry["automatic"] as? Bool ?? true,
                              limit: entry["limit"] as? String)
        }
        switch event {
        case "stage": self.init(kind: .stage, stage: text("stage"), status: Status(object["status"] as? String),
                                message: text("message"))
        case "summary": self.init(kind: .summary, message: text("message"))
        default: self.init(kind: .other(event), message: text("message"))
        }
        exitCode = object["exit_code"] as? Int
        userCode = text("user_code")
        verificationURI = text("verification_uri")
        verificationURIComplete = text("verification_uri_complete")
        browserOpened = object["browser_opened"] as? Bool
        waitlisted = object["waitlisted"] as? Bool ?? false
        progress = (object["progress"] as? Double).map { min(max($0, 0), 1) }
        hostID = text("host_id")
        consoleURL = text("console_url")
        linuxSlots = choice("linux")
        macOSSlots = choice("macos")
    }

    /// The CLI's name for a stage; an unknown stage keeps the installer's words.
    static func title(stage: String?, message: String?) -> String {
        switch stage {
        case "checking_mac": return "Checking this Mac"
        case "verifying_release": return "Verifying release"
        case "installing": return "Installing"
        case "waiting_for_approval": return "Waiting for approval"
        case "enrolled": return "Enrolled"
        case "starting": return "Starting"
        case "downloading_images": return "Downloading images"
        case "ready": return "Ready"
        default: return message ?? stage.map { $0.replacingOccurrences(of: "_", with: " ").capitalized } ?? "Setup"
        }
    }
}

/// The add-on's own slot plan: the one `{"schema":1,"event":"plan",…}` line
/// that `install.sh --plan --json-progress` (add-on 1.1.1 and later) prints
/// once it has verified the release and run the add-on's checks and sizing,
/// installing nothing. Disk: the floor stays free, a platform's first slot
/// costs its VM images and one job's disk, each further slot one job's disk.
struct SandboxSizingPlan: Equatable, Sendable {
    struct Platform: Equatable, Sendable {
        var slots: Int
        /// False when the owner chose `slots`.
        var automatic = true
        /// What capped `slots`, in the add-on's words (`free disk space`).
        var limit: String?
        /// Disk its VM images take; 0 when they are installed.
        var imagesBytes: Int64
        /// Disk each job takes: a Linux job's scratch disk, a macOS job's budget.
        var slotBytes: Int64
    }

    /// The add-on's one-line result, such as `1 Linux slot`.
    var message: String?
    var linux: Platform
    var macOS: Platform
    var freeBytes: Int64
    /// Free space that stays the owner's.
    var floorBytes: Int64
    var cores: Int
    var coresKept: Int
    var memoryBytes: Int64
    var memoryKeptBytes: Int64
    /// Memory kept for a running inference provider.
    var providerMemoryBytes: Int64
}

extension SandboxSizingPlan {
    /// The `plan` event in one stdout line. Unknown members are ignored;
    /// another schema or event, or a missing number, is not a plan.
    init?(line: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["schema"] as? Int == 1, object["event"] as? String == "plan" else { return nil }
        func platform(_ name: String) -> Platform? {
            guard let slots = object["\(name)_slots"] as? Int, let images = object["\(name)_images_bytes"] as? Int64,
                  let slot = object["\(name)_slot_bytes"] as? Int64 else { return nil }
            return Platform(slots: slots, automatic: object["\(name)_automatic"] as? Bool ?? true,
                            limit: object["\(name)_limit"] as? String, imagesBytes: images, slotBytes: slot)
        }
        guard let linux = platform("linux"), let macOS = platform("macos"),
              let free = object["free_bytes"] as? Int64, let floor = object["floor_bytes"] as? Int64,
              let cores = object["cores"] as? Int, let coresKept = object["cores_kept"] as? Int,
              let memory = object["memory_bytes"] as? Int64, let memoryKept = object["memory_kept_bytes"] as? Int64,
              let providerMemory = object["provider_memory_bytes"] as? Int64 else { return nil }
        self.init(message: object["message"] as? String, linux: linux, macOS: macOS, freeBytes: free,
                  floorBytes: floor, cores: cores, coresKept: coresKept, memoryBytes: memory,
                  memoryKeptBytes: memoryKept, providerMemoryBytes: providerMemory)
    }
}

/// Renders installer events as the CLI's stage list, each stage's one-line
/// results under it:
///
///     ✓ Checking this Mac
///       Apple M4 Max, 16 cores, 128 GB memory, macOS 27.0.1
///     ⠋ Waiting for approval
///
/// On a terminal the running stage is the last line, with a spinner, and
/// turns into ✓ (or ✗) when it ends; elsewhere each stage prints once, when it
/// ends. What needs the owner now (the approval link and code, the waitlist)
/// prints at once, above the running stage.
final class SandboxSetupRenderer: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case succeeded
        /// The installer's exit status and the end of its stderr.
        case failed(status: Int32, errors: [String])
        case interrupted
    }

    static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private struct Stage {
        let id: String?
        let title: String
        var details: [String] = []
        var waitlisted = false
        var progress: Double?
    }

    private let lock = NSLock()
    private let interactive: Bool
    private let color: Bool
    private let width: @Sendable () -> Int
    private let write: @Sendable (String) -> Void
    private var active: Stage?
    private var lineDrawn = false
    private var frame = 0
    private var approvalShown = false
    private var waitlistShown = false
    private var reportedTenths = -1
    private var failure: String?
    private var summaryEvent: SandboxInstallerEvent?

    init(interactive: Bool, color: Bool, width: @escaping @Sendable () -> Int = SandboxTerminal.width,
         write: @escaping @Sendable (String) -> Void = SandboxTerminal.write) {
        self.interactive = interactive
        self.color = color
        self.width = width
        self.write = write
    }

    /// The run's `summary` event, if it succeeded with one.
    var summary: SandboxInstallerEvent? { lock.withLock { summaryEvent } }

    func handle(_ output: SandboxInstallerOutput) {
        render { out in
            switch output {
            case .text(let text): emit("    \(text)", into: &out)
            case .event(let event): apply(event, into: &out)
            }
        }
    }

    /// Advances the spinner; a no-op off a terminal.
    func tick() {
        guard interactive else { return }
        render { _ in frame += 1 }
    }

    func finish(_ outcome: Outcome) {
        render { out in
            switch outcome {
            case .succeeded:
                if let stage = active { complete(stage, marker: done, into: &out) }
            case .failed(let status, let errors):
                let others = errors.filter { line in
                    guard let failure else { return true }
                    return !line.contains(failure) && !failure.contains(line)
                }
                if failure == nil || active != nil {
                    var stage = active ?? Stage(id: nil, title: "Setup failed")
                    if others.isEmpty, failure == nil { stage.details.append("The installer exited with status \(status).") }
                    complete(stage, marker: failed, into: &out)
                }
                others.forEach { emit("    \($0)", into: &out) }
            case .interrupted:
                if let stage = active { complete(stage, marker: failed, suffix: " (stopped)", into: &out) }
            }
            active = nil
        }
    }

    // MARK: - Under the lock

    private var done: String { DoctorTerminalStyle.verdict("✓", level: .pass, color: color) }
    private var failed: String { DoctorTerminalStyle.verdict("✗", level: .fail, color: color) }

    /// Runs `body` and writes its output in one piece, with the running
    /// stage's line redrawn last. The write stays under the lock: a spinner
    /// tick and an event must reach the terminal in the order they were drawn.
    private func render(_ body: (inout String) -> Void) {
        lock.withLock {
            var out = ""
            body(&out)
            erase(into: &out)
            if interactive, let stage = active {
                let symbol = DoctorTerminalStyle.heading(Self.spinner[frame % Self.spinner.count], color: color)
                out += "  \(symbol) " + clipped(runningTitle(stage), to: width() - 5)
                lineDrawn = true
            }
            if !out.isEmpty { write(out) }
        }
    }

    private func apply(_ event: SandboxInstallerEvent, into out: inout String) {
        switch event.kind {
        case .summary:
            summaryEvent = event
            return
        case .other:
            return
        case .stage:
            begin(event, into: &out)
        }
        switch event.status {
        case .started:
            break
        case .done, .failed:
            let isFailure = event.status == .failed
            if isFailure { failure = event.message }
            if var stage = active {
                if let message = event.message { stage.details.append(message) }
                complete(stage, marker: isFailure ? failed : done, into: &out)
                active = nil
            }
        case .progress, .other:
            progress(event, into: &out)
        }
    }

    /// Makes `event`'s stage the running one, closing another first. An
    /// event without a stage belongs to the running one.
    private func begin(_ event: SandboxInstallerEvent, into out: inout String) {
        if let stage = active, stage.id == event.stage || event.stage == nil { return }
        if let stage = active { complete(stage, marker: done, into: &out) }
        let title = SandboxInstallerEvent.title(stage: event.stage,
                                                message: event.status == .started ? event.message : nil)
        active = Stage(id: event.stage, title: title)
        reportedTenths = -1
    }

    private func progress(_ event: SandboxInstallerEvent, into out: inout String) {
        if event.userCode != nil || event.verificationURI != nil {
            showApproval(event, into: &out)
        } else if event.waitlisted {
            active?.waitlisted = true
            showWaitlist(into: &out)
        } else if let fraction = event.progress {
            active?.progress = fraction
            // A terminal shows it on the running line; elsewhere every tenth prints.
            let tenths = Int((fraction * 10).rounded(.down))
            if !interactive, tenths > reportedTenths, tenths < 10 {
                reportedTenths = tenths
                emit("    Downloading images \(SandboxStatusView.percent(fraction))", into: &out)
            }
        } else if let message = event.message {
            active?.details.append(message)
        }
    }

    private func showApproval(_ event: SandboxInstallerEvent, into out: inout String) {
        guard !approvalShown else { return }
        approvalShown = true
        let link = event.verificationURIComplete ?? event.verificationURI ?? "the Darkbloom Sandbox console's /device page"
        emit("", into: &out)
        emit("    Approve this Mac in your browser, signed in to the Darkbloom account that should own it:",
             into: &out)
        emit("      \(link)", into: &out)
        if let code = event.userCode {
            emit("    Code: \(code). Check the Mac shown, then press Approve; the CLI cannot approve for you.", into: &out)
        }
        if event.browserOpened == true {
            emit("    Your browser opened this page. If it didn't, open the link yourself.", into: &out)
        } else {
            emit(event.verificationURIComplete == nil && event.userCode != nil
                 ? "    Open the link in a browser on any device and enter the code."
                 : "    Open the link in a browser on any device.", into: &out)
        }
        emit("    Earnings for jobs on this Mac go to the account that approves it.", into: &out)
        emit("", into: &out)
    }

    private func showWaitlist(into out: inout String) {
        guard !waitlistShown else { return }
        waitlistShown = true
        emit("", into: &out)
        emit("    Your account is on the waitlist: Darkbloom reviews new Mac owners before their first Mac joins.",
             into: &out)
        emit("    Leave this running, or press Ctrl-C and run `\(BuildEnvironment.current.cliName) sandbox setup` "
             + "again later; this Mac enrolls once your account is approved.", into: &out)
        emit("", into: &out)
    }

    private func runningTitle(_ stage: Stage) -> String {
        if stage.waitlisted { return "Waiting for Darkbloom to approve your account" }
        if let progress = stage.progress { return "\(stage.title) \(SandboxStatusView.percent(progress))" }
        return stage.title
    }

    private func complete(_ stage: Stage, marker: String, suffix: String = "", into out: inout String) {
        emit("  \(marker) \(stage.title)\(suffix)", into: &out)
        for detail in stage.details {
            for line in detail.split(separator: "\n", omittingEmptySubsequences: true) {
                emit("    \(line)", into: &out)
            }
        }
    }

    private func emit(_ line: String, into out: inout String) {
        erase(into: &out)
        out += line + "\n"
    }

    private func erase(into out: inout String) {
        guard lineDrawn else { return }
        out += "\r\u{1B}[2K"
        lineDrawn = false
    }

    private func clipped(_ text: String, to width: Int) -> String {
        text.count <= max(10, width) ? text : String(text.prefix(max(10, width) - 1)) + "…"
    }
}

/// Terminal facts and output for the sandbox commands.
enum SandboxTerminal {
    /// Standard output is a terminal that can redraw a line.
    static func interactive(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isatty(STDOUT_FILENO) != 0 && environment["TERM"] != "dumb"
    }

    static func width() -> Int {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
        return Int(size.ws_col)
    }

    /// Through stdio, so it stays in order with `print`.
    static func write(_ text: String) {
        print(text, terminator: "")
        fflush(stdout)
    }

    /// Asks a yes/no question; anything but y or yes is no.
    static func confirm(_ question: String, readInput: () -> String? = { readLine() },
                        emit: (String) -> Void = { write($0) }) -> Bool {
        emit("\(question) [y/N]: ")
        let answer = readInput()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return ["y", "yes"].contains(answer)
    }
}
