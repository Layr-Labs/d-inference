import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `route_key` hands the account API key to `route key --stdin` on standard input and nowhere else: not argv, not the
/// operation or its journal (`operations.json`), not the snapshot, not an error. A stand-in CLI records what it got and,
/// unlike the real one, echoes the key back, to prove the API scrubs it even then. Nothing reaches the Keychain.
struct DesktopRouteKeyTests {
  static let key = "darkbloom-account-key-fixture-7f3a9c0e5b1d"

  struct Fixture {
    let directory: URL
    let script: URL
    let desktop: URL
    let config: URL
    var arguments: URL { directory.appendingPathComponent("arguments") }
    var input: URL { directory.appendingPathComponent("input") }
  }

  static func fixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-route-key-\(UUID().uuidString)")
    let desktop = directory.appendingPathComponent("desktop")
    try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-darkbloom")
    try DesktopWorkerTests.writeScript("""
      [ "$1 $2" = "route key" ] || exit 64
      printf '%s\\n' "$@" > '\(directory.path)/arguments'
      cat > '\(directory.path)/input'
      printf '✓ Account key saved in this Mac\\x27s Keychain. Darkbloom accepted it.\\n'
      printf 'echoed by a careless CLI: %s\\n' "$(cat '\(directory.path)/input')" >&2
      exit 0
      """, to: script)
    let config = directory.appendingPathComponent("provider.toml")
    try "[provider]\nname = \"Route key fixture\"\n".write(to: config, atomically: true, encoding: .utf8)
    return Fixture(directory: directory, script: script, desktop: desktop, config: config)
  }

  static func finished(_ backend: DesktopBackend, _ id: String) async throws -> DesktopOperation {
    for _ in 0..<500 {
      if let operation = await backend.operations.first(where: { $0.id == id }), operation.state != "running" {
        return operation
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
  }

  @Test func theKeyGoesOnStandardInputAndNeverIntoTheJournalOrTheOperation() async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await DesktopStorage.$directoryForTesting.withValue(fixture.desktop) {
      let backend = DesktopBackend(configPath: fixture.config.path, executable: fixture.script)
      let body = #"{"id":"\#(UUID().uuidString)","action":"route_key","key":"\#(Self.key)"}"#
      let request = try DesktopHTTP.decodeAction(Data(body.utf8))
      let submitted = try await backend.submit(request)
      let operation = try await Self.finished(backend, request.id)

      #expect(operation.state == "succeeded")
      #expect(operation.message.contains("Account key saved"))
      #expect(operation.message.contains("[key]"))
      // What the child got: the key on standard input only.
      #expect(try String(contentsOf: fixture.input, encoding: .utf8) == Self.key + "\n")
      let argv = try String(contentsOf: fixture.arguments, encoding: .utf8)
      #expect(argv == "route\nkey\n--stdin\n--config\n\(fixture.config.path)\n")

      // What anyone else can see: the returned operation, the snapshot's operations and the journal on disk.
      for text in [
        String(decoding: try JSONEncoder().encode(submitted), as: UTF8.self),
        String(decoding: try JSONEncoder().encode(operation), as: UTF8.self),
        String(decoding: try JSONEncoder().encode(DV.encoded(await backend.operations)), as: UTF8.self),
        try String(contentsOf: fixture.desktop.appendingPathComponent("operations.json"), encoding: .utf8),
      ] {
        #expect(!text.contains(Self.key))
        #expect(text.contains(request.id))
      }
      // The journal holds no part of the key's own bytes either.
      let journal = try Data(contentsOf: fixture.desktop.appendingPathComponent("operations.json"))
      #expect(journal.range(of: Data(Self.key.prefix(24).utf8)) == nil)

      // A retry with the same ID and key is the same operation; another key under that ID is refused, in words that
      // don't hold either key.
      #expect(try await backend.submit(request).id == request.id)
      var other = request
      other.key = Self.key + "2"
      do {
        _ = try await backend.submit(other)
        Issue.record("a different key reused the request ID")
      } catch {
        #expect(!String(describing: error).contains(Self.key))
        #expect(DesktopHTTP.errorResponse(for: error).message == "Request ID was already used")
      }
    }
  }

  @Test func aRouteKeyThatTimesOutKeepsTheKeyOutOfItsMessage() {
    let request = DesktopAction(id: UUID().uuidString, action: "route_key", key: Self.key)
    let error = DesktopWorker.RunError.timedOut("checking \(Self.key) with Darkbloom")
    let message = DesktopBackend.withoutKey(String(describing: error), request: request)
    #expect(!message.contains(Self.key))
    #expect(message.contains("checking [key] with Darkbloom"))
  }

  @Test func aRefusedKeyStartsNothingAndRecordsNothing() async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try await DesktopStorage.$directoryForTesting.withValue(fixture.desktop) {
      let backend = DesktopBackend(configPath: fixture.config.path, executable: fixture.script)
      let key = "secret with a space"
      let body = #"{"id":"\#(UUID().uuidString)","action":"route_key","key":"\#(key)"}"#
      do {
        _ = try await backend.submit(try DesktopHTTP.decodeAction(Data(body.utf8)))
        Issue.record("accepted a key with a space")
      } catch {
        let response = DesktopHTTP.errorResponse(for: error)
        #expect(response.status == .badRequest)
        #expect(!response.message.contains(key))
      }
      #expect(await backend.operations.isEmpty)
      #expect(!FileManager.default.fileExists(atPath: fixture.input.path))
      #expect(!FileManager.default.fileExists(atPath: fixture.desktop.appendingPathComponent("operations.json").path))
    }
  }

  @Test func standardInputReachesTheChildAndEnds() async throws {
    let worker = DesktopWorker(executable: URL(fileURLWithPath: "/bin/cat"))
    let (code, output) = try await worker.run([], timeout: 5, input: Data("one line\n".utf8))
    #expect(code == 0)
    #expect(output == "one line\n")
    let (_, empty) = try await worker.run([], timeout: 5)
    #expect(empty == "")
    await #expect(throws: DesktopWorker.RunError.inputTooLarge) {
      try await worker.run([], timeout: 5, input: Data(count: DesktopWorker.maximumInputBytes + 1))
    }
  }
}
