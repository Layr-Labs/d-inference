import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Option parsing for `darkbloom logs`. Running the command replaces the
/// process with `/usr/bin/log` or reads the real provider log, so only the
/// parsed options and the help text are checked here.
@Suite("Logs command options")
struct LogsCommandOptionsTests {

    @Test("defaults stream unified logs at info level with 50 file lines")
    func defaults() throws {
        let logs = try #require(try Darkbloom.parseAsRoot(["logs"]) as? Logs)
        #expect(!logs.file)
        #expect(!logs.follow)
        #expect(logs.last == nil)
        #expect(!logs.debug)
        #expect(logs.lines == 50)
    }

    @Test("short and long options set the history window, follow, debug and line count")
    func options() throws {
        let logs = try #require(try Darkbloom.parseAsRoot([
            "logs", "--last", "30m", "-f", "--debug", "-l", "200", "--file",
        ]) as? Logs)
        #expect(logs.last == "30m")
        #expect(logs.follow)
        #expect(logs.debug)
        #expect(logs.lines == 200)
        #expect(logs.file)
        #expect(throws: (any Error).self) { try Darkbloom.parseAsRoot(["logs", "--lines", "many"]) }
    }

    @Test("the help names the subsystem and the legacy log file")
    func help() {
        let discussion = Logs.configuration.discussion
        #expect(discussion.contains("(subsystem: dev.darkbloom.provider)"))
        #expect(discussion.contains(LaunchAgent.logPath().path))
        #expect(Logs.predicate == #"subsystem == "dev.darkbloom.provider""#)
    }

    @Test("show and stream argv share the predicate and output style")
    func sharedArgv() {
        let show = Logs.showArgv(predicate: Logs.predicate, duration: "2h", debug: false)
        let stream = Logs.streamArgv(predicate: Logs.predicate, debug: false)
        #expect(show == ["log", "show", "--predicate", Logs.predicate, "--style", "ndjson", "--info", "--last", "2h"])
        #expect(stream == ["log", "stream", "--predicate", Logs.predicate, "--style", "ndjson", "--level", "info"])
    }
}
