import ArgumentParser
import Darwin
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import ProviderCore

/// What `POST /control/v1/cluster/session` starts: `setup` runs `darkbloom cluster --app-console`, `local` runs
/// `darkbloom cluster local --app-console [model] [--bind address]` (`desktop-app/src/shared/cluster.ts`,
/// `ClusterSessionStart`).
struct DesktopClusterSessionStart: Decodable, Equatable, Sendable {
  let kind: String
  var model: String?
  var bind: String?

  func validate() throws {
    guard ["setup", "local"].contains(kind) else { throw ValidationError("Unknown cluster setup kind") }
    guard kind == "local" || (model == nil && bind == nil) else {
      throw ValidationError("Only a local cluster setup takes a model or an address")
    }
    if let model { try DesktopAction.validateModel(model) }
    if let bind, !ClusterServingScope.isValidBind(bind) {
      throw ValidationError(
        "The address must be localhost or a numeric IPv4 or IPv6 address (0.0.0.0 = every network of the leading Mac)")
    }
  }

  /// The child's argument array: `--config` as every child gets it, made absolute, as the setup requires.
  func arguments(configPath: String?) -> [String] {
    let config = configPath.map { ["--config", URL(fileURLWithPath: $0).standardizedFileURL.path] } ?? []
    guard kind == "local" else { return ["cluster", "--app-console"] + config }
    return ["cluster", "local", "--app-console"] + (bind.map { ["--bind", $0] } ?? []) + config + (model.map { [$0] } ?? [])
  }
}

/// `POST /control/v1/cluster/session/answer`: a `choose` question's `choice`, a `key` question's `key`, or `cancel`
/// (`ClusterSessionAnswer`).
struct DesktopClusterSessionAnswer: Decodable, Sendable {
  var question: String?
  var choice: Int?
  var key: String?
  var cancel: Bool?
}

/// The desktop app's guided cluster setup: one child at a time running the onboarding with the app's console
/// (`ClusterOnboardingAppConsole`), its screen kept as a session the app reads, watches and answers. The child's JSON
/// lines become the session's `events` (the console's `event` is the app's `type`) and `question`; a line that isn't
/// JSON is said as it is. A running session holds the API's mutation slot: it starts and stops this Mac's services
/// itself, so it starts only while no operation runs, and actions are refused while it runs
/// (`DesktopBackend.submit`). It lives in this API process: a restarted API has none, and its child sees its input
/// end, which leaves the setup as a cancel does.
final class DesktopClusterSessions: @unchecked Sendable {
  static let busyMessage = "A cluster setup is already running."
  static let maximumEvents = 600
  /// The longest line read from the child; a longer one is dropped.
  static let maximumLine = 262_144
  /// How long a session waits for the rest of the child's output once it exited.
  static let drainSeconds = 2.0
  /// An event stream renews after this many frames or seconds.
  static let framesPerStream = 300
  static let streamSeconds = 60

  private struct Session {
    let id: String
    let kind: String
    var state = "running"
    let startedAt: Double
    var finishedAt: Double?
    var events: [JSONValue] = []
    var question: JSONValue = .null
    var exitCode: Int32?
    var error: String?
    var cancelRequested = false
    /// The child wrote its `exit` event: it asks nothing more.
    var exited = false
    var errorLines: [String] = []
    var status: (code: Int32, signal: Bool)?
    var outputEnded = false
  }

  private let lock = NSLock()
  private var session: Session?
  private var answers: Int32 = -1
  /// Grows on every change, across sessions, so a stream sends a frame only when something changed.
  private var revision = 0

  deinit { closeAnswers() }

  /// A session runs: its child hasn't been seen to end.
  var running: Bool { lock.withLock { session?.state == "running" } }

  /// The current or last session, or null.
  func json() -> JSONValue { lock.withLock { session.map(Self.json) ?? .null } }

