import Foundation
import ProviderCore

/// One on-demand read of another command's state (`cluster status`, `sandbox status`, the waitlists): concurrent and
/// repeated reads within its time to live share one run, as `cooling` shares `fan status` (`DesktopBackend.sharedRead`).
struct DesktopSharedRead: Sendable {
  let task: Task<JSONValue, Never>
  /// When the read finished; nil while it runs.
  var finishedAt: Date?
}

extension DesktopBackend {
  /// The value of the read `key`: the one in flight, else one that finished less than `ttl` seconds ago, else a new
  /// run of `read`. A read is never cancelled by its callers; `forgetSharedReads` makes the next one run again.
  func sharedRead(_ key: String, ttl: TimeInterval, _ read: @escaping @Sendable () async -> JSONValue) async
    -> JSONValue
  {
    if let entry = sharedReads[key], entry.finishedAt.map({ Date().timeIntervalSince($0) < ttl }) ?? true {
      return await entry.task.value
    }
    // Bounded: an account or coordinator that keeps changing adds a key per change.
    if sharedReads.count >= 32 { sharedReads = sharedReads.filter { $0.value.finishedAt == nil } }
    // Created before any suspension, so concurrent callers share it.
    let task = Task { await read() }
    sharedReads[key] = DesktopSharedRead(task: task, finishedAt: nil)
    let value = await task.value
    if sharedReads[key]?.task == task { sharedReads[key]?.finishedAt = Date() }
    return value
  }

  func forgetSharedReads(where matches: (String) -> Bool) {
    sharedReads = sharedReads.filter { !matches($0.key) }
  }

  /// A finished action makes the reads it changed stale, so the app's refresh after it shows the new state.
  func forgetSharedReads(after action: String) {
    switch action {
    case "start", "stop", "restart", "switch", "cluster_leave", "update", "update_rollback":
      forgetSharedReads { $0 == Self.clusterReadKey }
    case "sandbox_pause", "sandbox_resume", "sandbox_uninstall", "sandbox_setup":
      forgetSharedReads { $0 == Self.sandboxReadKey || $0 == Self.sandboxLogsReadKey }
    case "waitlist_join", "link", "unlink":
      forgetSharedReads { $0.hasPrefix(Self.waitlistsReadKey) }
    case "route_key":
      accountKeyRead = nil
    default:
      break
    }
  }

  /// A status command's document (`cluster status --json`, `sandbox status --json`), read by this build's own child:
  /// `parse` makes the resource from what the child printed (`runReportingErrors`). A child that didn't answer within
  /// `timeout`, or couldn't run, is `unavailable`, with why in the words of `command`.
  static func readStatus(
    _ command: String, arguments: [String], executable: URL?, timeout: TimeInterval,
    parse: ((status: Int32, output: String, errors: String)) -> JSONValue, unavailable: (String) -> JSONValue
  ) async -> JSONValue {
    let name = "`\(BuildEnvironment.current.cliName) \(command)`"
    do {
      return parse(try await DesktopWorker(executable: executable).runReportingErrors(arguments, timeout: timeout))
    } catch DesktopWorker.RunError.timedOut {
      return unavailable("\(name) didn't answer within \(Int(timeout)) s.")
    } catch {
      return unavailable("\(name) couldn't run: \(DesktopText.line(String(describing: error)))")
    }
  }

  /// Why `command --json` printed no document the API keeps: its last line on standard error, else its exit status.
  static func noStatusReason(_ command: String, errors: String, exitCode: Int32) -> String {
    DesktopText.lastLines(errors, count: 1).first
      ?? "`\(BuildEnvironment.current.cliName) \(command) --json` printed no status (exit \(exitCode))."
  }

  /// `text` as one JSON object; nil for anything else.
  static func jsonObject(_ text: String) -> JSONValue? {
    guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object = value
    else { return nil }
    return value
  }
}
