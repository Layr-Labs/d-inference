import Darwin
import Foundation
import ProviderCore

/// One stdout line of `install.sh --json-progress`: a JSON object with a
/// `stage` (schema 1), or any other text, which is shown as it is.
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

struct SandboxInstallerEvent: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case checking, verifying, installing, waitingForApproval, waitlisted, enrolled, starting
        case downloadingImages, ready, error
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "checking": self = .checking
            case "verifying": self = .verifying
            case "installing": self = .installing
            case "waiting_for_approval": self = .waitingForApproval
            case "waitlisted": self = .waitlisted
            case "enrolled": self = .enrolled
            case "starting": self = .starting
            case "downloading_images": self = .downloadingImages
            case "ready": self = .ready
            case "error": self = .error
            default: self = .other(raw)
            }
        }

        /// Complete when it arrives, rather than an activity that runs.
        var isMilestone: Bool { self == .enrolled || self == .ready }
    }

    var stage: Stage
    var detail: String?
    var version: String?
    /// The approval page, with the code filled in.
    var url: String?
    var code: String?
    var expiresIn: Int?
    var hostID: String?
    /// 0...1, for `downloading_images`.
    var progress: Double?

    init(stage: Stage, detail: String? = nil, version: String? = nil, url: String? = nil, code: String? = nil,
         expiresIn: Int? = nil, hostID: String? = nil, progress: Double? = nil) {
        self.stage = stage
        self.detail = detail
        self.version = version
        self.url = url
        self.code = code
        self.expiresIn = expiresIn
        self.hostID = hostID
        self.progress = progress
    }

    /// Unknown fields are ignored; RFC 8628 names are accepted for the
    /// approval link and code.
    init?(json: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let stage = object["stage"] as? String, !stage.isEmpty else { return nil }
        func text(_ keys: String...) -> String? {
            keys.lazy.compactMap { (object[$0] as? String).flatMap { $0.isEmpty ? nil : $0 } }.first
        }
        self.init(
            stage: Stage(stage), detail: text("detail"), version: text("version"),
            url: text("url", "verification_uri_complete", "verification_uri"), code: text("code", "user_code"),
            expiresIn: object["expires_in"] as? Int, hostID: text("host_id"),
            progress: (object["progress"] as? Double).map { min(max($0, 0), 1) })
    }

    /// The same stage again: fields it carries replace the earlier ones.
    func updated(by event: SandboxInstallerEvent) -> SandboxInstallerEvent {
        SandboxInstallerEvent(
            stage: stage, detail: event.detail ?? detail, version: event.version ?? version,
            url: event.url ?? url, code: event.code ?? code, expiresIn: event.expiresIn ?? expiresIn,
            hostID: event.hostID ?? hostID, progress: event.progress ?? progress)
    }

    var title: String {
        switch stage {
        case .checking: return "Checking this Mac"
        case .verifying: return "Verifying release" + (version.map { " \($0)" } ?? "")
        case .installing: return "Installing"
        case .waitingForApproval: return "Waiting for approval"
        case .waitlisted: return "On the waitlist, waiting for Darkbloom to approve your account"
        case .enrolled: return "Enrolled" + (hostID.map { " (host \($0))" } ?? "")
        case .starting: return "Starting"
        case .downloadingImages:
            return "Downloading images" + (progress.map { " \(SandboxStatusView.percent($0))" } ?? "")
        case .ready: return "Ready"
        case .error: return "Setup failed"
        case .other(let name): return detail ?? name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Renders installer events as the CLI's stage list:
///
///     ✓ Checking this Mac
///     ✓ Verifying release 1.2.0
///     ⠋ Waiting for approval
///
/// On a terminal the running stage is the last line, with a spinner, and
/// turns into ✓ (or ✗) when the next stage starts. Elsewhere each stage prints
/// once, when it ends. A stage's details print under its line when it ends;
/// what needs the owner now (the approval link and code, the waitlist) prints
/// at once, above the running stage.
final class SandboxSetupRenderer: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed([String])
        case interrupted
    }

    static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private let lock = NSLock()
    private let interactive: Bool
    private let color: Bool
    private let browserOpens: Bool
    private let approvalPage: String
    private let width: @Sendable () -> Int
    private let write: @Sendable (String) -> Void
    private var active: SandboxInstallerEvent?
    private var activeDetails: [String] = []
    private var lineDrawn = false
    private var frame = 0
    private var shownApprovals: Set<String> = []
    private var waitlistShown = false
    private var reportedTenths = -1
    private var errorDetail: String?

    init(interactive: Bool, color: Bool, browserOpens: Bool, approvalPage: String,
         width: @escaping @Sendable () -> Int = SandboxTerminal.width,
         write: @escaping @Sendable (String) -> Void = SandboxTerminal.write) {
        self.interactive = interactive
        self.color = color
        self.browserOpens = browserOpens
        self.approvalPage = approvalPage
        self.width = width
        self.write = write
    }

    /// The installer's last `error` detail, if it sent one.
    var failureDetail: String? { lock.withLock { errorDetail } }

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
                if let current = active, current.stage == .downloadingImages, (current.progress ?? 0) < 1 {
                    complete(marker: DoctorTerminalStyle.heading("•", color: color),
                             title: current.title + ", continuing in the background", into: &out)
                } else if let current = active {
                    complete(marker: done, title: current.title, into: &out)
                }
            case .failed(let lines):
                complete(marker: failed, title: active?.title ?? "Setup failed", into: &out)
                lines.forEach { emit("    \($0)", into: &out) }
            case .interrupted:
                complete(marker: failed, title: (active?.title ?? "Setup") + " (stopped)", into: &out)
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
            if interactive, let current = active {
                let symbol = DoctorTerminalStyle.heading(Self.spinner[frame % Self.spinner.count], color: color)
                out += "  \(symbol) " + clipped(current.title, to: width() - 5)
                lineDrawn = true
            }
            if !out.isEmpty { write(out) }
        }
    }

    private func apply(_ event: SandboxInstallerEvent, into out: inout String) {
        if event.stage == .error {
            errorDetail = event.detail ?? errorDetail
            return
        }
        if let current = active, current.stage == event.stage {
            let updated = current.updated(by: event)
            active = updated
            if let detail = event.detail, detail != current.detail, !isTitle(event) { activeDetails.append(detail) }
            showAttention(for: updated, into: &out)
            return
        }
        if let current = active { complete(marker: done, title: current.title, into: &out) }
        active = nil
        if event.stage.isMilestone {
            emit("  \(done) \(event.title)", into: &out)
            if let detail = event.detail { emit("    \(detail)", into: &out) }
            return
        }
        active = event
        activeDetails = event.detail.flatMap { isTitle(event) ? nil : [$0] } ?? []
        // The stage's own line carries its first figure; later tenths print.
        reportedTenths = tenths(event.progress)
        showAttention(for: event, into: &out)
    }

    private func tenths(_ progress: Double?) -> Int { Int(((progress ?? 0) * 10).rounded(.down)) }

    /// `other` stages show their detail as their title.
    private func isTitle(_ event: SandboxInstallerEvent) -> Bool {
        if case .other = event.stage { return true }
        return false
    }

    private func showAttention(for event: SandboxInstallerEvent, into out: inout String) {
        switch event.stage {
        case .waitingForApproval:
            let link = event.url ?? approvalPage
            guard shownApprovals.insert(link + "|" + (event.code ?? "")).inserted else { return }
            emit("", into: &out)
            emit("    Approve this Mac in your browser, signed in to your Darkbloom account:", into: &out)
            emit("      \(link)", into: &out)
            if let code = event.code {
                let expiry = event.expiresIn.map { " (expires in \(max(1, $0 / 60)) min)" } ?? ""
                emit("    Code: \(code)\(expiry). Earnings go to the account that approves.", into: &out)
            }
            emit(browserOpens
                 ? "    Your browser should open it; if not, open the link yourself. The CLI cannot approve for you."
                 : "    Open the link yourself. The CLI cannot approve for you.", into: &out)
            emit("", into: &out)
        case .waitlisted:
            guard !waitlistShown else { return }
            waitlistShown = true
            emit("", into: &out)
            emit("    Your request is on the waitlist. This Mac enrolls as soon as Darkbloom approves your account.",
                 into: &out)
            emit("    You can press Ctrl-C now and run `\(BuildEnvironment.current.cliName) sandbox setup` again later.",
                 into: &out)
            emit("", into: &out)
        case .downloadingImages where !interactive:
            // The stage's own line shows the end figure.
            let reached = tenths(event.progress)
            guard event.progress != nil, reached > reportedTenths, reached < 10 else { return }
            reportedTenths = reached
            emit("    \(event.title)", into: &out)
        default:
            break
        }
    }

    private func complete(marker: String, title: String, into out: inout String) {
        emit("  \(marker) \(title)", into: &out)
        activeDetails.forEach { emit("    \($0)", into: &out) }
        activeDetails = []
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