  /// The session and its revision, for a stream.
  func snapshot() -> (revision: Int, session: JSONValue) {
    lock.withLock { (revision, session.map(Self.json) ?? .null) }
  }

  /// Starts `start`'s child with `executable`; one session at a time. A child that can't be started is a session that
  /// failed at once, with why.
  func start(_ start: DesktopClusterSessionStart, executable: URL, configPath: String?) throws -> JSONValue {
    try lock.withLock {
      guard session?.state != "running" else { throw HTTPError(.conflict, message: Self.busyMessage) }
      closeAnswers()
      // The child's callbacks wait for the lock, so they find this session once it is set below.
      var started = Session(id: UUID().uuidString, kind: start.kind, startedAt: Date().timeIntervalSince1970)
      do {
        try launch(id: started.id, executable: executable, arguments: start.arguments(configPath: configPath))
      } catch {
        started.state = "failed"
        started.finishedAt = Date().timeIntervalSince1970
        started.error = "Couldn't start the cluster setup: \(error.localizedDescription)"
      }
      session = started
      revision += 1
      return Self.json(started)
    }
  }

  /// Writes the answer line to the child for the question it asks now, or its cancel; the session's question is then
  /// cleared until the child asks again.
  func answer(_ answer: DesktopClusterSessionAnswer) throws -> JSONValue {
    try lock.withLock {
      guard var current = session, current.state == "running", !current.exited, answers >= 0 else {
        throw HTTPError(.conflict, message: "No cluster setup is running.")
      }
      let line: String
      if answer.cancel == true {
        guard answer.question == nil, answer.choice == nil, answer.key == nil else { throw ValidationError("Invalid answer") }
        line = #"{"cancel":true}"#
        current.cancelRequested = true
      } else {
        guard let id = answer.question, current.question.field("id").text == id else {
          throw HTTPError(.conflict, message: "That question is no longer asked.")
        }
        line = try Self.answerLine(id: id, answer, to: current.question)
      }
      guard Self.write(line + "\n", to: answers) else {
        throw HTTPError(.conflict, message: "The cluster setup isn't reading answers.")
      }
      current.question = .null
      session = current
      revision += 1
      return Self.json(current)
    }
  }

  /// `answer` as the child reads it, when it answers `question`: one of its options, or one of its keys.
  static func answerLine(id: String, _ answer: DesktopClusterSessionAnswer, to question: JSONValue) throws -> String {
    struct Choice: Encodable { let question: String; let choice: Int }
    struct Key: Encodable { let question: String; let key: String }
    let encoded: Data
    switch question.field("type").text {
    case "choose":
      guard let choice = answer.choice, answer.key == nil, question.field("options").values.indices.contains(choice) else {
        throw ValidationError("Invalid answer")
      }
      encoded = try JSONEncoder().encode(Choice(question: id, choice: choice))
    case "key":
      guard let key = answer.key, answer.choice == nil,
        question.field("keys").values.contains(where: { $0.field("key").text == key })
      else { throw ValidationError("Invalid answer") }
      encoded = try JSONEncoder().encode(Key(question: id, key: key))
    default:
      throw ValidationError("Invalid answer")
    }
    return String(decoding: encoded, as: UTF8.self)
  }

  // MARK: - The child

