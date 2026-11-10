import Foundation
import ProviderCore

/// Darkbloom Sandbox for the app: the add-on's status and log, read on demand through this build's own `darkbloom
/// sandbox` commands, and the progress of `sandbox setup --json-events` while it runs (`DesktopSandboxSetupTracker`).
extension DesktopBackend {
  static let sandboxReadKey = "sandbox"
  static let sandboxLogsReadKey = "sandbox-logs"
  /// `sandbox status` waits up to 10 s for the add-on (`Sandbox.statusTimeout`); its child gets more.
  static let sandboxStatusTimeout: TimeInterval = 30
  static let sandboxLogLines = 200
  static let sandboxLogsTimeout: TimeInterval = 15
  /// How long `sandbox setup --json-events` has, once cancelled, to pass SIGINT to its installer and say how it ended
  /// before it is killed (`DesktopWorker.terminationGrace`).
  static let sandboxSetupGrace: TimeInterval = 30
  /// A setup can wait for the browser approval and, with `wait_ready`, for the VM images.
  static let sandboxSetupTimeout: TimeInterval = 6 * 3600
  /// Lines an operation keeps (`DesktopOperation.lines`).
  static let operationLineLimit = 40

  /// `GET /control/v1/sandbox`: `sandbox status --json` as it printed it, whatever its exit status (an add-on that is
  /// not installed exits 1 with a `not_installed` document), with `last_update_check` in Unix seconds.
  func sandboxStatus() async -> JSONValue {
    await sharedRead(Self.sandboxReadKey, ttl: 10) { [executable] in
      await Self.readSandboxStatus(executable: executable)
    }
  }

  /// `GET /control/v1/sandbox-logs`: the agent log's last lines (`sandbox logs -n 200`), sanitized.
  func sandboxLogs() async -> JSONValue {
    await sharedRead(Self.sandboxLogsReadKey, ttl: 5) { [executable] in
      await Self.readSandboxLogs(executable: executable)
    }
  }

  static func readSandboxStatus(executable: URL?) async -> JSONValue {
    await readStatus(
      "sandbox status", arguments: ["sandbox", "status", "--json"], executable: executable,
      timeout: sandboxStatusTimeout, parse: { sandboxStatus(output: $0.output, errors: $0.errors, exitCode: $0.status) },
      unavailable: sandboxStatusUnavailable)
  }

