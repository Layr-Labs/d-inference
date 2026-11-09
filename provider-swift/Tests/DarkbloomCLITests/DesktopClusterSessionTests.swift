import Darwin
import Foundation
import Hummingbird
import NIOCore
import ProviderCore
import Testing

@testable import darkbloom

/// The guided cluster setup's routes on a real loopback socket, with a fake child in place of
/// `darkbloom cluster --app-console`: no cluster, service, pairing, credential or network is touched.
@Suite(.serialized) struct DesktopClusterSessionTests {
  private let token = "fixture-token"
  static let config = "/nonexistent-desktop-test-config"

  /// A fake `darkbloom` that writes its arguments and every answer it reads into `directory`, then runs `body`.
  static func fixture(_ body: String) throws -> (directory: URL, script: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("desktop-cluster-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-darkbloom")
    try DesktopWorkerTests.writeScript(
      "dir='\(directory.path)'\nprintf '%s\\n' \"$*\" > \"$dir/argv\"\n\(body)", to: script)
    return (directory, script)
  }

  /// The setup's screen up to the code question, then the answer's outcome; a cancel ends as q does (130).
  static let interactive = """
    printf '%s\\n' '{"event":"banner","title":"Darkbloom cluster","subtitle":""}'
    printf '%s\\n' 'A line that is not an event'
    printf '%s\\n' '{"event":"working","rows":["Checking the cable"]}'
    printf '%s\\n' '{"event":"working","rows":["Checking the cable · 1 s"]}'
    printf '%s\\n' '{"event":"say","text":"  Code 123 456. Same on the other Mac?"}'
    printf '%s\\n' '{"event":"question","question":{"id":"q1","type":"choose","options":[["Yes"],["No"]],"selected":0}}'
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$dir/answers"
      case "$line" in
        *cancel*)
          printf '%s\\n' '{"event":"question","question":null}' '{"event":"say","text":"Cancelled: nothing paired."}' '{"code":130,"event":"exit"}'
          exit 130 ;;
        *q1*)
          printf '%s\\n' '{"event":"question","question":null}' '{"event":"progress","text":"Copying: 1 of 2 GB"}'
          printf '%s\\n' '{"event":"result","ok":true,"title":"Serving Qwen","lines":["Test response in 0.61 s"]}' '{"code":0,"event":"exit"}'
          exit 0 ;;
      esac
    done
    exit 1
    """

  private func withServer(executable: URL, _ body: @Sendable (URL) async throws -> Void) async throws {
    let (ports, port) = AsyncStream.makeStream(of: Int.self)
    let app = Application(
      responder: DesktopHTTP(backend: DesktopBackend(configPath: Self.config, executable: executable), token: token),
      configuration: .init(address: .hostname("127.0.0.1", port: 0)),
      onServerRunning: { channel in
        port.yield(channel.localAddress?.port ?? 0)
        port.finish()
      })
    let server = Task { try await app.runService(gracefulShutdownSignals: []) }
    defer { server.cancel() }
    var iterator = ports.makeAsyncIterator()
    let bound = try #require(await iterator.next())
    try await body(URL(string: "http://127.0.0.1:\(bound)")!)
  }

  private func call(
    _ base: URL, _ path: String, json: String? = nil, contentType: String = "application/json", authorized: Bool = true
  ) async throws -> (JSONValue, Int) {
    var request = URLRequest(url: base.appendingPathComponent(path))
    if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let json {
      request.httpMethod = "POST"
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(json.utf8)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = try #require(response as? HTTPURLResponse).statusCode
    return ((try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null, status)
  }

  /// The session once `done` holds for it, or after five seconds.
  private func session(_ base: URL, until done: (JSONValue) -> Bool) async throws -> JSONValue {
    for _ in 0..<500 {
      let (session, _) = try await call(base, "control/v1/cluster/session")
      if done(session) { return session }
      try await Task.sleep(for: .milliseconds(10))
    }
    return try await call(base, "control/v1/cluster/session").0
  }

  /// `value` with every object's keys in order: the API's JSON objects carry no key order.
  private static func sorted(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let pairs): return .object(pairs.map { ($0.0, sorted($0.1)) }.sorted { $0.0 < $1.0 })
    case .array(let items): return .array(items.map(sorted))
    default: return value
    }
  }

  private static func lines(_ url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }

