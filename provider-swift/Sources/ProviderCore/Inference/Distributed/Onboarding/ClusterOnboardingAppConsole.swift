import Foundation
import Darwin

/// The onboarding's console for the desktop app (`darkbloom cluster --app-console`, `darkbloom cluster local
/// --app-console`): no terminal. Each thing the screen shows is one JSON object on its own line of `output`, and each
/// answer one JSON object on its own line of `input`; the desktop API's cluster setup session reads the one and writes
/// the other (`docs/reference/desktop-control.md`, "Cluster setup session").
///
/// Events, by `event`: `banner` (`title`, `subtitle`), `heading` (`text`), `say` (`text`, and `stressed` with `lead`,
/// `stressed` and `tail` where a terminal shows bold), `working` (`rows`), `settle`, `progress` (`text`), `result`
/// (`ok`, `title`, `lines`), `needs_terminal` (`text`), `question` (`question`: a `choose` or `key` question, or null
/// once nothing is asked) and, last, `exit` (`code`, written by `finish`). Answers: `{"question": id, "choice": n}`,
/// `{"question": id, "key": "q"}` and `{"cancel": true}`, which answers as q and escape do in a terminal: from then on
/// every list returns nothing and every wait that takes q gets q. An answer to a question no longer asked is dropped.
///
/// A line is a terminal's line, its indent included; blank lines (a terminal's spacing) are not sent. Live work is sent
/// when it changes: `working` rows and `progress` replace the ones before, and the next said line ends them.
public final class ClusterOnboardingAppConsole: ClusterOnboardingConsole, @unchecked Sendable {
    private let input: Int32
    private let output: Int32
    /// What `needs_terminal` says (`suspended`): where to run this setup instead.
    private let needsTerminal: String
    /// The room of a live row: the app shows live rows, at about a wide terminal's width.
    public let liveWidth: Int?
    /// Whole lines: the app wraps them.
    public var width: Int? { nil }

    /// The answers that came for the question asked now, and how the input stands; shared with the reading thread.
    private let condition = NSCondition()
    private var answers: [Answer] = []
    private var asked: Asked?
    private var cancelled = false
    private var inputEnded = false
    private var outputFailed = false
    private var finished = false
    private var asks = 0

    /// What the app shows live now (the flow's thread only): nothing, `working` rows or a `progress` line.
    private var live: Live = .none
    /// A newer `progress` line than the one sent, held back while progress is sent at most four times a second.
    private var progressSent: UInt64 = 0

    /// One write at a time, whole lines.
    private let writing = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private enum Answer { case choice(String, Int), key(String, Character) }
    private enum Asked: Equatable { case choose(String, count: Int), key(String, [ClusterOnboardingWaitKey]) }
    private enum Live: Equatable { case none, working([String]), progress(String) }

    /// The longest answer line read; a longer one is dropped whole.
    static let maximumLine = 16_384
    /// Progress is sent at most this often (nanoseconds): a copy reports more often than anyone reads.
    static let progressInterval: UInt64 = 250_000_000

    /// `input` is this console's: it reads it on a thread of its own and closes it once it ends. `output` stays open.
    public init(input: Int32, output: Int32, needsTerminal: String, liveWidth: Int? = 120) {
        self.input = input
        self.output = output
        self.needsTerminal = needsTerminal
        self.liveWidth = liveWidth
        Thread.detachNewThread { [self] in read() }
    }