  /// Called with the lock held.
  private func launch(id: String, executable: URL, arguments: [String]) throws {
    let child = Process()
    child.executableURL = executable
    child.arguments = arguments
    let input = Pipe(), output = Pipe(), errors = Pipe()
    child.standardInput = input
    child.standardOutput = output
    child.standardError = errors
    child.environment = DesktopWorker.childEnvironment
    child.terminationHandler = { [weak self] process in
      let signal = process.terminationReason == .uncaughtSignal
      self?.ended(id, status: (process.terminationStatus, signal))
    }
    do {
      try child.run()
    } catch {
      child.terminationHandler = nil
      for pipe in [input, output, errors] {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
      }
      throw error
    }
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    try? errors.fileHandleForWriting.close()
    // The child's answers: a write never blocks the API or raises SIGPIPE; it fails instead.
    answers = dup(input.fileHandleForWriting.fileDescriptor)
    try? input.fileHandleForWriting.close()
    if answers >= 0 {
      _ = fcntl(answers, F_SETFD, FD_CLOEXEC)
      _ = fcntl(answers, F_SETNOSIGPIPE, 1)
      _ = fcntl(answers, F_SETFL, fcntl(answers, F_GETFL) | O_NONBLOCK)
    }
    let events = output.fileHandleForReading, diagnostics = errors.fileHandleForReading
    Thread.detachNewThread { [weak self] in
      Self.lines(of: events) { self?.received(id, $0) }
      self?.outputEnded(id)
    }
    Thread.detachNewThread { [weak self] in
      Self.lines(of: diagnostics) { self?.diagnostic(id, $0) }
    }
  }

  /// Each line of `handle` as it arrives, framed as the console frames them (a line longer than `maximumLine` is
  /// dropped), then its unterminated last line, if any; then closes it.
  private static func lines(of handle: FileHandle, _ line: (String) -> Void) {
    defer { try? handle.close() }
    let rest = ClusterOnboardingAppConsole.readLines(
      handle.fileDescriptor, maximumBytes: maximumLine, readBytes: 65_536
    ) { line(String(decoding: $0, as: UTF8.self)) }
    if let rest { line(String(decoding: rest, as: UTF8.self)) }
  }

