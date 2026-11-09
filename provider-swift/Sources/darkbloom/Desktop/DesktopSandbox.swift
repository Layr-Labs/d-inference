import Foundation
import ProviderCore

/// Darkbloom Sandbox for the app: the add-on's status and log, read on demand through this build's own `darkbloom
/// sandbox` commands.
extension DesktopBackend {
  static let sandboxReadKey = "sandbox"
  static let sandboxLogsReadKey = "sandbox-logs"
  /// `sandbox status` waits up to 10 s for the add-on (`Sandbox.statusTimeout`); its child gets more.
  static let sandboxStatusTimeout: TimeInterval = 30
  static let sandboxLogLines = 200

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
    do {
      let run = try await DesktopWorker(executable: executable).runReportingErrors(
        ["sandbox", "status", "--json"], timeout: sandboxStatusTimeout)
      return sandboxStatus(output: run.output, errors: run.errors, exitCode: run.status)
    } catch DesktopWorker.RunError.timedOut {
      return sandboxStatusUnavailable(
        "`\(BuildEnvironment.current.cliName) sandbox status` didn't answer within \(Int(sandboxStatusTimeout)) s.")
    } catch {
      return sandboxStatusUnavailable(
        "`\(BuildEnvironment.current.cliName) sandbox status` couldn't run: \(DesktopText.line(String(describing: error)))")
    }
  }

  /// The add-on's document, decoded as leniently as the CLI decodes it (`SandboxAddonStatus`: an integer `schema` of 1
  /// or more and a string `state`), with `last_update_check` normalized as the CLI reads it
  /// (`SandboxAddonStatus.timestamp`: seconds, milliseconds or ISO 8601). Otherwise the CLI's own reason from stderr.
  static func sandboxStatus(output: String, errors: String, exitCode: Int32) -> JSONValue {
    guard SandboxAddonStatus(json: output) != nil, case .object(let pairs)? = jsonObject(output) else {
      let reason = DesktopText.lastLines(errors, count: 1).first
        ?? "`\(BuildEnvironment.current.cliName) sandbox status --json` printed no status (exit \(exitCode))."
      return sandboxStatusUnavailable(reason)
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
    do {
      let (code, output) = try await DesktopWorker(executable: executable).run(
        ["sandbox", "logs", "-n", String(sandboxLogLines)], timeout: 15)
      guard code == 0 else {
        return .dict([
          "lines": .array([]), "observed_at": observed,
          "error": .string("`\(BuildEnvironment.current.cliName) sandbox logs` exited \(code)."),
        ])
      }
      let whole = output.utf8.count < DesktopWorker.outputLimit
        ? output : String(output.drop(while: { $0 != "\n" }).dropFirst())
      let lines = DesktopText.lastLines(whole, count: sandboxLogLines)
      return .dict(["lines": .array(lines.map(DV.string)), "observed_at": observed])
    } catch {
      let reason =
        (error as? DesktopWorker.RunError).map {
          if case .timedOut = $0 { return "The agent log didn't answer within 15 s." }
          return $0.description
        } ?? "`\(BuildEnvironment.current.cliName) sandbox logs` couldn't run."
      return .dict(["lines": .array([]), "observed_at": observed, "error": .string(reason)])
    }
  }
}
