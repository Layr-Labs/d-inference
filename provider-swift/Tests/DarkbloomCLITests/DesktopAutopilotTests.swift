import Foundation
import Testing
@testable import darkbloom

struct DesktopAutopilotTests {
  /// A process fixture records argv; no provider, model, account or launchd action runs.
  private func fixture() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-autopilot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("cli")
    try """
      #!/bin/sh
      printf '%s\\n' "$*" >> "${0}.calls"
      if [ "$3" = "broken" ]; then exit 7; fi
      printf '100%%\\n'
      """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }

  @Test func allDownloadsCompleteBeforeOneEnrollment() async throws {
    let executable = try fixture()
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let request = DesktopAction(id: UUID().uuidString, action: "autopilot", models: ["a"], pinned: [], downloads: ["a", "b", "c"])
    let backend = DesktopBackend(configPath: "/tmp/autopilot-test.toml")
    let argv = try DesktopBackend.arguments(for: request, configPath: "/tmp/autopilot-test.toml", localActive: false)
    let result = try await backend.runAutopilot(request, arguments: argv, worker: DesktopWorker(executable: executable))
    #expect(result.0 == 0)
    let calls = try String(contentsOfFile: executable.path + ".calls", encoding: .utf8).split(separator: "\n")
    #expect(calls == ["models download a --config /tmp/autopilot-test.toml", "models download b --config /tmp/autopilot-test.toml", "models download c --config /tmp/autopilot-test.toml", "start --autopilot --model a --config /tmp/autopilot-test.toml"])
  }

  @Test func downloadFailureNeverStartsOrEnrollsTheProvider() async throws {
    let executable = try fixture()
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let request = DesktopAction(id: UUID().uuidString, action: "autopilot", models: ["a"], pinned: [], downloads: ["a", "broken", "c"])
    let backend = DesktopBackend(configPath: nil)
    await #expect(throws: (any Error).self) {
      try await backend.runAutopilot(request, arguments: ["start", "--autopilot", "--model", "a"], worker: DesktopWorker(executable: executable))
    }
    let calls = try String(contentsOfFile: executable.path + ".calls", encoding: .utf8).split(separator: "\n")
    #expect(calls == ["models download a", "models download broken"])
  }
}