  @Test func theSetupRunsAsAChildAndItsScreenAndAnswersGoThroughTheSession() async throws {
    let (directory, script) = try Self.fixture(Self.interactive)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await withServer(executable: script) { base in
      #expect(try await call(base, "control/v1/cluster/session") == (.null, 200))
      let (started, status) = try await call(base, "control/v1/cluster/session", json: #"{"kind":"setup"}"#)
      #expect(status == 202)
      #expect(started.field("kind") == .string("setup") && started.field("state") == .string("running"))
      #expect(started.field("started_at").number != nil && started.field("finished_at") == .null)
      let asked = try await session(base) { $0.field("question") != .null }
      #expect(Self.lines(directory.appendingPathComponent("argv")) == ["cluster --app-console --config \(Self.config)"])
      // The console's `event` is the app's `type`; a line that isn't an event is said; live rows end at the next line.
      #expect(Self.sorted(asked.field("events")) == .array([
        .dict(["type": .string("banner"), "title": .string("Darkbloom cluster"), "subtitle": .string("")]),
        .dict(["type": .string("say"), "text": .string("A line that is not an event")]),
        .dict(["type": .string("say"), "text": .string("  Code 123 456. Same on the other Mac?")]),
      ]))
      #expect(Self.sorted(asked.field("question")) == .dict([
        "id": .string("q1"), "type": .string("choose"),
        "options": .array([.array([.string("Yes")]), .array([.string("No")])]), "selected": .int(0),
      ]))
      // One setup at a time, and it holds the mutation slot.
      #expect(try await call(base, "control/v1/cluster/session", json: #"{"kind":"setup"}"#)
        == (.dict(["error": .string("A cluster setup is already running.")]), 409))
      let action = #"{"id":"\#(UUID().uuidString)","action":"stop"}"#
      #expect(try await call(base, "control/v1/actions", json: action)
        == (.dict(["error": .string("A cluster setup is already running.")]), 400))
      // Only the question asked now, with one of its options.
      #expect(try await call(base, "control/v1/cluster/session/answer", json: #"{"question":"q2","choice":0}"#).1 == 409)
      #expect(try await call(base, "control/v1/cluster/session/answer", json: #"{"question":"q1","choice":2}"#).1 == 400)
      #expect(try await call(base, "control/v1/cluster/session/answer", json: #"{"question":"q1","key":"q"}"#).1 == 400)
      let (answered, answerStatus) = try await call(
        base, "control/v1/cluster/session/answer", json: #"{"question":"q1","choice":0}"#)
      #expect(answerStatus == 200 && answered.field("question") == .null)
      let ended = try await session(base) { $0.field("state") != .string("running") }
      #expect(ended.field("state") == .string("succeeded") && ended.field("exit_code") == .int(0))
      #expect(ended.field("finished_at").number != nil && ended.field("error") == .null)
      #expect(ended.field("events").values.last.map(Self.sorted)
        == .dict(["type": .string("result"), "ok": .bool(true), "title": .string("Serving Qwen"),
                  "lines": .array([.string("Test response in 0.61 s")])]))
      #expect(!ended.field("events").values.contains { $0.field("type") == .string("progress") }, "live work ends with the next line")
      let written = Self.lines(directory.appendingPathComponent("answers"))
      #expect(written.count == 1)
      let line = try JSONDecoder().decode(JSONValue.self, from: Data((written.first ?? "").utf8))
      #expect(line.field("question") == .string("q1") && line.field("choice") == .int(0))
      // Once it ended, answers are refused and another setup may start.
      #expect(try await call(base, "control/v1/cluster/session/answer", json: #"{"cancel":true}"#)
        == (.dict(["error": .string("No cluster setup is running.")]), 409))
    }
  }

  @Test func aLocalSetupNamesItsModelAndAddressAndACancelEndsItAsQDoes() async throws {
    let (directory, script) = try Self.fixture(Self.interactive)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await withServer(executable: script) { base in
      let start = #"{"kind":"local","model":"mlx-community/Qwen3.5-9B-4bit","bind":"127.0.0.1"}"#
      #expect(try await call(base, "control/v1/cluster/session", json: start).1 == 202)
      _ = try await session(base) { $0.field("question") != .null }
      #expect(Self.lines(directory.appendingPathComponent("argv"))
        == ["cluster local --app-console --bind 127.0.0.1 --config \(Self.config) mlx-community/Qwen3.5-9B-4bit"])
      let (cancelling, status) = try await call(base, "control/v1/cluster/session/answer", json: #"{"cancel":true}"#)
      #expect(status == 200 && cancelling.field("question") == .null && cancelling.field("state") == .string("running"))
      let ended = try await session(base) { $0.field("state") != .string("running") }
      #expect(ended.field("state") == .string("cancelled") && ended.field("exit_code") == .int(130))
      #expect(ended.field("events").values.last.map(Self.sorted) == .dict(["type": .string("say"), "text": .string("Cancelled: nothing paired.")]))
      #expect(Self.lines(directory.appendingPathComponent("answers")) == [#"{"cancel":true}"#])
    }
  }

  @Test func startsAndAnswersAreValidated() async throws {
    let (directory, script) = try Self.fixture("exit 0")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await withServer(executable: script) { base in
      let path = "control/v1/cluster/session"
      for body in [
        #"{"kind":"pair"}"#, #"{"kind":"setup","model":"qwen"}"#, #"{"kind":"setup","bind":"127.0.0.1"}"#,
        #"{"kind":"local","model":"../escape"}"#, #"{"kind":"local","model":"--worker"}"#, #"{"kind":"local","bind":"example.com"}"#,
        #"{"model":"qwen"}"#, "not json",
      ] {
        let (_, status) = try await call(base, path, json: body)
        #expect(status == 400, "\(body)")
      }
      let plain = try await call(base, path, json: #"{"kind":"setup"}"#, contentType: "text/plain")
      #expect(plain.1 == 415)
      let anonymous = try await call(base, path, authorized: false)
      #expect(anonymous.1 == 401)
      let unasked = try await call(base, path + "/answer", json: #"{"question":"q1","choice":0}"#)
      #expect(unasked == (.dict(["error": .string("No cluster setup is running.")]), 409))
      let current = try await call(base, path)
      #expect(current.0 == .null, "nothing was started")
    }
  }

  @Test func aChildThatEndsWithoutItsExitSaysWhy() async throws {
    let cases = [
      ("printf '%s\\n' \"Error: Unknown option '--app-console'\" >&2; exit 64", Int64(64),
       "The installed Darkbloom runtime doesn’t support this yet. It needs a runtime release that includes the desktop app’s commands."),
      ("printf 'first\\nsecond\\n' >&2; exit 3", 3, "first\nsecond"),
      ("kill -9 $$", 137, "The cluster setup stopped (signal 9)."),
    ]
    for (body, code, error) in cases {
      let (directory, script) = try Self.fixture(body)
      defer { try? FileManager.default.removeItem(at: directory) }
      try await withServer(executable: script) { base in
        #expect(try await call(base, "control/v1/cluster/session", json: #"{"kind":"setup"}"#).1 == 202)
        let ended = try await session(base) { $0.field("state") != .string("running") }
        #expect(ended.field("state") == .string("failed") && ended.field("exit_code") == .int(code), "\(body)")
        #expect(ended.field("error") == .string(error), "\(body)")
      }
    }
  }

  @Test func theEventStreamSendsTheWholeSessionOnEveryChange() async throws {
    let (directory, script) = try Self.fixture(Self.interactive)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await withServer(executable: script) { base in
      var request = URLRequest(url: base.appendingPathComponent("control/v1/cluster/session/events"))
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let (bytes, response) = try await URLSession.shared.bytes(for: request)
      #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
      var frames: [JSONValue] = []
      var event: String?
      for try await line in bytes.lines {
        if line.hasPrefix("event: ") { event = String(line.dropFirst(7)); continue }
        guard line.hasPrefix("data: ") else { continue }
        #expect(event == "cluster-session")
        frames.append(try JSONDecoder().decode(JSONValue.self, from: Data(line.dropFirst(6).utf8)))
        if frames.count == 1 {
          #expect(frames[0] == .null, "no session yet")
          _ = try await call(base, "control/v1/cluster/session", json: #"{"kind":"setup"}"#)
        }
        if frames.last?.field("question") != .null { break }
      }
      #expect(frames.count >= 2 && frames.dropFirst().allSatisfy { $0.field("kind") == .string("setup") })
      #expect(frames.last?.field("question").field("id") == .string("q1"))
      _ = try await call(base, "control/v1/cluster/session/answer", json: #"{"cancel":true}"#)
      _ = try await session(base) { $0.field("state") != .string("running") }
    }
  }

  @Test func theRuntimeOffersTheSession() {
    #expect(DesktopBackend.snapshotCapabilities(paired: false).contains("cluster_session"))
    #expect(DesktopBackend.snapshotCapabilities(paired: true).contains("cluster_session"))
  }
}
