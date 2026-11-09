import Foundation

/// `darkbloom sandbox setup --json-events` (hidden; the desktop app runs it): what setup says, one JSON object per line
/// on standard output, so the app follows it without reading terminal text.
///
/// - `{"type":"line","text":"…"}` for each line setup prints, in order; `"stream":"error"` for one it prints on
///   standard error at a terminal (a refusal, a failed download).
/// - `{"type":"installer","event":{…}}` for each event of the installer's `--json-progress` output, as the installer
///   wrote it (`SandboxInstallerEvent` reads it), before the lines setup renders from it.
///
/// Nothing else reaches standard output in this mode. The installer's other text shows as lines.
enum SandboxSetupEvents {
  static func line(_ text: String, error: Bool = false) -> String {
    var object: [String: Any] = ["type": "line", "text": text]
    if error { object["stream"] = "error" }
    return encode(object)
  }

  /// The installer's event line as one `installer` object; nil when it is not a JSON object.
  static func installer(_ eventLine: String) -> String? {
    guard let event = (try? JSONSerialization.jsonObject(with: Data(eventLine.utf8))) as? [String: Any] else {
      return nil
    }
    return encode(["type": "installer", "event": event])
  }

  static func say(_ text: String, error: Bool = false) {
    write(line(text, error: error))
  }

  /// The installer's `--json-progress` line, passed on.
  static func passOn(installerLine: String) {
    if let object = installer(installerLine) { write(object) }
  }

  /// What the stage renderer draws (`SandboxSetupRenderer`, never interactive here), a line at a time.
  @Sendable static func rendered(_ text: String) {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    lines.forEach { say($0) }
  }

  /// One object per line. Each `print` holds stdout's lock for the whole line, so lines from the installer's reader
  /// thread and from setup never interleave; stdout is line-buffered (`Sandbox.Setup.run`).
  private static func write(_ json: String) {
    print(json)
  }

  private static func encode(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return #"{"type":"line","text":""}"# }
    return String(decoding: data, as: UTF8.self)
  }
}
