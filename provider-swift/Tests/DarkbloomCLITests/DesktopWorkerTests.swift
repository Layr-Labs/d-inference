import Darwin
import Foundation
import Testing

@testable import darkbloom

/// Real child processes only; no provider, service, credentials, or network access.
struct DesktopWorkerTests {
  static func fixture(_ body: String) throws -> (directory: URL, script: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-worker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-darkbloom")
    try writeScript(body, to: script)
    return (directory, script)
  }

  static func writeScript(_ body: String, to script: URL) throws {
    try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
  }

  @Test func ordinaryCommandsKeepStderrDiagnosticsAndExitStatus() async throws {
    let (directory, script) = try Self.fixture("""
      printf 'diagnostic\\n' >&2
      printf 'answer\\n'
      exit 7
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (code, output) = try await DesktopWorker(executable: script).run([], timeout: 5)
    #expect(code == 7)
    #expect(output.contains("diagnostic\n"))
    #expect(output.contains("answer\n"))
  }

  @Test func stdoutCaptureDiscardsLargeStderrAndDrainsTheFinalOutput() async throws {
    let (directory, script) = try Self.fixture("""
      i=0
      while [ "$i" -lt 8192 ]; do
        printf 'diagnostic noise on stderr\\n' >&2
        i=$((i + 1))
      done
      printf '0.9.20\\n'
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (code, output) = try await DesktopWorker(executable: script).run(
      [], timeout: 5, capture: .standardOutput)
    #expect(code == 0)
    #expect(output == "0.9.20\n")
  }

  @Test func combinedOutputStaysBoundedAndTruncatedStdoutFailsClosed() async throws {
    let (directory, script) = try Self.fixture("""
      i=0
      while [ "$i" -lt 8192 ]; do
        printf 'stdout log line\\n'
        printf 'stderr log line\\n' >&2
        i=$((i + 1))
      done
      printf 'finished\\n'
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let worker = DesktopWorker(executable: script)
    let (code, output) = try await worker.run([], timeout: 5) { progress in
      #expect(progress.utf8.count <= 32_768)
    }
    #expect(code == 0)
    #expect(output.utf8.count == 32_768)
    #expect(output.hasSuffix("finished\n"))
    await #expect(throws: DesktopWorker.RunError.outputLimitExceeded) {
      try await worker.run([], timeout: 5, capture: .standardOutput)
    }
  }

  @Test func aLaunchFailureDoesNotLeaveTheWorkerBusy() async throws {
    let (directory, script) = try Self.fixture("printf 'ready\\n'")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.removeItem(at: script)
    let worker = DesktopWorker(executable: script)
    await #expect(throws: (any Error).self) { try await worker.run([], timeout: 5) }
    try Self.writeScript("printf 'ready\\n'", to: script)
    let (code, output) = try await worker.run([], timeout: 5, capture: .standardOutput)
    #expect(code == 0)
    #expect(output == "ready\n")
  }

  static let stubbornChild = """
    if [ "$1" = hang ]; then
      trap '' TERM
      echo $$ > "$2"
      printf '0.9.20\\n'
      printf 'waiting for termination\\n' >&2
      exec /bin/sleep 30
    fi
    printf 'ready\\n'
    """

  static func waitForPID(_ file: URL) async throws -> pid_t {
    for _ in 0..<200 {
      if let text = try? String(contentsOf: file, encoding: .utf8),
        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
      { return pid }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileReadNoSuchFile)
  }

  @Test func taskCancellationReapsAChildThatIgnoresTermination() async throws {
    let (directory, script) = try Self.fixture(Self.stubbornChild)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let worker = DesktopWorker(executable: script)
    let task = Task { try await worker.run(["hang", pidFile.path], timeout: 5, capture: .standardOutput) }
    defer { task.cancel() }
    let pid = try await Self.waitForPID(pidFile)
    defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  @Test(arguments: [DesktopWorker.OutputCapture.combined, .standardOutput])
  func aTimedOutProbeIsReapedAndDoesNotCancelCapabilityDiscovery(capture: DesktopWorker.OutputCapture) async throws {
    let (directory, script) = try Self.fixture(Self.stubbornChild)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let worker = DesktopWorker(executable: script)
    let task = Task { try await worker.run(["hang", pidFile.path], timeout: 0.5, capture: capture) }
    defer { task.cancel() }
    let pid = try await Self.waitForPID(pidFile)
    defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
    let expected = "0.9.20\n" + (capture == .combined ? "waiting for termination\n" : "")
    await #expect(throws: DesktopWorker.RunError.timedOut(expected)) { try await task.value }
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    let (code, output) = try await worker.run([], timeout: 5)
    #expect(code == 0)
    #expect(output == "ready\n")
  }

  @Test func aCompletedCommandsDeadlineDoesNotStopTheNextCommand() async throws {
    let worker = DesktopWorker(executable: URL(fileURLWithPath: "/bin/sleep"))
    _ = try await worker.run(["0"], timeout: 0.1)
    let (code, _) = try await worker.run(["0.3"], timeout: 5)
    #expect(code == 0)
  }
}