  private static func write(_ line: String, to descriptor: Int32) -> Bool {
    let bytes = Array(line.utf8)
    var offset = 0
    let deadline = Date().addingTimeInterval(1)
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      if count > 0 { offset += count; continue }
      guard count < 0, errno == EAGAIN || errno == EINTR, Date() < deadline else { return false }
      usleep(1_000)
    }
    return true
  }

  /// One line of the child's output.
  private func received(_ id: String, _ line: String) {
    let text = line.trimmingCharacters(in: .newlines)
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    lock.withLock {
      guard session?.id == id else { return }
      guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)), case .object = value,
        let kind = value.field("event").text
      else {
        // Not one of the console's events: said as it is.
        add(.dict(["type": .string("say"), "text": .string(text)]))
        return
      }
      switch kind {
      case "question":
        session?.question = Self.question(value.field("question"))
      case "exit":
        session?.exited = true
        session?.question = .null
      case "settle":
        if let last = session?.events.last, Self.isLive(last) { session?.events.removeLast() }
      default:
        guard let event = Self.event(kind, value) else { return }
        add(event)
      }
      revision += 1
    }
  }

  /// Appends `event` (lock held): live work replaces the live work before it, and anything else ends it.
  private func add(_ event: JSONValue) {
    guard var events = session?.events else { return }
    if let last = events.last, Self.isLive(last) { events.removeLast() }
    events.append(event)
    if events.count > Self.maximumEvents { events.removeFirst(events.count - Self.maximumEvents) }
    session?.events = events
    revision += 1
  }

  private static func isLive(_ event: JSONValue) -> Bool {
    ["working", "progress"].contains(event.field("type").text)
  }

  /// The app's event for the console's `kind`, its fields checked; nil for an event the app doesn't know.
  static func event(_ kind: String, _ value: JSONValue) -> JSONValue? {
    func text(_ key: String) -> JSONValue? { value.field(key).text.map(JSONValue.string) }
    func texts(_ key: String) -> JSONValue? {
      guard case .array(let items) = value.field(key) else { return nil }
      let strings = items.compactMap(\.text)
      return strings.count == items.count ? .array(strings.map(JSONValue.string)) : nil
    }
    switch kind {
    case "banner":
      guard let title = text("title"), let subtitle = text("subtitle") else { return nil }
      return .dict(["type": .string(kind), "title": title, "subtitle": subtitle])
    case "heading", "progress", "needs_terminal":
      guard let line = text("text") else { return nil }
      return .dict(["type": .string(kind), "text": line])
    case "say":
      guard let line = text("text") else { return nil }
      let stressed = value.field("stressed")
      guard let lead = stressed.field("lead").text, let middle = stressed.field("stressed").text,
        let tail = stressed.field("tail").text
      else { return .dict(["type": .string(kind), "text": line]) }
      return .dict([
        "type": .string(kind), "text": line,
        "stressed": .dict(["lead": .string(lead), "stressed": .string(middle), "tail": .string(tail)]),
      ])
    case "working":
      guard let rows = texts("rows") else { return nil }
      return .dict(["type": .string(kind), "rows": rows])
    case "result":
      guard let ok = value.field("ok").flag, let title = text("title"), let lines = texts("lines") else { return nil }
      return .dict(["type": .string(kind), "ok": .bool(ok), "title": title, "lines": lines])
    default:
      return nil
    }
  }

  /// The app's question: a `choose` with each option's rows and the one selected, or a `key` question with its keys;
  /// null for none, or for one it can't read.
  static func question(_ value: JSONValue) -> JSONValue {
    guard let id = value.field("id").text, !id.isEmpty else { return .null }
    switch value.field("type").text {
    case "choose":
      let options = value.field("options").values.map { $0.values.compactMap(\.text) }
      guard !options.isEmpty, options.allSatisfy({ !$0.isEmpty }), let selected = value.field("selected").number,
        options.indices.contains(Int(selected))
      else { return .null }
      return .dict([
        "id": .string(id), "type": .string("choose"),
        "options": .array(options.map { .array($0.map(JSONValue.string)) }), "selected": .int(Int64(selected)),
      ])
    case "key":
      let keys = value.field("keys").values.compactMap { key -> JSONValue? in
        guard let name = key.field("key").text, let label = key.field("label").text else { return nil }
        return .dict(["key": .string(name), "label": .string(label)])
      }
      guard !keys.isEmpty else { return .null }
      return .dict(["id": .string(id), "type": .string("key"), "keys": .array(keys)])
    default:
      return .null
    }
  }

  /// A line of the child's standard error: the last ones say why a child that ended early did.
  private func diagnostic(_ id: String, _ line: String) {
    let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    lock.withLock {
      guard session?.id == id else { return }
      session?.errorLines.append(String(text.prefix(1_000)))
      if let count = session?.errorLines.count, count > 20 { session?.errorLines.removeFirst(count - 20) }
    }
  }

  private func outputEnded(_ id: String) {
    lock.withLock {
      guard session?.id == id else { return }
      session?.outputEnded = true
      finishIfEnded()
    }
  }

  private func ended(_ id: String, status: (code: Int32, signal: Bool)) {
    lock.withLock {
      guard session?.id == id else { return }
      session?.status = status
      finishIfEnded()
    }
    // A child that left its output to another process (one it started) has no more to say once it exited.
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainSeconds) { [weak self] in self?.outputEnded(id) }
  }

  /// The session's end, once its child exited and its output was read (lock held).
  private func finishIfEnded() {
    guard var current = session, current.state == "running", current.outputEnded, let status = current.status else { return }
    let code = status.signal ? 128 + status.code : status.code
    current.exitCode = code
    current.finishedAt = Date().timeIntervalSince1970
    current.question = .null
    if let last = current.events.last, Self.isLive(last) { current.events.removeLast() }
    current.state = current.cancelRequested ? "cancelled" : code == 0 ? "succeeded" : "failed"
    if !current.exited { current.error = Self.endedEarly(current.errorLines, code: code, signal: status.signal) }
    session = current
    closeAnswers()
    revision += 1
  }

  /// Closes the child's answers if they are open (lock held, or in `deinit`).
  private func closeAnswers() {
    guard answers >= 0 else { return }
    Darwin.close(answers)
    answers = -1
  }

  /// Why a child ended without its `exit` event: a runtime without the app's console says so in the API's words for an
  /// older runtime; otherwise the last lines it wrote to standard error, or its status.
  static func endedEarly(_ lines: [String], code: Int32, signal: Bool) -> String {
    if lines.contains(where: { $0.contains("--app-console") }) {
      return "The installed Darkbloom runtime doesn’t support this yet. It needs a runtime release that includes the desktop app’s commands."
    }
    let said = lines.suffix(6).joined(separator: "\n")
    if !said.isEmpty { return String(said.suffix(2_000)) }
    return signal ? "The cluster setup stopped (signal \(code - 128))." : "The cluster setup stopped (exit status \(code))."
  }

  private static func json(_ session: Session) -> JSONValue {
    var fields: [String: JSONValue] = [
      "id": .string(session.id), "kind": .string(session.kind), "state": .string(session.state),
      "started_at": .double(session.startedAt), "events": .array(session.events), "question": session.question,
    ]
    if let finishedAt = session.finishedAt { fields["finished_at"] = .double(finishedAt) }
    if let exitCode = session.exitCode { fields["exit_code"] = .int(Int64(exitCode)) }
    if let error = session.error { fields["error"] = .string(error) }
    return .dict(fields)
  }

  // MARK: - The event stream

  /// `event: cluster-session` frames: the whole session (or null) at once, then on every change, at most five a
  /// second; the stream renews after `framesPerStream` frames or `streamSeconds`.
  func events(lease: DesktopStreamLimiter.Lease) -> Response {
    Response(
      status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-store"],
      body: .init { [self] writer in
        defer { lease.release() }
        let end = ContinuousClock.now + .seconds(Self.streamSeconds)
        var sent: Int?
        var frames = 0
        while frames < Self.framesPerStream, ContinuousClock.now < end {
          let (revision, session) = snapshot()
          if revision != sent {
            let data = try JSONEncoder().encode(session)
            try await writer.write(
              ByteBuffer(string: "event: cluster-session\ndata: \(String(decoding: data, as: UTF8.self))\n\n"))
            sent = revision
            frames += 1
          }
          try await Task.sleep(for: .milliseconds(200))
        }
        try await writer.finish(nil)
      })
  }
}

