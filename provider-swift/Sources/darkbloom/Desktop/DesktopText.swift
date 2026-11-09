import Foundation

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
