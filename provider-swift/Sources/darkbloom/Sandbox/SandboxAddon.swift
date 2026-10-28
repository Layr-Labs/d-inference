import Foundation
import ProviderCore

/// The Darkbloom Sandbox add-on as this CLI sees it. DarkbloomSandbox.app is a
/// separate, closed-source app; its installer links the app's command at
/// `~/DarkbloomSandbox/darkbloom-sandbox`. The CLI runs that command and
/// reads the agent's log; it never reads or writes the add-on's other files.
struct SandboxAddon: Sendable {
    /// Tests only, though every build reads it: the add-on's install root.
    static let rootOverrideVariable = "DARKBLOOM_SANDBOX_ROOT"

    let root: URL

    var command: URL { root.appendingPathComponent("darkbloom-sandbox") }
    var agentLog: URL { root.appendingPathComponent("agent/agent.log") }
    /// The command exists and is executable (a dangling link is not).
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: command.path) }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SandboxAddon {
        if let root = environment[rootOverrideVariable], !root.isEmpty {
            return SandboxAddon(root: URL(fileURLWithPath: root, isDirectory: true))
        }
        return SandboxAddon(root: home.appendingPathComponent("DarkbloomSandbox", isDirectory: true))
    }
}

/// The answer to `darkbloom-sandbox status --json`.
enum SandboxAddonQuery: Equatable, Sendable {
    case notInstalled
    /// `json` is the add-on's stdout, unchanged, for `--json`.
    case status(SandboxAddonStatus, json: String)
    /// An add-on older than `status --json`: it rejects the option with its usage.
    case outdated
    case unresponsive(seconds: Int)
    case failed(String)
}

/// What a `pause`, `resume` or other add-on action ended with.
enum SandboxAddonActionResult: Equatable, Sendable {
    case done
    case notInstalled
    /// The add-on does not know the action yet.
    case outdated
    case failed(String)
}

extension SandboxAddon {
    /// Never throws and never waits past `timeout`: `darkbloom status` calls it.
    func queryStatus(timeout: TimeInterval) -> SandboxAddonQuery {
        guard isInstalled else { return .notInstalled }
        let result: SecurityCommandResult
        do {
            result = try SecurityCommandRunner.bounded(timeout: timeout).run(command.path, ["status", "--json"])
        } catch SecurityCommandRunner.CommandError.timedOut {
            return .unresponsive(seconds: Int(timeout.rounded(.up)))
        } catch {
            return .failed("could not run \(command.path): \(error.localizedDescription)")
        }
        if let status = SandboxAddonStatus(json: result.stdout) {
            return .status(status, json: result.stdout)
        }
        return Self.isUsageError(result) ? .outdated : .failed(Self.failureSummary(result))
    }

    /// Runs a short add-on action (`pause`, `resume`) and captures its output.
    func perform(_ arguments: [String], timeout: TimeInterval) -> SandboxAddonActionResult {
        guard isInstalled else { return .notInstalled }
        let result: SecurityCommandResult
        do {
            result = try SecurityCommandRunner.bounded(timeout: timeout).run(command.path, arguments)
        } catch SecurityCommandRunner.CommandError.timedOut {
            return .failed("the add-on did not finish within \(Int(timeout)) seconds")
        } catch {
            return .failed("could not run \(command.path): \(error.localizedDescription)")
        }
        if result.terminationStatus == 0 { return .done }
        return Self.isUsageError(result) ? .outdated : .failed(Self.failureSummary(result))
    }

    /// The add-on answers an option or action it does not know with its usage
    /// on stderr and EX_USAGE (64).
    static func isUsageError(_ result: SecurityCommandResult) -> Bool {
        result.terminationStatus == 64 || result.stderr.contains("usage: darkbloom-sandbox")
    }

    /// The exit status and the last line the add-on printed, without its
    /// `error: ` prefix.
    static func failureSummary(_ result: SecurityCommandResult) -> String {
        let output = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        var last = output?.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }
        if let line = last, line.hasPrefix("error: ") { last = String(line.dropFirst("error: ".count)) }
        return "exit status \(result.terminationStatus)" + (last.map { ": \($0)" } ?? "")
    }
}

/// `darkbloom-sandbox status --json`, schema 1. Every field but `schema` and
/// `state` is optional here, so an older or newer add-on still renders; an
/// unknown state is kept as it is.
struct SandboxAddonStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case notInstalled, waitingForApproval, waitlisted, enrolling, downloadingImages
        case ready, running, paused, updating, stopped, error
        case unknown(String)

        init(_ raw: String) {
            switch raw {
            case "not_installed": self = .notInstalled
            case "waiting_for_approval": self = .waitingForApproval
            case "waitlisted": self = .waitlisted
            case "enrolling": self = .enrolling
            case "downloading_images": self = .downloadingImages
            case "ready": self = .ready
            case "running": self = .running
            case "paused": self = .paused
            case "updating": self = .updating
            case "stopped": self = .stopped
            case "error": self = .error
            default: self = .unknown(raw)
            }
        }
    }

    struct Slots: Equatable, Sendable {
        var total: Int
        var free: Int
    }

    struct Image: Equatable, Sendable {
        var platform: String
        /// `installed`, `downloading` or `missing`.
        var state: String
        /// 0...1 while downloading.
        var progress: Double?
    }

    var schema: Int
    var installed: Bool
    var version: String?
    var hostID: String?
    var state: State
    var detail: String?
    var linux: Slots?
    var macOS: Slots?
    var jobsRunning: Int
    var images: [Image]
    var accepting: Bool?
    var lastUpdateCheck: Date?
    var consoleURL: String?
}

extension SandboxAddonStatus {
    /// Nil unless `json` is one JSON object with an integer `schema` (1 or
    /// later) and a string `state`.
    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let schema = object["schema"] as? Int, schema >= 1,
              let state = object["state"] as? String else { return nil }
        func text(_ key: String) -> String? {
            (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func slots(_ key: String) -> Slots? {
            guard let slots = object["slots"] as? [String: Any], let entry = slots[key] as? [String: Any],
                  let total = entry["total"] as? Int else { return nil }
            return Slots(total: max(0, total), free: min(max(0, entry["free"] as? Int ?? 0), max(0, total)))
        }
        self.init(
            schema: schema,
            installed: object["installed"] as? Bool ?? (state != "not_installed"),
            version: text("version"),
            hostID: text("host_id"),
            state: State(state),
            detail: text("detail"),
            linux: slots("linux"),
            macOS: slots("macos"),
            jobsRunning: max(0, object["jobs_running"] as? Int ?? 0),
            images: (object["images"] as? [[String: Any]] ?? []).compactMap { image in
                guard let platform = image["platform"] as? String, let state = image["state"] as? String else {
                    return nil
                }
                return Image(platform: platform, state: state,
                             progress: (image["progress"] as? Double).map { min(max($0, 0), 1) })
            },
            accepting: object["accepting"] as? Bool,
            lastUpdateCheck: Self.timestamp(object["last_update_check"]),
            consoleURL: text("console_url"))
    }

    /// Unix seconds (or milliseconds) or an ISO 8601 string.
    static func timestamp(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, !(value is Bool) {
            let seconds = number.doubleValue
            guard seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1_000 : seconds)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Every image is installed (and the add-on listed at least one).
    var imagesInstalled: Bool {
        !images.isEmpty && images.allSatisfy { $0.state == "installed" }
    }

    /// The image downloading now (the add-on fetches one at a time).
    var downloadingImage: Image? { images.first { $0.state == "downloading" } }
}
