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
}

/// Command output as the app shows it.
enum DesktopText {
  /// One line: ANSI escape sequences, other control and format characters, and line separators removed (a tab is a
  /// space), only what a carriage return redraws last kept, trailing spaces trimmed, and at most `limit` characters.
  static func line(_ raw: String, limit: Int = 1000) -> String {
    var text = raw
    if text.contains("\r") {
      text = text.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }
    for pattern in [
      #"\x{1B}\[[0-?]*[ -/]*[@-~]"#,  // CSI: colors, cursor moves, erases
      #"\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)?"#,  // OSC: titles, hyperlinks
      #"\x{1B}[@-Z\\-_]"#,  // other two-character escapes
      #"\x{9B}[0-?]*[ -/]*[@-~]"#,  // 8-bit CSI
    ] {
      text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      if scalar == "\t" {
        scalars.append(" ")
        continue
      }
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator: continue
      default: scalars.append(scalar)
      }
    }
    var cleaned = String(scalars)
    while cleaned.last?.isWhitespace == true { cleaned.removeLast() }
    return cleaned.count > limit ? String(cleaned.prefix(limit - 1)) + "…" : cleaned
  }

  /// The last `count` lines of `text` that have something to show, each as `line` makes it.
  static func lastLines(_ text: String, count: Int, limit: Int = 1000) -> [String] {
    Array(
      text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).lazy.map { line(String($0), limit: limit) }
        .filter { !$0.isEmpty }
        .suffix(count))
  }
}
