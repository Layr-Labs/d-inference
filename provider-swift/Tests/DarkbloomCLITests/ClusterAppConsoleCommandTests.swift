import ArgumentParser
import Darwin
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// The app's console over two pipes, as the desktop API runs it: the events it wrote, and answers to write.
private final class AppConsolePipes: @unchecked Sendable {
    let console: ClusterOnboardingAppConsole
    private let answers: Int32
    private let writer: Int32
    private let lock = NSLock()
    private var lines: [String] = []

    init() throws {
        var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0 else { throw CocoaError(.fileWriteUnknown) }
        answers = input[1]
        writer = output[1]
        console = ClusterOnboardingAppConsole(input: input[0], output: output[1], needsTerminal: Cluster.Setup.needsTerminalLine)
        let reader = output[0]
        Thread.detachNewThread { [self] in
            var pending = [UInt8](), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(reader, &buffer, buffer.count)
                guard count > 0 else { break }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    lock.withLock { lines.append(line) }
                }
            }
            Darwin.close(reader)
        }
    }

    // The console reads the end of its answers and closes them; the reader reads the end of the events.
    deinit {
        Darwin.close(answers)
        Darwin.close(writer)
    }

    var events: [JSONValue] { lock.withLock { lines }.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } }
    var said: [String] { events.filter { $0.field("event").text == "say" }.compactMap { $0.field("text").text } }

    /// The said lines once `done` holds for them (the events are read on a thread of their own), or after two seconds.
    func said(_ done: ([String]) -> Bool) -> [String] {
        for _ in 0..<200 where !done(said) { usleep(10_000) }
        return said
    }

    /// The first question asked, if it was.
    var question: JSONValue? {
        events.first { $0.field("event").text == "question" && $0.field("question") != .null }?.field("question")
    }

    /// Writes `answer`'s line for the first question once it is asked (within five seconds), from a thread of its own:
    /// the gate under test waits for it on the caller's.
    func answerWhenAsked(_ answer: @escaping @Sendable (_ id: String) -> String) {
        Thread.detachNewThread { [self] in
            for _ in 0..<500 {
                if let question { send(answer(question.field("id").text ?? "")); return }
                usleep(10_000)
            }
        }
    }

    func send(_ line: String) {
        _ = (line + "\n").withCString { Darwin.write(answers, $0, strlen($0)) }
    }
}

/// `darkbloom cluster --app-console` and `darkbloom cluster local --app-console`: the flag, and the waitlist gate's question
/// on the app's console.
@Suite("darkbloom cluster --app-console")
struct ClusterAppConsoleCommandTests {
    static func access(_ place: FeatureWaitlistPlace.Status, joined: FeatureWaitlistPlace.Status) -> FeatureWaitlistAccess {
        FeatureWaitlistAccess(
            coordinator: "https://coordinator.invalid",
            waitlists: { .failure(.unavailable("not asked")) },
            place: { _ in .success(FeatureWaitlistTests.place("cluster", "Clusters", place, start: "darkbloom cluster")) },
            join: { _ in .success(FeatureWaitlistTests.place("cluster", "Clusters", joined, start: "darkbloom cluster")) })
    }

    @Test("the waitlist's question is a list on the app's console, in the gate's own words, No first; Yes joins")
    func waitlistQuestionIsAChoice() async throws {
        let pipes = try AppConsolePipes()
        pipes.answerWhenAsked { "{\"question\":\"\($0)\",\"choice\":0}" }
        try await Cluster.Setup.requireNewPairApproval(
            pair: .notPaired, request: .init(),
            gate: Cluster.Setup.appWaitlistGate(console: pipes.console, access: Self.access(.none, joined: .approved)))
        let question = try #require(pipes.question)
        #expect(question.field("type") == .string("choose"))
        #expect(question.field("options") == .array([.array([.string("Yes")]), .array([.string("No")])]))
        #expect(question.field("selected") == .int(1))
        #expect(pipes.said { $0.count >= 3 } == ["Clusters is open to the accounts Darkbloom approves from its waitlist.",
                                                  "Join the Clusters waitlist now?", "  \u{25B8} Yes"])
    }

    @Test("No at the app's waitlist question joins nothing: the gate's lines, then exit 1; a cancel is No")
    func waitlistQuestionDeclined() async throws {
        let answers: [@Sendable (String) -> String] = [{ "{\"question\":\"\($0)\",\"choice\":1}" }, { _ in #"{"cancel":true}"# }]
        for answer in answers {
            let pipes = try AppConsolePipes()
            pipes.answerWhenAsked(answer)
            var thrown: (any Error)?
            do {
                try await Cluster.Setup.requireNewPairApproval(
                    pair: .notPaired, request: .init(),
                    gate: Cluster.Setup.appWaitlistGate(console: pipes.console, access: Self.access(.none, joined: .approved)))
            } catch { thrown = error }
            #expect(thrown as? ExitCode == .failure)
            let cli = ClusterPairSummary.cli
            let said = pipes.said { $0.last?.contains("cluster local") == true }
            #expect(said.suffix(2) == ["  Join it: \(cli) waitlist cluster", "  Serving on your own Macs only needs no approval: \(cli) cluster local"])
            #expect(!pipes.said.contains("  \u{25B8} Yes"))
        }
    }

    @Test("the flag parses on both commands, hidden, and takes none of the link setup's or the wizard's options")
    func flagParses() throws {
        let setup = try #require(try Darkbloom.parseAsRoot(["cluster", "--app-console", "--config", "/tmp/provider.toml"]) as? Cluster.Setup)
        #expect(setup.appConsole)
        let local = try #require(
            try Darkbloom.parseAsRoot(["cluster", "local", "--app-console", "--bind", "127.0.0.1", "--config", "/tmp/p.toml", "qwen-9b"])
                as? Cluster.Local)
        #expect(local.appConsole && local.bind == "127.0.0.1" && local.model == "qwen-9b")
        for option in ["--json", "--yes", "--temporary", "--dry-run", "--link-only", "--plain", "--wizard"] {
            #expect(throws: (any Error).self, "\(option)") { try Darkbloom.parseAsRoot(["cluster", "--app-console", option]) }
        }
        #expect(!Cluster.Setup.helpMessage().contains("--app-console"))
        #expect(!Cluster.Local.helpMessage().contains("--app-console"))
    }

    /// `bytes` through a pipe that then ends, read four bytes at a time with at most eight waiting for a line break.
    static func framed(_ bytes: String) throws -> (lines: [String], rest: String?) {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(ends[0]) }
        _ = bytes.withCString { Darwin.write(ends[1], $0, strlen($0)) }
        Darwin.close(ends[1])
        var lines: [String] = []
        let rest = ClusterOnboardingAppConsole.readLines(ends[0], maximumBytes: 8, readBytes: 4) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }
        return (lines, rest.map { String(decoding: $0, as: UTF8.self) })
    }

    @Test("the console's framing, as both ends read it: whole lines, an overlong one dropped through its line break")
    func linesAreFramedAsBothEndsReadThem() throws {
        #expect(try Self.framed("one\ntwo\n") == (["one", "two"], nil))
        #expect(try Self.framed("") == ([], nil))
        // Over eight bytes wait for the break: that line is dropped, its continuation too, and the next one read.
        #expect(try Self.framed("0123456789abcdef\nafter\nrest") == (["after"], "rest"))
        // An overlong last line is no rest.
        #expect(try Self.framed("ok\n0123456789ab") == (["ok"], nil))
    }
}
