import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `cluster`, `sandbox` and `sandbox-logs` run this build's own commands as children: a stand-in CLI here, which counts
/// its runs. No pairing, add-on, service or network is touched.
struct DesktopClusterSandboxResourcesTests {
  /// A stand-in CLI: `body` is the shell for its runs; each run of `$1 $2` is appended to `runs`.
  static func fakeCLI(_ body: String) throws -> (directory: URL, script: URL, runs: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-resources-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let runs = directory.appendingPathComponent("runs")
    let script = directory.appendingPathComponent("fake-darkbloom")
    try "#!/bin/sh\necho \"$1 $2\" >> '\(runs.path)'\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return (directory, script, runs)
  }

  static func runs(_ file: URL, _ command: String) -> Int {
    ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == command }.count
  }

  static let notServing = #"""
    {"schema":1,"paired":true,"role":"leader","this_mac":"Mac Studio","other_mac":{"name":"Apple M5 Max, 128 GB","answers":false},
    "model":{"id":"qwen3.8-27b","name":"Qwen 3.8 27B"},"mode":"tensor parallel","split":"M3 Ultra 50% / M5 Max 50%",
    "serves":"darkbloom","state":"other_mac_away","reason":"The other Mac isn't answering","next":"Leave both Macs running.",
    "lines":["Cluster: this Mac leads"],"service":{"running":true,"starts_at_login":true},"exit_code":5}
    """#

  @Test func clusterPassesTheCLIDocumentThroughForEveryStatusExit() async throws {
    let (directory, script, runs) = try Self.fakeCLI("""
      [ "$1 $2" = "cluster status" ] || exit 64
      [ "$3" = --json ] && [ "$4" = --config ] || exit 65
      printf 'Waiting for the leading Mac\\x27s answer (up to 10 s).\\n' >&2
      cat <<'JSON'
      \(Self.notServing)
      JSON
      exit 5
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
    let reads = try await withThrowingTaskGroup(of: DV.self) { group in
      for _ in 0..<5 { group.addTask { try await backend.resource("cluster") } }
      return try await group.reduce(into: []) { $0.append($1) }
    }
    let expected = try JSONDecoder().decode(DV.self, from: Data(Self.notServing.utf8))
    for value in reads { #expect(value == expected) }
    #expect(Self.runs(runs, "cluster status") == 1)
    _ = try await backend.resource("cluster")
    #expect(Self.runs(runs, "cluster status") == 1)
    await backend.forgetSharedReads(after: "download")
    _ = try await backend.resource("cluster")
    #expect(Self.runs(runs, "cluster status") == 1)
    await backend.forgetSharedReads(after: "cluster_leave")
    _ = try await backend.resource("cluster")
    #expect(Self.runs(runs, "cluster status") == 2)
  }

  @Test func clusterWithoutADocumentKeepsTheShapeAndSaysWhy() {
    let usage = DesktopBackend.clusterStatus(
      exitCode: 64, output: "", errors: "Error: Unknown option '--json'\nUsage: darkbloom cluster status\n")
    #expect(usage.field("state").text == "unknown")
    #expect(usage.field("exit_code") == .int(-1))
    #expect(usage.field("lines") == .array([]))
    #expect(usage.field("error").text == "Usage: darkbloom cluster status")
    for key in ["paired", "role", "this_mac", "other_mac", "model", "mode", "split", "serves", "reason", "next", "service"] {
      #expect(usage.field(key) == .null, "\(key)")
    }
    // A document with an exit status that never prints one is not trusted either.
    let crashed = DesktopBackend.clusterStatus(exitCode: 1, output: Self.notServing, errors: "")
    #expect(crashed.field("state").text == "unknown")
    #expect(crashed.field("error").text?.contains("printed no status (exit 1)") == true)
    let notJSON = DesktopBackend.clusterStatus(exitCode: 6, output: "not json", errors: "")
    #expect(notJSON.field("state").text == "unknown")
    let notPaired = DesktopBackend.clusterStatus(
      exitCode: 6, output: #"{"schema":1,"state":"not_paired","paired":false,"exit_code":6}"#, errors: "")
    #expect(notPaired.field("state").text == "not_paired")
    #expect(notPaired.field("error") == .null)
  }

  @Test func clusterThatCannotRunIsUnknown() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
    let value = await DesktopBackend.readClusterStatus(executable: missing, configPath: nil)
    #expect(value.field("state").text == "unknown")
    #expect(value.field("error").text?.contains("couldn't run") == true)
  }

  @Test func sandboxStatusIsTheAddOnDocumentWhateverItsExitWithSecondsForTheUpdateCheck() async throws {
    let (directory, script, runs) = try Self.fakeCLI("""
      [ "$1 $2 $3" = "sandbox status --json" ] || exit 64
      printf '%s\\n' '{"schema":1,"installed":false,"state":"not_installed","last_update_check":1762560000123,"slots":null}'
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
    let value = try await backend.resource("sandbox")
    #expect(value.field("state").text == "not_installed")
    #expect(value.field("installed").flag == false)
    #expect(value.field("slots") == .null)
    #expect(value.field("last_update_check").number == 1_762_560_000.123)
    _ = try await backend.resource("sandbox")
    #expect(Self.runs(runs, "sandbox status") == 1)
    await backend.forgetSharedReads(after: "sandbox_pause")
    _ = try await backend.resource("sandbox")
    #expect(Self.runs(runs, "sandbox status") == 2)
  }

  @Test(arguments: [
    ("1762560000", 1_762_560_000.0), ("1762560000000", 1_762_560_000.0), (#""2025-11-08T00:00:00Z""#, 1_762_560_000.0),
    (#""2025-11-08T00:00:00.500Z""#, 1_762_560_000.5), ("null", nil), (#""soon""#, nil),
  ] as [(String, Double?)])
  func sandboxUpdateCheckIsReadAsTheCLIReadsIt(raw: String, seconds: Double?) {
    let value = DesktopBackend.sandboxStatus(
      output: #"{"schema":1,"state":"ready","last_update_check":\#(raw)}"#, errors: "", exitCode: 0)
    #expect(value.field("state").text == "ready")
    #expect(value.field("last_update_check").number == seconds)
  }

  @Test func sandboxStatusWithoutADocumentSaysWhy() {
    let failed = DesktopBackend.sandboxStatus(
      output: "", errors: "The Darkbloom Sandbox add-on did not answer within 10 seconds.\n", exitCode: 1)
    #expect(failed == .dict([
      "schema": .int(1), "state": .string("unknown"),
      "error": .string("The Darkbloom Sandbox add-on did not answer within 10 seconds."),
    ]))
    // Only an integer schema of 1 or more and a string state make a document, as for the CLI.
    for output in [#"{"state":"ready"}"#, #"{"schema":0,"state":"ready"}"#, #"{"schema":1,"state":3}"#, "[]"] {
      #expect(DesktopBackend.sandboxStatus(output: output, errors: "", exitCode: 0).field("state").text == "unknown")
    }
  }

  @Test func sandboxLogsAreTheLastLinesSanitizedAndBounded() async throws {
    let (directory, script, _) = try Self.fakeCLI("""
      [ "$1 $2 $3 $4" = "sandbox logs -n 200" ] || exit 64
      i=0
      while [ "$i" -lt 250 ]; do printf 'line %s\\n' "$i"; i=$((i + 1)); done
      printf '\\033[31mred\\033[0m and \\033]0;title\\007bell\\001 done\\n'
      printf 'progress 10%%\\rprogress 90%%\\n'
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
    let value = try await backend.resource("sandbox-logs")
    let lines = value.field("lines").values.compactMap(\.text)
    #expect(lines.count == 200)
    #expect(lines.first == "line 52")
    #expect(lines.suffix(2) == ["red and bell done", "progress 90%"])
    #expect(value.field("observed_at").number != nil)
    #expect(value.field("error") == .null)
  }

  @Test func longLogLinesKeepTheLastWholeLinesWithinTheBound() async throws {
    let (directory, script, _) = try Self.fakeCLI("""
      i=0
      while [ "$i" -lt 200 ]; do printf '%0300d\\n' "$i"; i=$((i + 1)); done
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let value = await DesktopBackend.readSandboxLogs(executable: script)
    let lines = value.field("lines").values.compactMap(\.text)
    #expect(value.field("error") == .null)
    #expect(lines.count == DesktopWorker.outputLimit / 301)
    #expect(lines.allSatisfy { $0.count == 300 })
    #expect(lines.last == String(format: "%0300d", 199))
  }

  @Test func sandboxLogsThatFailSayWhy() async throws {
    let (directory, script, _) = try Self.fakeCLI("exit 3")
    defer { try? FileManager.default.removeItem(at: directory) }
    let value = await DesktopBackend.readSandboxLogs(executable: script)
    #expect(value.field("lines") == .array([]))
    #expect(value.field("error").text?.contains("exited 3") == true)
  }

  @Test func textKeepsWhatATerminalShows() {
    #expect(DesktopText.line("\u{1B}[1;32m✓\u{1B}[0m Ready\t now  ") == "✓ Ready  now")
    #expect(DesktopText.line("a\u{202E}b\u{200B}c\u{0085}d\u{2028}e") == "abcde")
    #expect(DesktopText.line("\u{1B}]8;;https://x\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "link")
    #expect(DesktopText.line(String(repeating: "x", count: 1200)).count == 1000)
    #expect(DesktopText.lastLines("a\r\n\n\u{1B}[2K\nb\nc\n", count: 2) == ["b", "c"])
  }
}
