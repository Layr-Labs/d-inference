import Foundation

/// Retry only firmware restoration failures through the verified CLI; its
/// ownership checks and automatic-control recovery remain authoritative.
enum DesktopCoolingAuthorization {
  enum Decision: Equatable { case retry, cancelled, failed }
  static func decision(_ output: String) -> Decision {
    if output.contains("(-128)") { return .cancelled }
    if output.contains("fan ownership recovery failed"),
      output.contains("SMC firmware rejected") || output.contains("Ftst remained") {
      return .retry
    }
    return .failed
  }
  static func perform(
    script: String,
    run: @Sendable (String) async throws -> (Int32, String) = { script in
      try await DesktopWorker(executable: URL(fileURLWithPath: "/usr/bin/osascript"))
        .run(["-e", script], timeout: 120)
    },
    pause: @Sendable () async throws -> Void = {
      try await Task.sleep(for: .milliseconds(700))
    }
  ) async throws -> String {
    for attempt in 0..<3 {
      let (status, output) = try await run(script)
      if status == 0 { return output }
      let result = decision(output)
      if result == .retry && attempt < 2 { try await pause(); continue }
      throw Failure(cancelled: result == .cancelled, output: output)
    }
    preconditionFailure("Bounded cooling retry must return or throw")
  }
  struct Failure: Error, CustomStringConvertible {
    let cancelled: Bool
    let output: String
    var description: String {
      cancelled ? "Cooling authorization cancelled" :
        "Cooling change failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
  }
}
