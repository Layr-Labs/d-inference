import Foundation
import Testing

@testable import darkbloom

/// The child-output readers hand each line on as soon as the child writes it, not when a read buffer fills or the child
/// exits: an approval link the child prints and then waits on must reach the person while it waits. Real child
/// processes only.
@Suite("Child output promptness")
struct ChildOutputPromptnessTests {
  /// True once `lines` holds `expected`; false after 2 s.
  static func arrives(_ lines: DesktopLines, _ expected: [String]) async throws -> Bool {
    for _ in 0..<200 {
      if lines.all == expected { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  @Test("DesktopWorker hands a line on while the child still runs")
  func desktopWorkerLines() async throws {
    let seen = DesktopLines()
    let worker = DesktopWorker(executable: URL(fileURLWithPath: "/bin/sh"))
    let run = Task {
      try await worker.run(["-c", "printf 'first\\n'; exec /bin/sleep 30"], timeout: 60, lines: { seen.append($0) })
    }
    #expect(try await Self.arrives(seen, ["first"]))
    run.cancel()
    await #expect(throws: CancellationError.self) { try await run.value }
  }

  @Test("SandboxChildProcess hands a line on while the child still runs")
  func sandboxChildLines() async throws {
    let seen = DesktopLines()
    let run = Task {
      try await SandboxChildProcess.run(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'first\\n'; exec /bin/sleep 3"], closeStandardInput: true,
        standardOutput: .lines { seen.append($0) })
    }
    #expect(try await Self.arrives(seen, ["first"]))
    #expect(try await run.value.succeeded)
  }
}
