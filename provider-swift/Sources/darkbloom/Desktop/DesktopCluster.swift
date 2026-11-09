import Foundation
import ProviderCore

/// `GET /control/v1/cluster`: this Mac's two-Mac cluster as `darkbloom cluster status --json` says it (schema 1), run as
/// this build's own child so its timeouts stay the CLI's: on the Mac that follows it waits up to 10 seconds for the
/// leading Mac (`ClusterPairSummary.boundedStatus`). Read only on demand; concurrent and repeated reads within 10 s
/// share one run, and a finished start, stop, restart, switch, update or `cluster_leave` makes the next read run again.
extension DesktopBackend {
  static let clusterReadKey = "cluster"
  /// The child's own bound, past the CLI's 10-second wait for the leading Mac.
  static let clusterStatusTimeout: TimeInterval = 30
  /// The exit statuses `cluster status --json` prints its document with: 0 serving, 3 not serving yet, 4 stopped, 5 the
  /// other Mac isn't answering, 6 not paired, 7 an unreadable pairing record.
  static let clusterStatusExitCodes: Set<Int32> = [0, 3, 4, 5, 6, 7]

  func clusterStatus() async -> JSONValue {
    await sharedRead(Self.clusterReadKey, ttl: 10) { [executable, configPath] in
      await Self.readClusterStatus(executable: executable, configPath: configPath)
    }
  }

  static func readClusterStatus(executable: URL?, configPath: String?) async -> JSONValue {
    let arguments = ["cluster", "status", "--json"] + (configPath.map { ["--config", $0] } ?? [])
    do {
      let run = try await DesktopWorker(executable: executable).runReportingErrors(
        arguments, timeout: clusterStatusTimeout)
      return clusterStatus(exitCode: run.status, output: run.output, errors: run.errors)
    } catch DesktopWorker.RunError.timedOut {
      return clusterStatusUnavailable(
        "`\(BuildEnvironment.current.cliName) cluster status` didn't answer within \(Int(clusterStatusTimeout)) s.")
    } catch {
      return clusterStatusUnavailable(
        "`\(BuildEnvironment.current.cliName) cluster status` couldn't run: \(DesktopText.line(String(describing: error)))")
    }
  }

  /// The document `cluster status --json` printed, as it is, for an exit status that prints one. Anything else is the
  /// same shape with nothing known (`clusterStatusUnavailable`), and why: the command's last line on stderr, if any.
  static func clusterStatus(exitCode: Int32, output: String, errors: String) -> JSONValue {
    if clusterStatusExitCodes.contains(exitCode), let document = jsonObject(output),
      document.field("schema").number.map({ $0 >= 1 }) == true, document.field("state").text != nil
    {
      return document
    }
    let reason = DesktopText.lastLines(errors, count: 1).first
      ?? "`\(BuildEnvironment.current.cliName) cluster status --json` printed no status (exit \(exitCode))."
    return clusterStatusUnavailable(reason)
  }

  /// `ClusterStatus` with every key, nothing known, `state` `unknown` and `exit_code` -1, and `error` saying why.
  static func clusterStatusUnavailable(_ reason: String) -> JSONValue {
    .dict([
      "schema": .int(1), "paired": .null, "role": .null, "this_mac": .null, "other_mac": .null, "model": .null,
      "mode": .null, "split": .null, "serves": .null, "state": .string("unknown"), "reason": .null, "next": .null,
      "lines": .array([]), "service": .null, "exit_code": .int(-1), "error": .string(reason),
    ])
  }

  /// `text` as one JSON object; nil for anything else.
  static func jsonObject(_ text: String) -> JSONValue? {
    guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object = value
    else { return nil }
    return value
  }
}