  /// The add-on's document, decoded as leniently as the CLI decodes it (`SandboxAddonStatus`: an integer `schema` of 1
  /// or more and a string `state`), with `last_update_check` normalized as the CLI reads it
  /// (`SandboxAddonStatus.timestamp`: seconds, milliseconds or ISO 8601). Otherwise the CLI's own reason from stderr
  /// (`noStatusReason`).
  static func sandboxStatus(output: String, errors: String, exitCode: Int32) -> JSONValue {
    guard SandboxAddonStatus(json: output) != nil, case .object(let pairs)? = jsonObject(output) else {
      return sandboxStatusUnavailable(noStatusReason("sandbox status", errors: errors, exitCode: exitCode))
    }
    let raw = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any]
    let checked = SandboxAddonStatus.timestamp(raw?["last_update_check"]).map { JSONValue.number($0.timeIntervalSince1970) }
    var normalized = pairs.filter { $0.0 != "last_update_check" }
    normalized.append(("last_update_check", checked ?? .null))
    return .object(normalized)
  }

  static func sandboxStatusUnavailable(_ reason: String) -> JSONValue {
    .dict(["schema": .int(1), "state": .string("unknown"), "error": .string(reason)])
  }

  /// The output keeps its last 32 KiB (`DesktopWorker`), so long log lines can leave fewer than 200; a line the bound
  /// cut in two is left out.
  static func readSandboxLogs(executable: URL?) async -> JSONValue {
    let observed = JSONValue.number(Date().timeIntervalSince1970)
    func unavailable(_ reason: String) -> JSONValue {
      .dict(["lines": .array([]), "observed_at": observed, "error": .string(reason)])
    }
    let command = "`\(BuildEnvironment.current.cliName) sandbox logs`"
    do {
      let (code, output) = try await DesktopWorker(executable: executable).run(
        ["sandbox", "logs", "-n", String(sandboxLogLines)], timeout: sandboxLogsTimeout)
      guard code == 0 else { return unavailable("\(command) exited \(code).") }
      let whole = output.utf8.count < DesktopWorker.outputLimit
        ? output : String(output.drop(while: { $0 != "\n" }).dropFirst())
      let lines = DesktopText.lastLines(whole, count: sandboxLogLines)
      return .dict(["lines": .array(lines.map(DV.string)), "observed_at": observed])
    } catch DesktopWorker.RunError.timedOut {
      return unavailable("The agent log didn't answer within \(Int(sandboxLogsTimeout)) s.")
    } catch let error as DesktopWorker.RunError {
      return unavailable(error.description)
    } catch {
      return unavailable("\(command) couldn't run.")
    }
  }

  /// `sandbox setup --yes --no-browser --json-events` with the app's choices; `--disk` once per work disk, in order.
  static func sandboxSetupArguments(_ request: DesktopAction) -> [String] {
    var arguments = ["sandbox", "setup", "--yes", "--no-browser", "--json-events"]
    if let linux = request.linux_slots { arguments += ["--linux-slots", String(linux)] }
    if let macOS = request.macos_slots { arguments += ["--macos-slots", String(macOS)] }
    for disk in request.disks ?? [] { arguments += ["--disk", disk] }
    if request.wait_ready == true { arguments.append("--wait-ready") }
    return arguments
  }

  /// Runs `sandbox setup --json-events`, publishing its lines and the installer's progress on the operation as they
  /// arrive. Returns the exit status and the operation's final message: the lines setup said. A runtime without
  /// `--json-events` (exit 64 before any event) is named instead of its usage text.
  func runSandboxSetup(_ request: DesktopAction, arguments: [String], worker: DesktopWorker) async throws
    -> (Int32, String)
  {
    let tracker = DesktopSandboxSetupTracker()
    defer { applySandboxSetup(request.id, tracker) }
    let code: Int32
    do {
      (code, _) = try await worker.run(
        arguments, timeout: Self.sandboxSetupTimeout,
        lines: { [weak self] line in
          tracker.consume(line)
          Task { await self?.applySandboxSetup(request.id, tracker) }
        })
    } catch {
      // A cancel or the timeout stopped it: the CLI's own exit status, or 130 (stopped) when a signal ended it first.
      if let ended = worker.lastTermination { tracker.end(exitStatus: ended.signaled ? 130 : ended.status) }
      throw error
    }
    if code != 0 { tracker.end(exitStatus: code) }
    let snapshot = tracker.snapshot
    if code == 64, !snapshot.sawEvents {
      return (code, "This Darkbloom runtime can't set up Darkbloom Sandbox from the app yet. Update it, or run `"
        + "\(BuildEnvironment.current.cliName) sandbox setup` in Terminal.")
    }
    return (code, snapshot.lines.joined(separator: "\n"))
  }

  /// The tracker's latest lines and progress on the running operation. Each call reads the newest state, so calls that
  /// arrive out of order still leave the latest.
  func applySandboxSetup(_ id: String, _ tracker: DesktopSandboxSetupTracker) {
    guard let index = operations.firstIndex(where: { $0.id == id }), operations[index].state == "running" else {
      return
    }
    let snapshot = tracker.snapshot
    operations[index].lines = snapshot.lines
    operations[index].sandbox_setup = snapshot.progress
    // A cancelled setup says "Cancelling…" until it ends (`submit` took its `cancellable` away).
    if let last = snapshot.lines.last, operations[index].cancellable { operations[index].message = last }
  }
}