    /// This process's standard input and output for the app: the console takes private copies (closed in every child
    /// this process starts); standard input then reads /dev/null and standard output goes where standard error goes, so
    /// nothing else on the setup's path (sudo, `darkbloom login`, a stray line) reads an answer or writes into the
    /// events. The process leaves the terminal session it may be in (the desktop API started by hand), so no child can
    /// ask for a password at a terminal, and a closed pipe is an error to see, never a signal. Nil when the streams
    /// can't be copied.
    public static func standardStreams(needsTerminal: String) -> ClusterOnboardingAppConsole? {
        signal(SIGPIPE, SIG_IGN)
        let answers = fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, 3)
        let events = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3)
        guard answers >= 0, events >= 0 else {
            if answers >= 0 { Darwin.close(answers) }
            if events >= 0 { Darwin.close(events) }
            return nil
        }
        let empty = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        if empty >= 0 {
            _ = dup2(empty, STDIN_FILENO)
            Darwin.close(empty)
        }
        fflush(stdout)
        _ = dup2(STDERR_FILENO, STDOUT_FILENO)
        // Fails for a process group leader (a command a shell started), which keeps its terminal as before.
        _ = setsid()
        return ClusterOnboardingAppConsole(input: answers, output: events, needsTerminal: needsTerminal)
    }

    // MARK: - What the screen shows

    public func say(_ line: String) {
        guard !line.allSatisfy(\.isWhitespace) else { return }
        live = .none
        emit(["event": .string("say"), "text": .string(line)])
    }

    public func sayStressed(_ lead: String, _ stressed: String, _ tail: String) {
        guard !stressed.isEmpty else { return say(lead + tail) }
        live = .none
        emit(["event": .string("say"), "text": .string(lead + stressed + tail),
              "stressed": .object(["lead": .string(lead), "stressed": .string(stressed), "tail": .string(tail)])])
    }

    public func heading(_ title: String) {
        live = .none
        emit(["event": .string("heading"), "text": .string(title)])
    }

    public func banner(_ title: String, _ subtitle: String) {
        live = .none
        emit(["event": .string("banner"), "title": .string(title), "subtitle": .string(subtitle)])
    }

    public func result(_ succeeded: Bool, _ title: String, _ lines: [String]) {
        live = .none
        emit(["event": .string("result"), "ok": .bool(succeeded), "title": .string(title), "lines": .array(lines.map(JSON.string))])
    }

    public func working(_ text: String) { workingRows([text]) }

    /// Sent when the rows change (the flow says them again every few hundredths of a second while it waits).
    public func workingRows(_ rows: [String]) {
        guard !rows.isEmpty, live != .working(rows) else { return }
        live = .working(rows)
        emit(["event": .string("working"), "rows": .array(rows.map(JSON.string))])
    }

    public func settle() {
        guard live != .none else { return }
        live = .none
        emit(["event": .string("settle")])
    }

    /// The whole line (`text(nil)`), sent when it changes, at most four times a second: the flow says the latest again
    /// while the work goes on, so a line held back is sent with the next.
    public func progress(_ text: (_ width: Int?) -> String, logged: Bool) {
        let line = text(nil)
        guard live != .progress(line) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if case .progress = live, now &- progressSent < Self.progressInterval { return }
        live = .progress(line)
        progressSent = now
        emit(["event": .string("progress"), "text": .string(line)])
    }

    /// A step the app can't take (sudo's password, `darkbloom login`): said, then `body` runs with nothing to read, so a
    /// prompt there fails at once instead of waiting.
    public func suspended<T>(_ body: () -> T) -> T {
        settle()
        emit(["event": .string("needs_terminal"), "text": .string(needsTerminal)])
        return body()
    }

    // MARK: - Questions

    public func choose(_ options: [String], selected: Int, abandon: () -> Bool) -> Int? {
        ask(options.map { $0.components(separatedBy: "\n") }, selected: selected, abandon: abandon)
    }

    /// Each option as its whole text (no limit on a row's room): the app lays the rows out.
    public func chooseFitting(_ options: [(_ room: Int?) -> String], selected: Int, abandon: () -> Bool) -> Int? {
        choose(options.map { $0(nil) }, selected: selected, abandon: abandon)
    }

    /// The question until it is answered, the input closes or `abandon` turns true (asked every tenth of a second).
    /// Answered, the chosen option's first row is said as a terminal folds its list to it.
    private func ask(_ options: [[String]], selected: Int, abandon: () -> Bool) -> Int? {
        guard !options.isEmpty else { return nil }
        settle()
        condition.lock()
        guard !stopped else { condition.unlock(); return nil }
        asks += 1
        let id = "q\(asks)"
        asked = .choose(id, count: options.count)
        answers.removeAll()
        condition.unlock()
        let start = min(max(0, selected), options.count - 1)
        emit(["event": .string("question"), "question": .object([
            "id": .string(id), "type": .string("choose"),
            "options": .array(options.map { .array($0.map(JSON.string)) }), "selected": .int(start)])])
        var chosen: Int?
        condition.lock()
        while true {
            if let index = answers.firstIndex(where: { if case .choice(id, _) = $0 { return true }; return false }),
               case .choice(_, let choice) = answers.remove(at: index) {
                chosen = choice
                break
            }
            if stopped { break }
            condition.unlock()
            let abandoned = abandon()
            condition.lock()
            if abandoned { break }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        asked = nil
        answers.removeAll()
        condition.unlock()
        emit(["event": .string("question"), "question": .null])
        if let chosen, let row = options[chosen].first { say("  \u{25B8} " + row) }
        return chosen
    }

    /// q leaves every wait that takes keys in this flow; `key(milliseconds:taking:)` says which.
    public func key(milliseconds: Int) -> Character? { key(milliseconds: milliseconds, taking: [.leave]) }

    /// The keys `keys` offers as a `key` question (asked again only when they change; none: nothing asked), and one the
    /// app answered within `milliseconds`, else nil. After a cancel, or once the input closed, every wait that takes keys
    /// gets the first of them (q) at once; one that takes none waits its time out.
    public func key(milliseconds: Int, taking keys: [ClusterOnboardingWaitKey]) -> Character? {
        let deadline = Date(timeIntervalSinceNow: Double(max(0, milliseconds)) / 1000)
        condition.lock()
        if stopped {
            condition.unlock()
            if let first = keys.first { return first.key }
            Thread.sleep(until: deadline)
            return nil
        }
        var question: JSON?
        let offered: [ClusterOnboardingWaitKey]?
        if case .key(_, let shown)? = asked { offered = shown } else { offered = nil }
        if keys.isEmpty, asked != nil {
            question = .null
            asked = nil
            answers.removeAll()
        } else if !keys.isEmpty, offered != keys {
            asks += 1
            let id = "q\(asks)"
            asked = .key(id, keys)
            answers.removeAll()
            question = .object(["id": .string(id), "type": .string("key"),
                                "keys": .array(keys.map { .object(["key": .string(String($0.key)), "label": .string($0.label)]) })])
        }
        condition.unlock()
        if let question { emit(["event": .string("question"), "question": question]) }
        condition.lock()
        defer { condition.unlock() }
        while true {
            if case .key(let id, _) = asked,
               let index = answers.firstIndex(where: { if case .key(id, _) = $0 { return true }; return false }),
               case .key(_, let key) = answers.remove(at: index) {
                // Taken: the app asked nothing more; the next wait with keys asks again.
                asked = nil
                return key
            }
            if stopped { return keys.first?.key }
            if !condition.wait(until: deadline) { return nil }
        }
    }

    /// The input ended, the app cancelled, or the events can no longer be written.
    public var closed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    private var stopped: Bool { cancelled || inputEnded || outputFailed }

    /// The last event: the setup's exit status. Nothing is sent after it.
    public func finish(_ code: Int32) {
        condition.lock()
        let first = !finished
        let open = asked != nil
        asked = nil
        condition.unlock()
        guard first else { return }
        if open { emit(["event": .string("question"), "question": .null]) }
        emit(["event": .string("exit"), "code": .int(Int(code))])
        condition.lock()
        finished = true
        condition.unlock()
    }

    // MARK: - Lines in and out

    private func emit(_ event: [String: JSON]) {
        condition.lock()
        let done = finished
        condition.unlock()
        guard !done else { return }
        writing.lock()
        defer { writing.unlock() }
        guard var line = try? encoder.encode(JSON.object(event)) else { return }
        line.append(0x0A)
        let written = line.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress! + offset, bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR || errno == EAGAIN { usleep(1_000); continue }
                return false
            }
            return true
        }
        guard !written else { return }
        condition.lock()
        outputFailed = true
        condition.broadcast()
        condition.unlock()
    }

    /// Reads answer lines until the input ends, then closes it; each line is taken as it arrives.
    private func read() {
        defer { Darwin.close(input) }
        var pending = [UInt8]()
        var skipping = false
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Array(pending[..<newline])
                pending.removeSubrange(...newline)
                if skipping { skipping = false } else { take(line) }
            }
            if pending.count > Self.maximumLine {
                pending.removeAll()
                skipping = true
            }
        }
        condition.lock()
        inputEnded = true
        condition.broadcast()
        condition.unlock()
    }

    private struct Incoming: Decodable {
        var question: String?
        var choice: Int?
        var key: String?
        var cancel: Bool?
    }

    /// One answer line: kept when it answers the question asked now with one of its options or keys, else dropped.
    private func take(_ line: [UInt8]) {
        guard let incoming = try? JSONDecoder().decode(Incoming.self, from: Data(line)) else { return }
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        if incoming.cancel == true {
            cancelled = true
            return
        }
        guard let id = incoming.question else { return }
        switch asked {
        case .choose(id, let count)?:
            if let choice = incoming.choice, (0..<count).contains(choice) { answers.append(.choice(id, choice)) }
        case .key(id, let keys)?:
            if let text = incoming.key, text.count == 1, let key = text.first, keys.contains(where: { $0.key == key }) {
                answers.append(.key(id, key))
            }
        default:
            break
        }
    }

    /// The events' JSON values.
    private enum JSON: Encodable {
        case string(String), int(Int), bool(Bool), array([JSON]), object([String: JSON]), null

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }
}
