import Darwin
import Foundation
import Testing

@testable import darkbloom

/// The child-output readers keep only their bounded tail resident while a
/// child runs. Each reader is one Dispatch block for the child's whole life,
/// and a block drains no autorelease pool before it returns: without a pool
/// per read, every byte the child wrote stays resident until it exits. A tail
/// kept as a slice of its buffer keeps every byte too. Real child processes
/// only.
@Suite("Child output read memory")
struct ChildOutputReadMemoryTests {
  private static let outputBytes = 256 << 20
  private static let allowedGrowth: UInt64 = 64 << 20

  @Test("DesktopWorker keeps only its output tail while the child runs")
  func desktopWorkerReader() async throws {
    try await Self.withChild { script, written, release in
      try DesktopWorkerTests.writeScript(Self.childScript(written: written, release: release), to: script)
      let before = try #require(Self.footprint())
      async let outcome = DesktopWorker(executable: script).run([], timeout: 120)
      let finished = try await Self.waitForFile(written)
      let during = try #require(Self.footprint())
      #expect(FileManager.default.createFile(atPath: release.path, contents: nil))
      let (code, output) = try await outcome
      #expect(finished, "the child never finished writing")
      #expect(code == 0)
      #expect(output == String(repeating: "\u{0}", count: 32_768))
      Self.expectBoundedGrowth("DesktopWorker", from: before, to: during)
    }
  }

  @Test("SandboxChildProcess keeps only its output tail while the child runs")
  func sandboxChildReader() async throws {
    try await Self.withChild { _, written, release in
      let tail = SandboxOutputTail()
      let before = try #require(Self.footprint())
      async let outcome = SandboxChildProcess.run(
        URL(fileURLWithPath: "/bin/sh"), ["-c", Self.childScript(written: written, release: release)],
        closeStandardInput: true, standardOutput: .tail(tail))
      let finished = try await Self.waitForFile(written)
      let during = try #require(Self.footprint())
      #expect(FileManager.default.createFile(atPath: release.path, contents: nil))
      let exit = try await outcome
      #expect(finished, "the child never finished writing")
      #expect(exit.succeeded)
      #expect(tail.lastLines(1) == [String(repeating: "\u{0}", count: 32 * 1024)])
      Self.expectBoundedGrowth("SandboxChildProcess", from: before, to: during)
    }
  }

  /// The child writes `outputBytes` zero bytes, marks `written` (by then the
  /// reader has taken all but one pipe buffer of them) and waits, at most
  /// 60 s, for `release`.
  private static func childScript(written: URL, release: URL) -> String {
    """
    head -c \(outputBytes) /dev/zero
    : > '\(written.path)'
    i=0
    while [ ! -e '\(release.path)' ] && [ "$i" -lt 1200 ]; do sleep 0.05; i=$((i + 1)); done
    """
  }

  private static func withChild(_ body: (URL, URL, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("child-output-memory-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(
      directory.appendingPathComponent("fake-darkbloom"), directory.appendingPathComponent("written"),
      directory.appendingPathComponent("release"))
  }

  /// True once `url` exists; false after 60 s.
  private static func waitForFile(_ url: URL) async throws -> Bool {
    for _ in 0..<3000 {
      if FileManager.default.fileExists(atPath: url.path) { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  private static func expectBoundedGrowth(_ reader: String, from before: UInt64, to during: UInt64) {
    let growth = during > before ? during - before : 0
    #expect(growth < allowedGrowth, "\(reader) held \(growth) bytes of \(outputBytes) read")
  }

  private static func footprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
  }
}