/// `SandboxSetupProgress` in the app's contract (`desktop-app/src/shared/sandbox.ts`).
struct DesktopSandboxSetupProgress: Codable, Equatable, Sendable {
  struct Approval: Codable, Equatable, Sendable {
    var user_code: String
    var verification_uri: String
    var verification_uri_complete: String?
  }

  var stage: String?
  var step: Int?
  var steps: Int?
  var message: String?
  var approval: Approval?
  var waitlisted: Bool?
  var background: Bool?
  var progress: Double?
  /// The CLI's exit status once the setup ended without success: the installer's 2, 3 or 4, 130 when it was stopped,
  /// else the CLI's own. Absent while it runs and after a success.
  var exit_status: Int32?
}

/// Follows one `sandbox setup --json-events` run, line by line, on the worker's reader thread: the lines setup says
/// (the last 40, sanitized; `{"type":"line"}`) and the installer's progress from its events (`{"type":"installer"}`,
/// read as the CLI reads them: `SandboxInstallerEvent`). Any other line, such as an older runtime's usage text, is
/// kept as a line.
final class DesktopSandboxSetupTracker: @unchecked Sendable {
  struct Snapshot: Equatable, Sendable {
    var lines: [String] = []
    var progress = DesktopSandboxSetupProgress()
    /// The run wrote at least one `--json-events` object.
    var sawEvents = false
  }

  private let lock = NSLock()
  private var state = Snapshot()

  var snapshot: Snapshot { lock.withLock { state } }

  /// How the setup ended without success (`DesktopSandboxSetupProgress.exit_status`).
  func end(exitStatus: Int32) { lock.withLock { state.progress.exit_status = exitStatus } }

  func consume(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    let object = trimmed.hasPrefix("{")
      ? (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] : nil
    lock.withLock {
      guard let object, let type = object["type"] as? String else {
        append(trimmed)
        return
      }
      state.sawEvents = true
      switch type {
      case "line":
        if let text = object["text"] as? String { append(text) }
      case "installer":
        guard let event = object["event"] as? [String: Any],
          let data = try? JSONSerialization.data(withJSONObject: event),
          let parsed = SandboxInstallerEvent(json: String(decoding: data, as: UTF8.self))
        else { return }
        apply(parsed)
      default:
        break
      }
    }
  }

  // MARK: - Under the lock

  private func append(_ raw: String) {
    let line = DesktopText.line(raw)
    guard !line.isEmpty else { return }
    state.lines.append(line)
    if state.lines.count > DesktopBackend.operationLineLimit {
      state.lines.removeFirst(state.lines.count - DesktopBackend.operationLineLimit)
    }
  }

  /// What the CLI's renderer shows from the same event (`SandboxSetupRenderer`): the stage and its words, the approval
  /// link and code, the waitlist, whether the wait goes on in the background, and the image download. Once the
  /// `enrolled` stage is done, nothing waits for approval any more.
  private func apply(_ event: SandboxInstallerEvent) {
    guard event.kind == .stage else { return }
    var progress = state.progress
    if let stage = event.stage { progress.stage = DesktopText.line(stage, limit: 64) }
    if let step = event.step { progress.step = step }
    if let steps = event.steps { progress.steps = steps }
    if let message = event.message { progress.message = DesktopText.line(message) }
    let approval = event.userCode != nil || event.verificationURI != nil
    if approval, let link = event.verificationURI ?? event.verificationURIComplete {
      progress.approval = .init(
        user_code: DesktopText.line(event.userCode ?? "", limit: 64),
        verification_uri: DesktopText.line(link, limit: 2048),
        verification_uri_complete: event.verificationURIComplete.map { DesktopText.line($0, limit: 2048) })
    }
    if event.waitlisted { progress.waitlisted = true }
    if approval || event.waitlisted { progress.background = event.background || progress.background == true }
    if let fraction = event.progress { progress.progress = fraction }
    if event.status == .done, event.stage == "enrolled" {
      progress.approval = nil
      progress.waitlisted = false
      progress.background = false
    }
    state.progress = progress
  }
}
