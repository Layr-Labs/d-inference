import Foundation
import Testing

@testable import darkbloom

/// The cooling resource runs a real child process; rapid and concurrent reads
/// must share one run instead of each spawning `fan status`.
struct DesktopCoolingCacheTests {
  /// A stand-in CLI that counts its runs and prints a `fan status --json` body.
  static func fakeCLI() throws -> (directory: URL, script: URL, counter: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-cooling-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let counter = directory.appendingPathComponent("runs")
    let script = directory.appendingPathComponent("fake-darkbloom")
    try """
    #!/bin/sh
    echo run >> '\(counter.path)'
    sleep 0.3
    printf '%s' '{"helper":{"mode":"automatic"},"diagnostic":{"supported":true,\
    "fans":[{"name":"Left","actualRPM":1200,"maximumRPM":5000}],\
    "gpuTemperatures":[{"celsius":51.5},{"celsius":48}]}}'
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return (directory, script, counter)
  }

  static func runs(_ counter: URL) throws -> Int {
    try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
  }

  @Test func concurrentAndRepeatedReadsShareOneFanStatusChild() async throws {
    let (directory, script, counter) = try Self.fakeCLI()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(
      configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
    let reads = try await withThrowingTaskGroup(of: DV.self) { group in
      for _ in 0..<5 { group.addTask { try await backend.resource("cooling") } }
      return try await group.reduce(into: []) { $0.append($1) }
    }
    let repeated = try await backend.resource("cooling")

    #expect(try Self.runs(counter) == 1)
    for value in reads + [repeated] {
      #expect(value.field("supported").flag == true)
      #expect(value.field("temperature").number == 51.5)
      #expect(value.field("fans").values.count == 1)
    }
  }

  @Test func aFinishedCoolingChangeInvalidatesTheCache() async throws {
    let (directory, script, counter) = try Self.fakeCLI()
    defer { try? FileManager.default.removeItem(at: directory) }
    let backend = DesktopBackend(
      configPath: directory.appendingPathComponent("provider.toml").path, executable: script)
    _ = try await backend.resource("cooling")
    await backend.operationFinished("download")
    _ = try await backend.resource("cooling")
    #expect(try Self.runs(counter) == 1)
    await backend.operationFinished("cooling")
    _ = try await backend.resource("cooling")
    #expect(try Self.runs(counter) == 2)
  }
}