extension DesktopBackend {
  /// Starts the guided cluster setup in the API's mutation slot: refused while an operation runs (and actions are
  /// refused while it runs, `submit`).
  func startClusterSession(_ start: DesktopClusterSessionStart) throws -> JSONValue {
    try start.validate()
    guard !operations.contains(where: { $0.state == "running" }) else {
      throw HTTPError(.conflict, message: "An operation is already running. Wait for it to finish.")
    }
    return try clusterSessions.start(start, executable: DesktopWorker.childExecutable(executable), configPath: configPath)
  }
}

extension DesktopHTTP {
  /// `/control/v1/cluster/session` and its `answer` and `events`; nil for any other route.
  func clusterSessionRoute(_ request: Request, path: String) async throws -> Response? {
    let sessions = backend.clusterSessions
    if request.method == .get, path == "/control/v1/cluster/session" {
      return try Self.json(sessions.json())
    }
    if request.method == .get, path == "/control/v1/cluster/session/events" {
      return sessions.events(lease: try streams.acquire())
    }
    if request.method == .post, path == "/control/v1/cluster/session" {
      guard let body = try await Self.jsonBody(request) else { return try Self.jsonRequired() }
      let start = try Self.decodeBody(DesktopClusterSessionStart.self, from: body)
      return try Self.json(try await backend.startClusterSession(start), status: .accepted)
    }
    if request.method == .post, path == "/control/v1/cluster/session/answer" {
      guard let body = try await Self.jsonBody(request) else { return try Self.jsonRequired() }
      let answer = try Self.decodeBody(DesktopClusterSessionAnswer.self, from: body)
      return try Self.json(try sessions.answer(answer))
    }
    return nil
  }
}
