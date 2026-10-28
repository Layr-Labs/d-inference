import Foundation
import ProviderCore

/// How `darkbloom sandbox status` and the `Sandboxes:` line of `darkbloom
/// status` present the add-on's status. Pure string production.
enum SandboxStatusView {
    static var cli: String { BuildEnvironment.current.cliName }

    /// The state in a few words, and how it should read (green, yellow, red).
    static func headline(_ status: SandboxAddonStatus) -> (text: String, level: DiagnosticLevel) {
        switch status.state {
        case .notInstalled: return ("not set up", .info)
        case .waitingForApproval: return ("waiting for approval", .warn)
        case .waitlisted: return ("on the waitlist", .warn)
        case .enrolling: return ("enrolling", .warn)
        case .downloadingImages:
            return ("downloading images" + (status.imageProgress.map { " (\(percent($0)))" } ?? ""), .warn)
        case .ready: return (status.jobsRunning > 0 ? "running \(jobs(status.jobsRunning))" : "ready", .pass)
        case .running: return ("running \(jobs(status.jobsRunning))", .pass)
        case .paused: return ("paused", .warn)
        case .updating: return ("updating", .warn)
        case .stopped: return ("stopped", .fail)
        case .error: return ("error", .fail)
        case .unknown(let state): return (state.replacingOccurrences(of: "_", with: " "), .info)
        }
    }

    /// What the state means for the owner, and what to do about it.
    static func meaning(_ status: SandboxAddonStatus) -> String {
        switch status.state {
        case .notInstalled:
            return "Set it up with `\(cli) sandbox setup`."
        case .waitingForApproval:
            return "Approve this Mac in your browser, signed in to your Darkbloom account. "
                + "Run `\(cli) sandbox setup` to see the link and code again."
        case .waitlisted:
            return "Darkbloom has not approved your account to host sandboxes yet. "
                + "This Mac enrolls as soon as it does."
        case .enrolling:
            return "Finishing enrollment."
        case .downloadingImages:
            return "Jobs start once an image is installed."
        case .ready where status.jobsRunning == 0:
            return status.accepting == false
                ? "Not taking jobs right now." : "Waiting for jobs. Inference runs as usual until a job starts."
        case .ready, .running:
            return "Inference is paused while jobs run, and resumes after the last one ends."
        case .paused where status.jobsRunning > 0:
            return "\(jobs(status.jobsRunning)) still running; "
                + (status.jobsRunning == 1 ? "it finishes" : "they finish") + " normally. "
                + "No new jobs until you run `\(cli) sandbox resume`."
        case .paused:
            return "No new jobs until you run `\(cli) sandbox resume`. Inference runs as usual."
        case .updating:
            return "Installing a new version of the add-on between jobs."
        case .stopped:
            return "The agent is not running, so this Mac gets no jobs. Run `\(cli) sandbox setup` to start it."
        case .error:
            return "See `\(cli) sandbox logs` for details."
        case .unknown:
            return "Your add-on is newer than this CLI. Run `\(cli) update` for a matching CLI."
        }
    }

    /// The `darkbloom sandbox status` screen.
    static func lines(_ status: SandboxAddonStatus, now: Date = Date(), color: Bool = false) -> [String] {
        let headline = headline(status)
        let title = "Darkbloom Sandbox" + (status.version.map { " \($0)" } ?? "") + ": "
        var lines = [title + DoctorTerminalStyle.verdict(headline.text, level: headline.level, color: color)]
        lines.append("  " + meaning(status))
        if let detail = status.detail { lines.append("  Detail: \(detail)") }
        guard status.state != .notInstalled else { return lines }
        if let slots = slotsText(status) { lines.append("  Free slots: \(slots)") }
        if !status.images.isEmpty { lines.append("  Images: \(imagesText(status.images))") }
        if let host = status.hostID { lines.append("  Host: \(host)") }
        let checked = status.lastUpdateCheck.map {
            "last checked \(darkbloom.Status.compactDuration(max(0, now.timeIntervalSince($0)))) ago"
        } ?? "not checked yet"
        lines.append("  Updates: automatic, \(checked)")
        if let console = status.consoleURL { lines.append("  Console: \(console) (jobs and earnings)") }
        lines.append(status.state == .paused
            ? "  Resume: \(cli) sandbox resume" : "  Pause: \(cli) sandbox pause (running jobs finish; no new ones)")
        lines.append("  Logs: \(cli) sandbox logs")
        return lines
    }

    static func notInstalledLines() -> [String] {
        [
            "Darkbloom Sandbox: not set up on this Mac.",
            "  It runs approved GitHub Actions jobs in Linux and macOS VMs here and pays each job's",
            "  price minus a 10% fee into your Darkbloom balance; inference pauses while a job runs.",
            "  Set it up with `\(cli) sandbox setup`. Docs: \(Sandbox.docsURL)",
        ]
    }

    /// One line for `darkbloom status`; nil when the add-on is not installed.
    static func statusLine(_ query: SandboxAddonQuery) -> String? {
        let details = "Run `\(cli) sandbox status` for details."
        switch query {
        case .notInstalled:
            return nil
        case .status(let status, _):
            guard status.installed, status.state != .notInstalled else { return nil }
            var summary = headline(status).text
            switch status.state {
            case .ready where status.jobsRunning == 0:
                summary += ", no jobs running"
            case .paused:
                summary += status.jobsRunning > 0 ? " (\(jobs(status.jobsRunning)) finishing, no new jobs)" : " (no new jobs)"
            default:
                break
            }
            if [.ready, .running, .paused].contains(status.state), let slots = slotsText(status, compact: true) {
                summary += "; free slots \(slots)"
            }
            let attention: [SandboxAddonStatus.State] = [.waitingForApproval, .waitlisted, .stopped, .error]
            if attention.contains(status.state) || headline(status).level == .info {
                summary += ". \(details)"
            }
            return "Sandboxes: \(summary)"
        case .outdated:
            return "Sandboxes: installed; this add-on version reports no summary. \(details)"
        case .unresponsive(let seconds):
            return "Sandboxes: installed; the add-on did not answer within \(seconds)s. \(details)"
        case .failed(let reason):
            return "Sandboxes: installed; status unavailable (\(reason)). \(details)"
        }
    }

    /// `Linux 1 of 1, macOS 0 of 1` (compact: `Linux 1/1, macOS 0/1`);
    /// a platform without slots is left out.
    static func slotsText(_ status: SandboxAddonStatus, compact: Bool = false) -> String? {
        let parts = [("Linux", status.linux), ("macOS", status.macOS)].compactMap { name, slots -> String? in
            guard let slots, slots.total > 0 else { return nil }
            return compact ? "\(name) \(slots.free)/\(slots.total)" : "\(name) \(slots.free) of \(slots.total)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func imagesText(_ images: [SandboxAddonStatus.Image]) -> String {
        images.map { image in
            let state: String
            switch image.state {
            case "downloading": state = "downloading" + (image.progress.map { " \(percent($0))" } ?? "")
            default: state = image.state
            }
            return "\(platformName(image.platform)) \(state)"
        }.joined(separator: ", ")
    }

    /// `linux_arm64` reads as Linux, `macos_arm64` as macOS.
    static func platformName(_ platform: String) -> String {
        let lowered = platform.lowercased()
        if lowered.hasPrefix("linux") { return "Linux" }
        if lowered.hasPrefix("macos") { return "macOS" }
        return platform
    }

    static func jobs(_ count: Int) -> String { count == 1 ? "1 job" : "\(count) jobs" }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded(.down)))%" }
}
