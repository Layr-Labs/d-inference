import Darwin
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `sandbox_setup` follows `darkbloom sandbox setup --json-events` line by line: what setup says (`SandboxSetupEvents`)
/// becomes the operation's `lines`, the installer's events its `sandbox_setup` progress, as the CLI's renderer reads
/// them. A stand-in CLI plays setup here; nothing is downloaded or installed.
struct DesktopSandboxSetupTests {
  static func installer(_ object: String) -> String { SandboxSetupEvents.installer(object)! }

  static let approval = #"""
    {"schema":1,"event":"stage","stage":"waiting_for_approval","step":4,"steps":8,"status":"progress",\#
    "user_code":"WXYZ-1234","verification_uri":"https://api-sandbox.darkbloom.dev/device",\#
    "verification_uri_complete":"https://api-sandbox.darkbloom.dev/device?code=WXYZ-1234","browser_opened":false,\#
    "background":true}
    """#

  @Test func theTrackerReadsLinesAndInstallerEventsAsTheCLIRendersThem() {
    let tracker = DesktopSandboxSetupTracker()
    tracker.consume(SandboxSetupEvents.line("Darkbloom Sandbox setup"))
    tracker.consume(SandboxSetupEvents.line(""))
    tracker.consume(SandboxSetupEvents.line("  \u{1B}[32m[PASS]\u{1B}[0m Chip: Apple M4 Max"))
    tracker.consume(Self.installer(
      #"{"schema":1,"event":"stage","stage":"checking_mac","step":1,"steps":8,"status":"started","message":"Checking this Mac"}"#))
    var snapshot = tracker.snapshot
    #expect(snapshot.sawEvents)
    #expect(snapshot.lines == ["Darkbloom Sandbox setup", "  [PASS] Chip: Apple M4 Max"])
    #expect(snapshot.progress == DesktopSandboxSetupProgress(stage: "checking_mac", step: 1, steps: 8,
                                                             message: "Checking this Mac"))

    tracker.consume(Self.installer(Self.approval))
    snapshot = tracker.snapshot
    #expect(snapshot.progress.stage == "waiting_for_approval")
    #expect(snapshot.progress.step == 4)
    #expect(snapshot.progress.approval == .init(
      user_code: "WXYZ-1234", verification_uri: "https://api-sandbox.darkbloom.dev/device",
      verification_uri_complete: "https://api-sandbox.darkbloom.dev/device?code=WXYZ-1234"))
    #expect(snapshot.progress.background == true)

    tracker.consume(Self.installer(
      #"{"schema":1,"event":"stage","stage":"waiting_for_approval","status":"progress","waitlisted":true}"#))
    #expect(tracker.snapshot.progress.waitlisted == true)
    // Only the approval and waitlist events say whether the wait goes on in the background; a later one keeps it.
    #expect(tracker.snapshot.progress.background == true)

    tracker.consume(Self.installer(
      #"{"schema":1,"event":"stage","stage":"enrolled","step":5,"steps":8,"status":"done","message":"Enrolled as host-1"}"#))
    snapshot = tracker.snapshot
    #expect(snapshot.progress.approval == nil)
    #expect(snapshot.progress.waitlisted == false)
    #expect(snapshot.progress.background == false)
    #expect(snapshot.progress.message == "Enrolled as host-1")

    tracker.consume(Self.installer(
      #"{"schema":1,"event":"stage","stage":"downloading_images","status":"progress","progress":1.7}"#))
    #expect(tracker.snapshot.progress.progress == 1)
    // A summary, another event or another type changes nothing.
    tracker.consume(Self.installer(#"{"schema":1,"event":"summary","host_id":"host-1"}"#))
    tracker.consume(#"{"type":"future","text":"ignored"}"#)
    #expect(tracker.snapshot.progress.stage == "downloading_images")
  }

  @Test func plainTextIsALineAndTheLastFortyAreKept() {
    let tracker = DesktopSandboxSetupTracker()
    tracker.consume("Error: Unknown option '--json-events'")
    #expect(!tracker.snapshot.sawEvents)
    for index in 0..<45 { tracker.consume(SandboxSetupEvents.line("line \(index)")) }
    let lines = tracker.snapshot.lines
    #expect(lines.count == DesktopBackend.operationLineLimit)
    #expect(lines.first == "line 5")
    #expect(lines.last == "line 44")
  }

  @Test func theEventsWriterPassesTheInstallerOnAndSplitsRenderedText() {
    #expect(SandboxSetupEvents.line("a/b") == #"{"text":"a/b","type":"line"}"#)
    #expect(SandboxSetupEvents.line("refused", error: true) == #"{"stream":"error","text":"refused","type":"line"}"#)
    #expect(SandboxSetupEvents.installer("not json") == nil)
    #expect(SandboxSetupEvents.installer(#"[1]"#) == nil)
    let passed = SandboxSetupEvents.installer(#"{"event":"stage","stage":"ready","step":8}"#)
    #expect(passed == #"{"event":{"event":"stage","stage":"ready","step":8},"type":"installer"}"#)
  }

  @Test func installerEventsCarryTheirStep() {
    let event = SandboxInstallerEvent(json: #"{"event":"stage","stage":"installing","step":3,"steps":8,"status":"started"}"#)
    #expect(event?.step == 3)
    #expect(event?.steps == 8)
    #expect(SandboxInstallerEvent(json: #"{"event":"stage","stage":"installing"}"#)?.step == nil)
  }

  /// A stand-in for `sandbox setup --json-events`: its lines, the approval event, then it waits for a cancel, which it
  /// ends with the CLI's words, as the real setup does once its installer took the SIGINT. In Perl, whose handler takes
  /// SIGTERM whatever the stand-in inherited, as the real setup does (`Sandbox.Setup.takeTheAppsCancel`).
  static func fakeSetup() throws -> (directory: URL, script: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-sandbox-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("desktop"),
                                            withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-darkbloom")
    let lines = [
      SandboxSetupEvents.line("Darkbloom Sandbox setup"),
      installer(#"{"schema":1,"event":"stage","stage":"installing","step":3,"steps":8,"status":"started"}"#),
      installer(approval),
      SandboxSetupEvents.line("    Approve this Mac in your browser, signed in to the Darkbloom account that should own it:"),
    ]
    let stopped = SandboxSetupEvents.line(
      "Setup stopped. An enrollment waiting for approval goes on; run `darkbloom sandbox setup` again to follow it.")
    try """
      #!/usr/bin/perl
      use strict;
      $| = 1;
      exit 64 unless join(" ", @ARGV[0..4]) eq "sandbox setup --yes --no-browser --json-events";
      open(my $arguments, ">", "\(directory.path)/arguments") or die;
      print $arguments join("\\n", @ARGV) . "\\n";
      close($arguments);
      $SIG{TERM} = sub { print \(perlQuoted(stopped)) . "\\n"; exit 130; };
      print \(perlQuoted(lines.joined(separator: "\n") + "\n"));
      exit 0 if ($ARGV[5] // "") eq "--linux-slots";
      select(undef, undef, undef, 0.05) while 1;
      """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return (directory, script)
  }

  /// `text` as a single-quoted Perl string.
  static func perlQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
  }

  static func operation(
    _ backend: DesktopBackend, _ id: String, until done: @escaping @Sendable (DesktopOperation) -> Bool
  ) async throws -> DesktopOperation {
    for _ in 0..<1000 {
      let current = await backend.operations.first { $0.id == id }
      if let current, done(current) { return current }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
  }

  static func finished(_ backend: DesktopBackend, _ id: String) async throws -> DesktopOperation {
    try await operation(backend, id) { $0.state != "running" }
  }

  @Test func aRunningSetupReportsItsLinesAndApprovalAndACancelEndsItWithTheCLIsWords() async throws {
    let (directory, script) = try Self.fakeSetup()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await DesktopStorage.$directoryForTesting.withValue(directory.appendingPathComponent("desktop")) {
      let backend = DesktopBackend(configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
      let id = UUID().uuidString
      let submitted = try await backend.submit(DesktopAction(id: id, action: "sandbox_setup"))
      #expect(submitted.cancellable)
      let waiting = try await Self.operation(backend, id) { $0.sandbox_setup?.approval != nil }
      #expect(waiting.state == "running")
      #expect(waiting.sandbox_setup?.stage == "waiting_for_approval")
      #expect(waiting.sandbox_setup?.approval?.user_code == "WXYZ-1234")
      #expect(waiting.lines?.first == "Darkbloom Sandbox setup")
      #expect(waiting.lines?.contains(waiting.message) == true || waiting.message == "Working…")
      #expect(waiting.sandbox_setup?.exit_status == nil)

      let cancelling = try await backend.submit(DesktopAction(id: UUID().uuidString, action: "cancel", operation: id))
      #expect(cancelling.message == "Cancelling…")
      let cancelled = try await Self.finished(backend, id)
      #expect(cancelled.state == "cancelled")
      #expect(cancelled.lines?.last?.hasPrefix("Setup stopped. An enrollment waiting for approval goes on") == true)
      #expect(cancelled.sandbox_setup?.approval?.user_code == "WXYZ-1234")
      #expect(cancelled.sandbox_setup?.exit_status == 130)
      let journal = try String(contentsOf: directory.appendingPathComponent("desktop/operations.json"), encoding: .utf8)
      #expect(journal.contains("waiting_for_approval"))
    }
  }

  @Test func aFinishedSetupKeepsItsLinesAsItsMessage() async throws {
    let (directory, script) = try Self.fakeSetup()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await DesktopStorage.$directoryForTesting.withValue(directory.appendingPathComponent("desktop")) {
      let backend = DesktopBackend(configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
      let id = UUID().uuidString
      _ = try await backend.submit(DesktopAction(id: id, action: "sandbox_setup", linux_slots: 2, wait_ready: true))
      let done = try await Self.finished(backend, id)
      #expect(done.state == "succeeded")
      #expect(done.sandbox_setup?.exit_status == nil)
      #expect(done.message.hasPrefix("Darkbloom Sandbox setup\n"))
      #expect(done.lines?.count == 2)
      let arguments = try String(contentsOf: directory.appendingPathComponent("arguments"), encoding: .utf8)
      #expect(arguments.split(separator: "\n").suffix(3) == ["--linux-slots", "2", "--wait-ready"])
    }
  }

  @Test func aRuntimeWithoutJSONEventsIsNamedInsteadOfItsUsage() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-sandbox-old-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("desktop"),
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("fake-darkbloom")
    try DesktopWorkerTests.writeScript("echo \"Error: Unknown option '--json-events'\" >&2\nexit 64", to: script)
    try await DesktopStorage.$directoryForTesting.withValue(directory.appendingPathComponent("desktop")) {
      let backend = DesktopBackend(configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
      let id = UUID().uuidString
      _ = try await backend.submit(DesktopAction(id: id, action: "sandbox_setup"))
      let done = try await Self.finished(backend, id)
      #expect(done.state == "failed")
      #expect(done.message.hasPrefix("This Darkbloom runtime can't set up Darkbloom Sandbox from the app yet."))
      #expect(done.lines == ["Error: Unknown option '--json-events'"])
      #expect(done.sandbox_setup?.exit_status == 64)
    }
  }

  @Test func aSetupThatFailsReportsTheCLIsExitStatus() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-sandbox-failed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("desktop"),
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("fake-darkbloom")
    let line = SandboxSetupEvents.line("A job is running on this Mac, so the installer changed nothing.")
    try DesktopWorkerTests.writeScript("printf '%s\\n' '\(line)'\nexit 4", to: script)
    try await DesktopStorage.$directoryForTesting.withValue(directory.appendingPathComponent("desktop")) {
      let backend = DesktopBackend(configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
      let id = UUID().uuidString
      _ = try await backend.submit(DesktopAction(id: id, action: "sandbox_setup"))
      let done = try await Self.finished(backend, id)
      #expect(done.state == "failed")
      #expect(done.sandbox_setup?.exit_status == 4)
      #expect(done.message == "A job is running on this Mac, so the installer changed nothing.")
    }
  }
}
